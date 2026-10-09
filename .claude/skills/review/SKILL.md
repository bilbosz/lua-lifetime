---
name: review
description: The reviewer's checklist and output format for judging one task branch of lua-lifetime against its task file and the spec in docs/. Produces findings and a verdict (APPROVE, REQUEST_CHANGES or BLOCKED). Never edits code.
---

# Review a task

You produce findings and a verdict. You do not edit anything.

## Inputs

The task file, the branch name, the implementer's handoff, and the diff
(`git diff master...task/NNN-slug`). Read all four before forming a view.

## Procedure

1. **Rebuild the expectation first.** From the task file and the cited spec
   sections, write down what the correct behaviour is for each acceptance
   criterion *before* reading the implementation. Then compare.
2. **Run the suite yourself.** `make test` and `make lint` on the branch
   head. Record the summary lines and which interpreters ran. A green suite
   is necessary, not sufficient. Then `make bench` on the branch head and
   on `master`, same machine, both interpreters.
3. **Trace by hand.** Choose the acceptance criterion whose spec sentence is
   easiest to misread (the task file names one; disagree if you like) and
   trace a concrete program through the code. Then do the same for one
   program the task's tests do *not* cover. Write the trace down briefly in
   the review; it is the part the implementer learns most from.
4. **Walk the checklist** below. Every item is either confirmed, a finding,
   or not applicable with a reason.
5. **Decide the verdict** by the rules at the end.

## Checklist

**Spec conformance**
- Each acceptance criterion is implemented and matches the cited sentence.
- Each spec citation in the handoff is accurate (the sentence says what the
  implementer says it says).
- Behaviour that the diff introduces but the task does not cite is traced to
  the spec by you, or flagged as uncited.
- Nothing in `docs/06-open-questions.md` was silently decided by the code,
  and nothing contradicts a decision of
  `xd/docs/10-lua-lifetime-decisions.md`.

**Ownership order** (`docs/02-semantics.md`, "Cascading death",
"`__destroy` and reasons", "Tombstones")
- Cascade is two-phase: all deaths decided before any destructor runs.
- An object's body runs before its dependents; dependents and hooks share
  one order, most recently attached first; a scope's dependents go in
  reverse attachment order; the tombstone comes after the subtree.
- Scope destructors run on every exit path the task covers: fall-through,
  `return`, `break`, `goto` on LuaJIT, error.
- `reason` matches the spec; dying objects are usable; only `@` on them and
  anchoring to them is refused; `destroy` on a dead or dying object is a
  no-op.
- Errors in destructors follow the C++ rule exactly.

**Collector honesty**
- No strong reference from a runtime table to a dependent that may be
  collected; hook lists are the one strong list, and only because hooks are
  pinned.
- No side table keyed by an anchor. The sentinel reaches its table through
  its own metatable.
- No test or code claims a reachable death at a point other than after
  `collectgarbage("collect")`.
- Nothing works on one interpreter only; `make test` ran under both when
  both are installed.

**Tests**
- Every acceptance criterion has a test that would fail if the behaviour
  regressed.
- Death tests assert order and the statement of death, not just occurrence.
- No `.expected` file changed unless the task said it would, and the commit
  says why.
- `make test` and `make lint` are green on the branch head (you ran them).

**Performance** (`CLAUDE.md`, rule 5)
- The task's *Performance* section is honoured: the named benchmarks exist
  and ran.
- No benchmark the task touches is slower than `master` beyond the
  threshold in `bench/README.md`.
- Code that does not use the extension pays nothing: the plain-Lua
  benchmarks did not move, a block without `@ lifetime.scope` or a bare hook is
  emitted verbatim, an object never anchored has no state.
- No optimisation changes observable behaviour (order, reasons, error
  texts, the statement of death).

**Scope**
- The diff does what the task says and nothing else. Optimisations of paths
  the task does not name, extra builtins, or semantic drift are findings
  even when well-intentioned.
- Nothing under *Out of scope* in the task file was touched.

**Quality** (does not change the verdict on its own)
- Names follow the spec's vocabulary.
- No dead code, no commented-out code, no TODOs without a task id.

## Output format

```
## Verdict: APPROVE | REQUEST_CHANGES | BLOCKED

## Suite
<summary line of make test per interpreter, make lint, make bench on branch and master per interpreter, and whether you ran them on the branch head>

## Trace
<the hand trace from step 3: program, expected per spec, observed in code, match or not>

## Findings
### F1 — <blocking|non-blocking> — <one-line claim>
File: path:line
Spec: docs/<file>.md, "<heading>" — "<quoted sentence>"
Input: <concrete program or call>
Expected: ...
Observed: ...
Fix: <precise description, no code edits by you>

### F2 — ...

## Questions
<things you could not reproduce or could not trace to the spec; not findings>

## Notes for the orchestrator
<spec gaps, open questions touched, follow-up tasks to create>
```

## Verdict rules

- **APPROVE**: no blocking findings, suite green, every acceptance criterion
  confirmed. Non-blocking findings may remain; list them so they can become a
  follow-up task.
- **REQUEST_CHANGES**: at least one blocking finding. A finding is blocking if
  it is a spec violation, an ordering error, a strong reference or side
  table the runtime may not keep, something that works on one interpreter
  only, a missing or inadequate test for an acceptance criterion, a
  measured slowdown beyond the threshold or a cost added to code that does
  not use the extension, a missing benchmark the task asked for, or an
  out-of-scope change that alters behaviour.
- **BLOCKED**: the task cannot be judged because the spec is silent or
  contradictory on something the task requires, or it touches an open
  question. Say exactly which sentence is missing. Do not propose semantics;
  that is for `/spec-change` and the human.

Be exact and be brief. A review is read by someone who will act on every
line, so every line must be actionable or removable.
