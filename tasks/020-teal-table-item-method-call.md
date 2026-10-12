---
id: 020
title: Teal front end: a `Name ':'` table item that is not a typed field is an expression
status: review
depends: [018]
branch: task/020-teal-table-item-method-call
pr: https://github.com/bilbosz/lua-lifetime/pull/56
commits:
review: APPROVE (round 1)
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
3. A malformed typed field is rejected, not silently read as an
   expression, and the error sits where tl puts it: the backtrack applies
   whenever the item does not start a valid `Name ':' type '='`, so the
   expression read fails at the first token that is not a method call.
   `{ n: integer 1 }` reads `function arguments expected near '1'` (tl:
   1:24, the `1`), `{ n: 1 }` reads `'<name>' expected near '1'` (tl:
   1:16), `{ n: T.x }` near `.`, `{ n: Box<Box<integer>> }` near `<`, in
   Lua's wording for the construct that fails there; `{ n: integer = }`
   commits to the typed field and reads `unexpected symbol near '}'`. (As
   written at creation this case expected `'=' expected near '1'`, which
   contradicted "exactly as tl does"; amended at review.)
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

### Round 1: APPROVE

Head `fb5e917`. `make test`: unit 433/433 under `lua5.1` and `luajit`,
conformance 91/91 under both (the Teal examples included), trial 8/8,
luals-check green; `make lint` clean over 48 files. `make bench
BASE=origin/master BENCH_FILES=bench/bench-build.lua` twice: no `SLOWER`
mark; `build/extension-5000` 0.96-1.04, `build/teal-5000` 0.92-1.07,
`build/teal-fields-5000` 0.98-1.01; the implementer's single run-1 mark on
luajit `build/extension-5000` did not reproduce in three later runs
(noise under the two-run rule). The backtrack was traced against tl's
`read_table_item`: pos/tok restore, no side effect of a discarded type
read (the only token write, the `>>` split, can never be reached by both
reads), no header leak from a discarded Raw.

- F1 (non-blocking): no byte-for-byte round trip pinned a typed field
  after a backtracked item. Applied by the orchestrator in the approval
  commit (two cases in `METHOD_CALL_ITEMS`).
- F2 (non-blocking): the task's test case 3 expected `'=' expected near
  '1'`, contradicting "exactly as tl does"; the implementation matches
  tl's position with Lua's wording. The case is amended above.
