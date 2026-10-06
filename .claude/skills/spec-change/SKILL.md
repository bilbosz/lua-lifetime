---
name: spec-change
description: How to change the semantics of lua-lifetime correctly: update docs/02-semantics.md and the design docs, record the decision in docs/05-decisions.md, adjust affected examples and expected outputs, and queue implementation tasks. Says what may not be changed here. Use whenever code work reveals a spec gap, or the user wants a language change.
---

# Change the spec

Semantics live in `docs/`, never in code alone. A semantic change is a docs
change first, a decision-log entry second, and implementation tasks third.

## What may not be changed here

The spec in `docs/` is derived from `xd/docs/10-lua-lifetime-decisions.md`
("file 10") and the rest of `xd/docs/`. **A change to a decision of file
10 is not made in this repository.** If a problem with one of its eleven
decisions turns up, or with a sentence of `xd/docs/` that file 10 does not
reverse:

1. Write the problem into `docs/06-open-questions.md` under "Found while
   deriving the spec" or a new heading: what the decision says (quote it),
   what program exposes the problem, and what the alternatives are.
2. Report it to the human in the handoff or the dispatch report. The human
   carries it back to `xd`, where it is settled through `xd`'s own
   `/spec-change`, and file 10 is updated there.
3. Do not push to `xd` from here. Do not implement either reading; leave
   the task blocked on the question if it cannot proceed without it.

What this repository settles itself: the open points file 10 lists for
lua-lifetime ("Open points for lua-lifetime"), the decisions already in
`docs/05-decisions.md`, and anything `xd/docs/` is silent on. Settling one
is reported back to the human too, so `xd` can learn from it.

## Procedure

1. **State the problem** in two sentences: what the spec currently says (quote
   it) or fails to say, and what program exposes it (concrete code with the
   behaviour in question).
2. **Check the authority.** Is the sentence derived from a decision of file
   10, or from the rest of `xd/docs/`? Then follow "What may not be changed
   here". Is it this repository's own? Then check `docs/05-decisions.md`:
   it may already have decided this, possibly the other way. If so, the
   change is a *reversal*: say so explicitly and give the new evidence.
   Reversals need the human's approval before step 4.
3. **Check open questions.** If `docs/06-open-questions.md` lists it, you are
   resolving an open question; move it to the decision log in step 5.
4. **Edit the docs.** Update every section that states the behaviour, not
   just the first one you find. `grep` the key terms across `docs/`,
   `README.md`, `CLAUDE.md` and `examples/`. The usual suspects:
   `docs/02-semantics.md` (the spec and its summary table),
   `docs/03-runtime.md`, `docs/04-transpiler.md` (grammar, expansions),
   `docs/07-conformance.md`.
5. **Record the decision** in `docs/05-decisions.md`: what was decided, why,
   what it replaced, and a link to the section that now embodies it. Newest at
   the bottom.
6. **Fix the examples.** Any `examples/*.lt` whose behaviour changes gets its
   `.expected` file updated in the same commit, with the commit message
   naming the decision. An example ported from `xd` that now deviates is
   recorded in `docs/07-conformance.md` under "Deviations".
7. **Queue work.** Use `/create-task` for the implementation, citing the new
   or changed sentences. If the change invalidates an `in-progress` task,
   note it in that task's *Spec issues found* and tell the orchestrator.
8. **Branch and pull request.** Make the change on a `spec/slug` branch with
   a commit message starting `spec:`, push it, and open a pull request to
   `master` titled `spec: <one line>` whose body quotes the old and new
   sentences and links the decision-log entry. The reviewer agent does not
   review spec PRs; the human does. Merge with a merge commit once approved.
   `master` must always hold the current spec, so do not leave spec PRs open
   while implementation tasks that depend on them start.

## What is not a spec change

- Fixing a typo or clarifying wording without changing behaviour: just edit.
- Adding an example that the current spec already determines: just add it,
  with its `.expected`.
- A bug in the runtime or the transpiler: that is a task, not a spec change.

## Guardrails

- Monotonicity must survive: no change may let an object die and come back,
  or be born dead. See `docs/02-semantics.md`, "The one rule".
- Ownership order must survive: no change may make the order of a cascade,
  a scope exit or the program-end sweep depend on anything but attachment
  and creation order. See `docs/02-semantics.md`, "Cascading death".
- The collector's authority must survive: no change may promise a
  reachable death at a point other than after `collectgarbage("collect")`,
  and no change may give the runtime a strong reference to a collectable
  dependent. See `docs/02-semantics.md`, "Reachability is the collector's".
- If a change needs any guardrail relaxed, stop and ask the human.
