---
id: 023
title: Rename: the metamethod `__lifetime_destroy`, the handler `lifetime_destroyerror`
status: review
depends: [022]
branch: task/023-rename-destroy
pr:
commits:
review: APPROVE (round 1)
---

## Goal

The two names a program defines for the runtime carry the library's name:
the destructor metamethod is `__lifetime_destroy` (was `__destroy`) and
the global error handler is `lifetime_destroyerror` (was `destroyerror`).
Nothing else changes: the semantics, the order, the reasons and the
messages are as before, but for the handler's prefix, which follows its
name.

## Spec

- `docs/05-decisions.md`, "The metamethod is `__lifetime_destroy`, the
  handler `lifetime_destroyerror`": the decision, at the human's request;
  the human carries it back to `xd`.
- `docs/02-semantics.md`, "`__lifetime_destroy` and reasons" (rule 1: "is
  looked up on the object's metatable at the moment of death") and
  "Errors in destructors and `lifetime_destroyerror`" ("The default
  writes `lifetime_destroyerror: <message>` and a traceback to `stderr`";
  "a global function, looked up raw in `_G`").
- Every other section of `docs/` that names either, renamed in place.

## Acceptance criteria

- The runtime reads `__lifetime_destroy` from the metatable and never
  `__destroy`; a metatable with only `__destroy` is a plain table to it.
- The runtime looks up `lifetime_destroyerror` raw in `_G` and never
  `destroyerror`; the default handler's prefix is
  `lifetime_destroyerror: `.
- `lifetime/init.d.tl` and `editor/luals/meta/lifetime.lua` name the new
  names; `trial/treflove` defines them.
- Every example's output is unchanged except
  `examples/destroy_errors.lt.expected`, whose handler prints its new
  name.
- `make test` green under `lua5.1` and `luajit`; `make lint` clean.

## Test cases

The existing suites, renamed: every destruction test defines
`__lifetime_destroy`; the error tests install `lifetime_destroyerror`.
One new case in `tests/test-runtime.lua`: an object whose metatable has
`__destroy` and not `__lifetime_destroy` is destroyed silently, and a
global `destroyerror` is not called for a destructor error while
`lifetime_destroyerror` is; the sentence most likely to be misread is
"looked up on the object's metatable at the moment of death": the case
adds `__lifetime_destroy` to the metatable after the attach and sees it
run.

## Performance

None: the names are string constants read at the moment of death and on
the error path; no path changes.

## Out of scope

- The string values of `getmetatable` (`"hook"`, `"token"`, `"scope"`,
  `"dead"`, `"lifetime"`), which name types and are not keys a program
  defines.
- The names of the generated chunk's locals (`__lt_attach`, ...), which
  are never visible to a program.

## Spec issues found

None.

## Review log

Round 1 (reviewer agent, 2026-10-19): APPROVE, no blocking finding.
`make test` 430/430 under lua5.1 and luajit, conformance 77/77 (the
Teal examples skipped: `tl` not installed, so the `.tlt` rename is
verified by reading), the trial, luals-check; `make lint` clean; `make
bench` on the branch and on a fresh worktree of master, each tree's own
files on its own runtime (`BASE=master` would run the branch's files on
a runtime that ignores the new name): every row with a destructor
within the noise band, the free paths at 1.0. Traced: the metamethod
read at the moment of death; a `__destroy`-only object silent on
destroy, at collection and as a dependent; a destructor error to the
default handler with its new prefix, a global `destroyerror` never
called. F1 (non-blocking): the new case said "a plain table" where it
meant "no destructor", and left the collector's leg untested; renamed
and extended after the review.
