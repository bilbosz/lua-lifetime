---
id: 020
title: Teal front end: a `Name ':'` table item that is not a typed field is an expression
status: in-progress
depends: [018]
branch: task/020-teal-table-item-method-call
pr:
commits:
review:
---

## Goal

In a `.tlt` file a table constructor item that starts with `Name ':'` but
is not Teal's typed field (`Name ':' type '=' exp`) parses as the
expression it is, a method call: `{ r:get() }`, `{ 1, r:get() }`,
`{ obj:method(a), x = 1 }`. Today the dialect reads the `:` as the start
of a typed field and reports `'=' expected near '('`, while `tl` accepts
the same source (found while migrating Treflove, `game/page/page.tlt`,
which binds the results to locals as a workaround).

## Spec

- `docs/04-transpiler.md`, "Grammar": the constructor is lparser.c's,
  `'{' [field {fieldsep field} [fieldsep]] '}'`, with `field ::= '[' exp ']'
  '=' exp | Name '=' exp | exp`; a method call `prefixexp ':' Name args`
  is an `exp`.
- `docs/04-transpiler.md`, "The Teal front end", "Types pass through": a
  type after "a table field's name" is kept as its tokens; the item is
  Teal's `Name ':' type '=' exp` (tl.tl, `parse_table_item`: it parses the
  type and, when no `=` follows, backtracks and reads the item as an
  expression).
- `docs/05-decisions.md`, "The Teal front end is a dialect of the shared
  transpiler": the dialect's hooks decide where Teal syntax starts; the
  shared parser's constructor calls the hook at `Name ':'`.

## Acceptance criteria

- `lifetime/parser.lua`, `constructor` (or the dialect hook it calls):
  at `Name ':'` the typed-field reading is tried, and when no `=` follows
  the type the parser backtracks to the Name and reads the item as a
  positional expression, exactly as tl does; the generated Teal is the
  source's tokens unchanged. A typed field `{name: T = v}` still parses
  and is written back as it was.
- The Lua dialect is unchanged: `{ r:get() }` in a `.lt` file already
  parses (no dialect, no `:` branch) and keeps doing so; `bench/`'s
  `build/extension-5000` within the threshold.
- `make test` and `make lint` green under both interpreters with `tl`
  installed; no `.expected` changes.

## Test cases

1. `tests/test-teal.lua`: `build("local t = {\n    r:get()\n}")` through
   the Teal dialect returns the source unchanged (no header, no error);
   `{ 1, r:get() }`, `{ r:get(), x = 1 }`, `{ r:get(1, 2), s:put() }` and a
   multi-line constructor whose method call sits on its own line likewise.
2. A typed field still works: `{ n: integer = 1 }` and `{ f: function():
   number = function(): number return 1 end }` round-trip unchanged; a
   typed field followed by a method call item `{ n: integer = 1, r:get() }`
   too.
3. A malformed typed field keeps its error: `{ n: integer 1 }` is reported
   as before (`'=' expected near '1'`), not silently read as an
   expression — the backtrack applies only when the item does not start a
   valid `Name ':' type '='`, so compare with tl: tl reports the error at
   the same place; match tl's behaviour and say which in the test.
4. With `tl` installed: `lifetime run` of the reproducer below prints `2`.

   ```
   local record R
       get: function(self): number, number
   end
   local r: R = { get = function(_self: R): (number, number) return 1, 2 end }
   local t = {
       r:get()
   }
   print(#t)
   ```

The sentence most likely to be misread: "a table field's name" in "Types
pass through" taken to mean every `Name ':'` in a constructor opens a type;
case 1 pins the method call.

## Performance

The constructor's `Name ':'` branch, Teal dialect only: one speculative
type parse per such item, as tl does; a `.lt` file never takes the branch.
`bench/bench-build.lua`: `build/teal-5000` and `build/extension-5000`
within the threshold of `bench/README.md`, `make bench BASE=origin/master`
twice.

## Out of scope

- Any other table-item form; the Lua dialect; the emitter.

## Spec issues found

## Review log
