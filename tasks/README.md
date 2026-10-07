# Tasks

One file per unit of work, `NNN-slug.md`, created with `/create-task` from
`TEMPLATE.md`. Ids are permanent and never reused.

## Lifecycle

```
todo → in-progress → review → done      (review = approved, PR open)
                  ↘ blocked        (spec gap or open question; needs a human)
todo → cancelled                   (with a one-line reason)
```

The `status` field in the frontmatter is the single source of truth. The
dispatch skill (`/dispatch`) moves tasks through these states and records the
branch, the merge commit and the final review verdict. Humans may do the same
by hand.

## Frontmatter

| Field | Meaning |
| --- | --- |
| `id` | Three digits, matches the filename. |
| `title` | Short imperative sentence. |
| `status` | One of the states above. |
| `depends` | List of task ids that must be `done` first. |
| `branch` | `task/NNN-slug` once started. |
| `pr` | URL of the pull request to `master` once opened. |
| `commits` | Merge commit hash once done. |
| `review` | Final verdict and round, e.g. `APPROVE (round 2)`. |

## Sections

Every section in the template is mandatory. *Acceptance criteria* must cite
the spec; *Test cases* must give exact expected output including destruction
order, with reachable deaths pinned by `collectgarbage("collect")`;
*Performance* must name the hot path, its benchmark, and what stays free.
*Spec issues found* and *Review log* start empty and are appended to
during implementation and review.

## Current backlog

| Id | Title | Depends |
| --- | --- | --- |
| 001 | Skeleton, `make test`, conformance runner, pass-through transpiler for plain Lua | |
| 002 | Runtime: anchors, dependents inside the anchor, `destroy`, cascade order, tombstones, `destroyerror` | 001, 010 |
| 003 | Runtime: scope records, `caller` depth counter, hooks | 002 |
| 004 | Runtime: `lifetime.token`, `lifetime.pin`, `lifetime.alive`, reachable-only destructors via `newproxy`, `collectgarbage` | 002 |
| 005 | Lexer and parser: Lua 5.1 plus `@`, the list form, the hook operator `!@`, `scope`, `caller` | 001, 010 |
| 006 | Emitter: `@` and lists, hooks (`!@`), block epilogues on every exit path, the `pcall` error path, `caller` prologue and epilogue | 003, 005 |
| 007 | CLI `lifetime build` and `lifetime run`; the rockspec installs and runs | 006 |
| 008 | Port the conformance examples from `xd/examples/`; document each deviation in `docs/07-conformance.md` | 004, 007 |
| 009 | Treflove trial: transpile the sessions-and-listeners slice described in `xd/docs/notes/xd-in-treflove.md` and run it under LuaJIT | 008 |
| 010 | Benchmark harness: `make bench`, comparison with plain Lua and with `master` | 001 |

Keep this table in sync when adding tasks.
