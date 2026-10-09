# lua-lifetime — guidance for agents working in this repository

`lua-lifetime` is a transpiler and a runtime that bring owned and scoped
objects with destructors to Lua 5.1 and LuaJIT. Read `README.md` first,
then the documents in `docs/`. **The documents in `docs/` are the
specification.** Code that disagrees with them is wrong; if the documents
are wrong, change the documents first (see
`.claude/skills/spec-change/SKILL.md`), never the code alone. The
documents are derived from `xd/docs/10-lua-lifetime-decisions.md` in the
`xd` repository; a decision recorded there is not changed here.

## Where things are

| Path | What |
| --- | --- |
| `docs/01-overview.md` | What lua-lifetime is, the one-screen taste, where the semantics come from, the relation to `xd` and `teal-lifetime`. Read once. |
| `docs/02-semantics.md` | **The spec** of the language extension: `@` and the list form, the implicit `reachable` term and `lifetime.pin`, `lifetime.scope`, hooks and the `!@` operator, tokens, `destroy`, the cascade order, `__destroy`, tombstones, errors, reachability, program end. |
| `docs/03-runtime.md` | The design of the `lifetime` module: state records inside the anchor, the sentinel, the cascade, scope records, tokens. |
| `docs/04-transpiler.md` | The grammar and the code generation: what `@` expands to, block epilogues on every exit path, the `pcall` wrapper, the command. |
| `docs/05-decisions.md` | Decision log of this repository. Check here before proposing a change. |
| `docs/06-open-questions.md` | Not decided yet. If a task hits one of these, stop and ask. |
| `docs/07-conformance.md` | How the conformance suite relates to `xd/examples/`: ported, rewritten, deviations. |
| `examples/*.lt` | Example programs. Each becomes a conformance test. |
| `tasks/` | Work items. See `tasks/README.md` for the format and lifecycle. |
| `lifetime/` | The runtime (`init.lua`) and the transpiler (`lexer.lua`, `parser.lua`, `emit.lua`, `cli.lua`). |
| `bin/lifetime` | The command: `lifetime build FILE -o OUT`, `lifetime run FILE`. |
| `tests/` | The unit suite (`run.lua`, `lib/test.lua`) and the conformance runner (`conformance.lua`). |

## How work happens here

Work is split between two roles, run as separate agents:

- **Implementer** (`.claude/agents/implementer.md`): takes one task from
  `tasks/`, implements it on a task branch, writes tests, runs them,
  commits. Does not review its own work beyond the self-check in the
  implement skill.
- **Reviewer** (`.claude/agents/reviewer.md`): reviews the implementer's
  diff against the task and the spec, runs the suite, and returns a verdict
  with findings. **Never edits code.** Findings go back to the implementer.

The loop is driven by the dispatch skill (`.claude/skills/dispatch/SKILL.md`):
create tasks → dispatch one to the implementer → review → iterate until
approved → **pull request to `master`** → merge → mark done. A human can run
any step by hand.

Skills, invoked with `/name`:

| Skill | Who runs it | Purpose |
| --- | --- | --- |
| `/create-task` | orchestrator or human | Turn a request into one or more task files with acceptance criteria. |
| `/dispatch` | orchestrator | Pick ready tasks, run the implement → review loop, merge. |
| `/implement` | implementer agent | The procedure for completing one task. |
| `/review` | reviewer agent | The checklist and output format for reviewing one task. |
| `/spec-change` | anyone | How to change the language semantics correctly, and what may not be changed here. |

## Rules that apply to everyone

1. **The spec wins, then Lua 5.1.** The spec is `docs/`, derived from
   `xd/docs/10-lua-lifetime-decisions.md` and the rest of `xd/docs/`. Before
   writing code for any behaviour, find the sentence in `docs/` that
   defines it and cite it in the task or the commit message. If no sentence
   defines it and Lua 5.1 defines it, Lua's behaviour is the spec: cite
   the Lua 5.1 reference manual section, or LuaJIT's documentation where
   LuaJIT differs. If neither defines it, that is a spec gap: file it via
   `/spec-change` or ask, do not guess.
2. **Expected output is law.** Every `examples/*.lt` file has a matching
   `examples/*.lt.expected` file (`examples/README.md` defines the
   format). The conformance runner must pass on every merged commit, under
   every interpreter it finds. Never edit an `.expected` file to make a
   test pass unless the spec says the old expectation was wrong, and then
   say so in the commit.
3. **Ownership order is the product; reachability timing is not.**
   Cascade order, scope-exit order, the moment a `destroy` or a block exit
   runs a destructor, and the tombstone afterwards are all specified. A
   test that checks *that* something was destroyed but not *in what order*
   and *at which statement* is not finished. A death by `reachable`
   happens when the collector finds it; tests pin it with
   `collectgarbage("collect")` and never with timing.
4. **No semantic changes in implementation tasks.** If implementing a task
   makes you want to change the semantics, stop, write down why in the task
   file under "Spec issues found", and finish the parts that do not depend
   on it. The reviewer and the human decide.
5. **Performance is a priority, second only to correctness.** The order
   is: the spec, then ownership order, then speed, then brevity. Code that
   does not use the extension pays nothing: a plain Lua chunk transpiles
   to itself, a block with no `@ lifetime.scope` and no bare hook gets no scope
   record, an object never anchored gets no state, a pinned object gets no
   proxy. Code that does use it pays as little as the design allows, and
   the cost is measured, not guessed: a task that touches a hot path adds
   or updates a benchmark under `bench/`, and `make bench` (task 010
   provides it) compares the branch with `master` on the same machine. An
   optimisation never changes what a program observes (order, reasons,
   error texts, the statement of death); one that would is a spec change.
6. **The runtime owns nothing the collector does not.** It never keeps a
   strong reference to a dependent that the language says may be
   collected: dependents lists are weak-valued, hook lists are strong
   because hooks are pinned, and there is no side table keyed by an anchor.
   If a test needs a strong reference to keep an object alive, the test
   holds it.
7. **Branches, pull requests and `master`.** Nothing is committed to
   `master` directly after the bootstrap commit. One task per branch, named
   `task/NNN-slug`; spec changes on `spec/slug`; everything else on
   `chore/slug`. **Every branch that opens a pull request has a meaningful
   name** in one of those three forms, chosen before the first commit; an
   auto-generated or session name (`ccr-…`, `claude/…`, `wip`) is not
   acceptable, however the session was started. If a tool assigns you such
   a branch, create the properly named branch from it and open the pull
   request from that one. Small commits with messages that name the task
   (`[001] …`). Every branch reaches `master` through a pull request whose
   body carries the task id, the spec sections relied on, and the
   reviewer's final verdict. A task PR is opened only after the reviewer's
   verdict is APPROVE and merged with a merge commit. `master` therefore
   always holds the current spec, a green suite, and nothing half-reviewed.
   Never rewrite history on `master`.
8. **Tests run with one command.** `make test` runs everything: the unit
   suite under every interpreter found among `lua5.1` and `luajit`, and
   the conformance suite, which runs every example under every
   interpreter found. If it is not green, the task is not done. `make
   lint` must be clean too.

## Technical decisions (binding)

- Lua 5.1 and LuaJIT are the targets. The runtime and the generated code
  use nothing outside Lua 5.1 plus `newproxy`; LuaJIT's `goto` is honoured
  by the transpiler when it appears in the input and never emitted
  otherwise.
- No dependencies. No busted, no luaunit, no lpeg. The lexer and parser are
  hand-written. The test harness is `tests/lib/test.lua`.
- The parser is recursive descent over a plain table AST with a line on
  every node. The emitter preserves source lines.
- State lives inside the object (`docs/03-runtime.md`). Dependents are
  iterated by a numeric loop over the anchor's sequence-number range,
  newest first, skipping holes: never `ipairs`, which stops at the first
  hole, and never a sort per cascade.
- Hot paths stay cheap and compilable by LuaJIT: the generated chunk
  binds the runtime functions it uses to locals; no generated function
  gets a prologue or epilogue of its own, so a call costs what it costs
  in Lua; the runtime uses numeric `for` loops on its own hot paths;
  nothing that runs per block entry uses `debug.*`, `coroutine.running`, `select("#", …)` on
  the common path, or creates a closure where an alternative exists.
  Where the spec forces a cost (the `pcall` wrapper, the sentinel), the
  benchmark says how much (`docs/03-runtime.md`, "Performance").
- The tombstone is an emptied table with the dead metatable. There is no
  dead-object type; `lifetime.alive` is the check.
- Reachability is Lua's. The runtime never traces, counts references, or
  wraps assignments. `collectgarbage("collect")` is the only timing a test
  may rely on for a reachable death.
- Guest and host are the same Lua state. The runtime's own tables
  (`lifetime`, the dead metatable) are roots like any module; nothing else the runtime holds keeps a user
  object alive beyond what rule 6 allows.

## Things that look like bugs but are the spec

- The owner's destructor runs **before** its dependents' (`docs/02-semantics.md`,
  "Cascading death"): `__destroy` sees every dependent alive.
- A hook on an object runs **after** that object's `__destroy`, in its
  place among the object's other dependents by attachment order.
- `@ x` dies early if nothing refers to the dependent: `@ x` implies the
  `reachable` term, and the collector may take an unreferenced dependent
  before `x` dies. `lifetime.pin(x)` is the spelling for "alive while `x`
  is, referenced or not".
- Dead objects are tombstones, not `nil`: the reference stays, indexing it
  raises with the object's name and where it died, and `lifetime.alive(x)`
  is the check. Identity survives death.
- A reachable death is the collector's: nothing is destroyed at the end of
  the statement that dropped the last reference. Tests call
  `collectgarbage("collect")`, twice when a weak table must have cleared.
- `local tmp = {} @ lifetime.scope` followed by `tmp = nil` is collected whenever
  the collector runs, not at the block exit.
- `destroy` on a dead or dying object is a no-op, so a destructor may
  destroy its own dependents by hand.
- `f !@ x` is pinned by `x` even though every other `@ x` is not, and
  stays pinned when moved with `@`.
- A hook has no default lifetime: block-exit cleanup is written
  `f !@ lifetime.scope`.
- `defer`, `token`, `scope` and `caller` are ordinary names; hooks are
  made with `!@`, tokens with `lifetime.token([name])`, and the block
  anchor is the spelling `lifetime.scope` after `@` or `!@`.
- `lifetime.token("p") @ self` dies early if nothing holds it, like any
  `@ self`; keep it in a field or anchor it with `lifetime.pin(self)`.
- `lifetime.scope` is syntax after `@`, not a value: stored in a
  variable it is a marker that cannot be anchored to. There is no scope
  value and no loop-iteration trap.
- There is no `caller`: a function returns an object on the default
  lifetime and the receiver anchors it (`local x = f() @ lifetime.scope`).
- A plain table the runtime never saw is collected silently, `__destroy`
  or not; `x @ lifetime.reachable` registers it.
- `return x` from a block where `x @ lifetime.scope` hands the caller a tombstone.
