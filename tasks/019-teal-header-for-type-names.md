---
id: 019
title: Teal front end: a chunk that names `lifetime` only inside a type gets the header
status: review
depends: [018]
branch: task/019-teal-header-for-type-names
pr: https://github.com/bilbosz/lua-lifetime/pull/55
commits:
review: APPROVE (round 1)
---

## Goal

A `.tlt` chunk whose only mention of `lifetime` is inside a type (`local
function f(r: lifetime.Reason)`, `self._period: lifetime.Token`, `x as
lifetime.Hook`) transpiles to Teal that begins with the header `local
lifetime = require("lifetime")`, so that `tl` resolves the type through the
declaration file `lifetime/init.d.tl`. Today the header is emitted only
when `lifetime` is named as a value, and `tl` reports `unknown type
lifetime.Reason` for such a chunk.

## Spec

- `docs/04-transpiler.md`, "The generated chunk header": "Every output
  chunk that uses the extension begins with one line that binds the
  runtime … so that `lifetime.*` in the source … resolves without
  installing globals"; "a chunk that uses no extension syntax and does
  not name `lifetime` gets no header and is its input unchanged"; "A
  source file that shadows `lifetime` gets what it wrote."
- `docs/04-transpiler.md`, "The Teal front end", "Types pass through": a
  type is "kept as the tokens they were, with their lines, and written
  back unchanged; the transpiler never interprets a type, `tl` does". A
  type written back unchanged that reads `lifetime.Reason` names
  `lifetime`; it resolves only if the header binds the local.
- `docs/04-transpiler.md`, "The Teal front end", "The declaration file":
  "`lifetime/init.d.tl` declares the `lifetime` table … `tl` finds it next
  to the runtime through the `?/init.lua` entry of the path".
- `docs/05-decisions.md`, "The Teal front end is a dialect of the shared
  transpiler": the dialect's hooks decide where Teal syntax starts; the
  type tokens are the dialect's to inspect.

## Acceptance criteria

- `lifetime/teal.lua` (or the emitter through the dialect): a Teal chunk
  that names `lifetime` inside any type position (a parameter, a return
  list, a local's or global's annotation, a record or interface field, an
  `as` or `is` operand, a type argument, a type declaration body) and
  nowhere else gets the header line `local lifetime = require("lifetime")`
  (and nothing else bound, since it calls no runtime function), on line 1
  as "The generated chunk header" says.
- A chunk that names `lifetime` nowhere, in no value and no type, is still
  its input unchanged (`examples/teal/plain.tlt` keeps its `.expected`).
- A chunk that shadows `lifetime` (`local record lifetime`, `local
  lifetime = …`) is unchanged in behaviour: "gets what it wrote".
- `lifetime run` on the reproducer below prints `destroy` and exits 0.
- `docs/04-transpiler.md`, "The Teal front end", "Types pass through"
  gains one sentence saying that `lifetime` named inside a type counts as
  naming it for the header. No other document changes.
- `make test` and `make lint` green under both interpreters, with `tl`
  installed; the Teal conformance examples unchanged.

## Test cases

1. `tests/test-teal.lua`: building
   ```
   local function f(r: lifetime.Reason)
     print(r)
   end
   f("destroy")
   ```
   yields Teal whose first line starts with `local lifetime =
   require("lifetime");` followed by the source's first line, and
   `lifetime run` of it (through `cli` in the test, as the other Teal
   command tests do) prints `destroy`.
2. A record field type: `local record R\n  tok: lifetime.Token\nend` alone
   gets the header; the same with `local record lifetime … end` first does
   not add a second binding and compiles.
3. `as`: `local t = x as lifetime.Token` alone gets the header.
4. Negative: `local function f(r: Reason) print(r) end` (no `lifetime`
   anywhere) is its input unchanged.
5. `examples/teal/*.tlt.expected` unchanged. New `examples/teal/typed_reason.tlt`
   + `.expected`: a record with a `__destroy` typed `function(self: R,
   reason: lifetime.Reason)` that prints the reason, an instance anchored
   `@ lifetime.scope` in a function (the anchor is extension syntax, so the
   header is expected anyway; what the example pins is that `tl` accepts the
   typed destructor), and a second, plain function `local function show(r:
   lifetime.Reason) print("reason " .. r) end` called with `"anchor"` — the
   expected output is the destructor's line then `reason anchor`. The unit
   test in `tests/test-teal.lua` (case 1) is the one that pins the header
   coming from the type mention alone.

The sentence most likely to be misread: "does not name `lifetime`" taken
to mean "as a value"; cases 1 and 4 pin both sides.

## Performance

The decision is per chunk and is taken from tokens the dialect already
reads when it keeps a type; no new pass over the token list and no
per-token cost in the Lua path (`.lt` files have no types). `make bench
BASE=master` twice: `build/teal-5000` and `build/extension-5000` within
the threshold of `bench/README.md`.

## Out of scope

- Changing what the header binds beyond `lifetime` for this case.
- Any change to the Lua dialect or to the runtime.

## Spec issues found

1. A *global* type named `lifetime` (`global record lifetime … end`) is
   not a shadowing local, so a `lifetime.T` read after it in the same
   chunk now gets the header, and `tl` then rejects the chunk: "cannot
   define a global when a local with the same name is in scope" at the
   declaration and "unknown type lifetime.T" at the use. Before this
   task the same chunk had no header and compiled. (The same `tl` error
   already met a chunk that names `lifetime` as a value and declares a
   `global record lifetime`.)
   This follows the value rule of docs/04-transpiler.md, "The generated
   chunk header" ("An assignment to the global `lifetime` in a
   transpiled chunk assigns the header's local … a program that wants
   the global sets `_G.lifetime`"), but types have no `_G.` spelling, so
   a program cannot ask for the global type. The spec does not say
   whether a global type declaration shadows. Implemented: it does not
   (same as a global value); the self-reference inside the global
   record's own body is still the record's. Not blocking: no example or
   test uses a global type named `lifetime`.

## Review log

### Round 1: APPROVE

Suite 428/428 under lua5.1 and luajit, conformance 91/91 (the Teal
examples under both, `typed_reason` included), the Treflove trial 8/8,
lint clean; `make bench BASE=origin/master` twice (the local `master`
ref is stale): `build/teal-5000` and `build/extension-5000` within the
threshold, no benchmark marked in both invocations. Findings: F1 (a
nested `type lifetime = lifetime.Token` hid the runtime's name on its
own right-hand side) and F3 (examples/README.md names
`typed_reason.tlt`) applied by the implementer in the approval round;
F2 (a `global record lifetime` chunk with type-only uses now gets the
header) recorded under "Spec issues found" for the human.
