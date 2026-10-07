---
id: 005
title: Lexer and parser: Lua 5.1 plus `@`, the list form, `defer`, `scope`, `caller`, the token declaration
status: todo
depends: [001, 010]
branch:
pr:
commits:
review:
---

## Goal

The lexer and parser of task 001 accept the whole extended grammar of
`docs/04-transpiler.md` and produce AST nodes for `@` (expression and
statement, single anchor and list, `scope` and `caller` as anchors),
`defer` (expression and statement), and the `token` declaration, plus
LuaJIT's `goto` and labels in the input. Before writing the parser, the
implementer settles "Reserved words" in `docs/06-open-questions.md` with
the human (an open point this repository owns) and records the answer in
`docs/05-decisions.md` on the task branch.

## Spec

- `docs/04-transpiler.md`, "Grammar": the EBNF; "`@` has the lowest
  precedence of any operator and is postfix"; "`defer` takes everything up
  to a `@`, a comma or a closing token"; "`@()` is a syntax error. Lists do
  not nest"; reserved words.
- `docs/02-semantics.md`, "Acquiring a lifetime: the `@` operator": the
  statement form's left side must be a `prefixexp`; `x @ (a)` is `x @ a`;
  `x @ (cond and a or b)` is a one-element list.
- `docs/02-semantics.md`, "Scopes: `scope` and `caller`": "using them
  anywhere but after `@` (including inside the list form) is a syntax
  error".
- `docs/02-semantics.md`, "Named tokens": `token Name [@ anchor]`.
- `docs/02-semantics.md`, "`defer` and hooks": `defer (f @ obj)` anchors
  the function; a function body is closed before an outer `@` is read.
- `docs/05-decisions.md`, "Tokens are declared with `token NAME`".

## Acceptance criteria

- `e @ a`, `e @ (a, b, c)`, `e @ scope`, `e @ caller`, `e @ (a, scope)`
  parse to an `Anchor` node holding the expression and an array of anchor
  items, where `scope` and `caller` are marked items, not names.
- `a + b @ s` parses as `(a + b) @ s`; `f(x) @ s` as `(f(x)) @ s`;
  `x @ y @ z` as `(x @ y) @ z`.
- The statement form accepts a `prefixexp` on the left; `{} @ scope`
  alone is `unexpected symbol near '{'` or Lua's equivalent wording.
- `@()` raises a syntax error naming the empty list; `@ (a, (b, c))`
  raises `unexpected symbol near ','` (a nested list is not a list, it is
  Lua's parenthesised expression, which cannot hold a comma).
- `defer f`, `defer f @ a`, `defer a or b` (as `defer (a or b)`), `defer
  function() … end @ a`, `local h = defer f` parse to `Defer` nodes;
  `defer` alone or `defer 5` is accepted by the parser (the runtime raises
  on the value; `defer` with no expression is a syntax error).
- `token t` and `token t @ a` parse to a `Token` node declaring a local;
  under the settled reserved-words decision, `token` as a variable either
  still parses (contextual) or is a syntax error (reserved), and a test
  pins whichever it is.
- `scope` or `caller` anywhere but after `@` or inside the list form is a
  syntax error with Lua's wording.
- `goto name` and `::name::` parse (LuaJIT syntax) so the emitter can
  honour them; they are AST nodes with lines.
- Every line of every new node is recorded.
- `make test` green under both interpreters; `make lint` clean.

## Test cases

- `tests/test-parser.lua` gains one case per criterion above, comparing
  the AST shape (a small dumper in the test) and the error text.
- A comma case: `local x, y = {} @ (a, b), {} @ c` gives two values with
  two and one anchor items.
- A precedence case: `defer f @ a` is `Defer(f)` under `Anchor`; `defer (f
  @ a)` is `Defer(Anchor(f, a))`.

The sentence most likely to be misread: "`defer` takes everything up to a
`@`, a comma or a closing token", under which `defer a or b` is one hook
on the value of `a or b`, not `(defer a) or b`. The `defer a or b` case
pins it.

## Performance

Hot path: the transpiler, not the program. Benchmark: lex and parse time
of the largest file in the corpus, recorded in `bench/` so later parser
changes can be compared. Must stay free: nothing at run time.

## Out of scope

- Code generation: task 006.
- Any runtime behaviour.

## Spec issues found

## Review log
