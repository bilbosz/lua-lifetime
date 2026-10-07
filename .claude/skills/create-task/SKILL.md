---
name: create-task
description: Turn a request, a spec section, or a review finding into one or more task files under tasks/ with spec citations, acceptance criteria and test cases. Use whenever new work needs to be queued for the implementer.
---

# Create a task

A task is one unit of work an implementer can finish in a single session and a
reviewer can judge against the spec without asking questions. If you cannot
write acceptance criteria that cite `docs/`, the task is not ready; file a
`/spec-change` or ask instead.

## Procedure

1. **Read the request** and the spec sections it touches. Find the exact
   sentences in `docs/` that define the behaviour. Note any sentence that is
   missing or ambiguous, and any entry of `docs/06-open-questions.md` the
   request touches: a task may not silently settle one.
2. **Check for overlap.** `grep -l` the key terms across `tasks/` to find
   existing tasks. Extend an existing `todo` task rather than creating a near
   duplicate. Never edit a task that is `in-progress`, `review` or `done`;
   create a follow-up instead.
3. **Size it.** One task should change one area and be reviewable as one diff.
   If the request needs more than one, split it and record the dependencies in
   each task's `depends` field. Order the split so each task leaves `make
   test` green on its own, under both interpreters.
4. **Pick the next id.** Three digits, zero padded, one higher than the
   highest existing id in `tasks/`.
5. **Write the file** from `tasks/TEMPLATE.md` as `tasks/NNN-slug.md`. Every
   section is mandatory. In particular:
   - *Spec* lists each cited section by file and heading, with the sentence
     quoted when it is short.
   - *Acceptance criteria* are checkable statements, one per line, each
     traceable to a cited sentence. "Works correctly" is not a criterion.
   - *Test cases* give concrete programs with their exact expected output,
     including destruction order and the statement at which each death
     happens; a reachable death is pinned with `collectgarbage("collect")`.
     At least one case must exercise the spec sentence most likely to be
     misread; say which one and why.
   - *Performance* names the hot path the task adds or changes, the
     benchmark under `bench/` that measures it (new or existing), and what
     must stay free: the code that does not use the feature. "None" is an
     answer only for a task with no runtime or generated-code path.
   - *Out of scope* names the adjacent things the implementer must not do.
6. **Set `status: todo`** and leave `branch`, `commits` and `review` empty.
7. **Update the backlog table** in `tasks/README.md`.
8. **Report** the task id, title and dependencies in one line each.

## Quality bar

The reviewer will judge the implementation against this file and nothing else
except the spec. Anything you leave implicit will be implemented however the
implementer guesses and then argued about in review. Write it down.

## Task ids

Ids are permanent. A cancelled task keeps its id with `status: cancelled` and
a one-line reason. Do not renumber.
