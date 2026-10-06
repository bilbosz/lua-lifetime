---
name: dispatch
description: Drive the implement-then-review loop for tasks in tasks/. Picks ready tasks, runs the implementer agent on a task branch, runs the reviewer agent on the result, iterates on findings until APPROVE, merges to master, and updates task status. Use to make progress on the backlog.
---

# Dispatch tasks

You are the orchestrator. You do not write runtime or transpiler code and you
do not review it; you run the two agents that do, move work between them, and
keep `tasks/` and `master` truthful.

## Selecting work

1. List tasks with `status: todo` whose every `depends` entry is `done`.
2. If the user named a task, take that one (and refuse if its dependencies are
   not done; say which). Otherwise take the lowest id.
3. Run **one task at a time** unless the user asked for parallel work and the
   tasks touch disjoint files. Parallel implementers on overlapping files
   produce merge conflicts that cost more than the time saved.

## One task, one loop

For task `NNN`:

1. **Mark it.** Set `status: in-progress` and `branch: task/NNN-slug` in the
   task file. This is the first commit on the task branch itself
   (`[NNN] start`), not a commit to `master`.
2. **Implement.** Spawn the `implementer` agent with `isolation: "worktree"`
   and a prompt containing: the task id and path, the branch name, the
   instruction to invoke the `implement` skill, and (on later rounds) the
   reviewer's findings verbatim. Wait for its handoff.
3. **Check the handoff** before spending reviewer effort: the branch exists,
   `make test` and `make lint` were reported with the interpreters that
   ran, and the handoff lists what was left out. If the implementer reports
   red tests or an unaddressed blocking finding, send it back once with the
   specific gap; do not forward a known-broken branch to review.
4. **Review.** Spawn the `reviewer` agent with the task path, branch name, the
   implementer's handoff verbatim, and the instruction to invoke the `review`
   skill. Wait for its verdict.
5. **Branch on the verdict.**
   - `APPROVE`: go to *Pull request and merge*. If the verdict carries
     non-blocking findings, the orchestrator decides: take a round 2 on the
     same branch when a later task would inherit the finding (a convention,
     an interface, an error format), queue a follow-up task when it is
     self-contained. Either way, record the findings in the review log.
     An architectural decision that is hard to revert (the state record
     layout, the generated code's shape, anything the docs do not settle)
     goes to the human first; everything else the orchestrator decides on
     the human's standing authority.
   - `REQUEST_CHANGES`: append the findings to the task file under
     *Review log* with the round number, set `status: in-progress`, and go
     back to step 2 with the findings in the implementer's prompt. Use
     `SendMessage` to the same implementer agent when it is still available
     so it keeps its context; otherwise spawn a fresh one.
   - `BLOCKED` (the reviewer found a spec gap or an open question): stop the
     loop, set `status: blocked`, record the reason, and report to the user.
     Do not resolve spec questions yourself. A question that touches a
     decision of `xd/docs/10-lua-lifetime-decisions.md` is for the human to
     carry back to `xd`.
6. **Round limit.** After three REQUEST_CHANGES rounds on the same task, stop
   and report to the user with the review log. Repeated findings mean the
   task is under-specified or mis-split, not that another round will fix it.

## Pull request and merge

`master` is never committed to directly; the task reaches it through a pull
request.

1. Confirm the reviewer ran `make test` and `make lint` and both were green
   on the branch head, and which interpreters ran.
2. On the task branch, set `status: review`, `review: APPROVE (round N)` and
   fill in the review log in the task file. Commit (`[NNN] approved`) and
   push the branch.
3. Open a pull request from `task/NNN-slug` to `master` with the GitHub tools
   available in the session (the `github` MCP `create_pull_request`, or
   `gh pr create`). Title: `[NNN] <task title>`. Body, in this order: the
   task's *Goal*; the spec sections relied on (from the handoff); the
   reviewer's verdict section and the trace from the final review; the
   rounds taken; anything under *Spec issues found*. Record the PR URL in the
   task file's `pr` field in a follow-up commit on the branch.
4. Merge the pull request with a **merge commit** (`merge_pull_request` with
   `merge_method: merge`, or `gh pr merge --merge`). Never squash or rebase;
   the review refers to the commits as they were. If the human has said they
   merge PRs themselves, stop here and report the URL instead.
5. Fetch `master`, run `make test` on it, and confirm green. If it is not,
   the merge brought in a conflict with a concurrent change: open a new task
   branch from `master`, fix, and go through review again. Do not fix on
   `master`.
6. Set `status: done` and `commits` to the merge commit hash. This edit is
   itself a change to `master`, so make it on a short `chore/NNN-done`
   branch and merge it through a pull request too, or batch it with the
   next task's start commit (step 1 of *One task, one loop*, which also goes
   through a `chore/` branch and PR).
7. Delete the task branch locally and remotely.
8. If the task file has entries under *Spec issues found*, create follow-up
   tasks or `/spec-change` entries for each and link them from the task.

## Reporting

After each task, one short message: task id and title, rounds taken, the PR
URL and merge commit, anything left under *Spec issues found*, and the next
ready task. Do not paste the diff or the review.
