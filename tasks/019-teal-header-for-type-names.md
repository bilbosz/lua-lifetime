---
id: 019
title: Teal front end: a chunk that names `lifetime` only inside a type gets the header
status: todo
depends: [018]
branch:
pr:
commits:
review:
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
5. `examples/teal/*.tlt.expected` unchanged; add
   `examples/teal/typed_reason.tlt` + `.expected`: a destructor typed with
   `lifetime.Reason` whose module names `lifetime` nowhere else, printing
   the reason of one `lifetime.destroy`… (careful: that call names
   `lifetime` as a value; the example must keep the type as the only
   mention — e.g. the destroy happens in a block exit: `local x = make() @
   lifetime.scope` is extension syntax, which already triggers the header.
   Use a scope exit so the header comes from the type mention alone is not
   possible; make the example a module-level function whose reason type is
   the only `lifetime` and let the object die at program end with reason
   `"exit"`, pinned by the expected output).

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

## Review log
