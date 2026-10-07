---
id: 005
title: Lexer and parser: Lua 5.1 plus `@`, the list form, the hook operator `!@`, `scope`, `caller`
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
the hook operator `!@` (expression and statement, with the name of its
binding target for named hooks), plus
LuaJIT's `goto` and labels in the input. Before writing the parser, the
implementer settles "Reserved words" in `docs/06-open-questions.md` with
the human (an open point this repository owns) and records the answer in
`docs/05-decisions.md` on the task branch.

## Spec

- `docs/04-transpiler.md`, "Grammar": the EBNF; "`@` has the lowest
  precedence of any operator and is postfix"; "`!@` has the precedence
  and the right operand of `@`"; `!@` is one token; the `!=` error; a
  statement may start with `function (`; "`@()` is a syntax error. Lists
  do not nest"; reserved words.
- `docs/02-semantics.md`, "Acquiring a lifetime: the `@` operator": the
  statement form's left side must be a `prefixexp`; `x @ (a)` is `x @ a`;
  `x @ (cond and a or b)` is a one-element list.
- `docs/02-semantics.md`, "Scopes: `scope` and `caller`": "using them
  anywhere but after `@` (including inside the list form) is a syntax
  error".
- `docs/02-semantics.md`, "Hooks: the `!@` operator": the anchor is
  always written; the statement form's left side; "Named hooks": which
  binding targets name a hook.
- `docs/05-decisions.md`, "Hooks are made with the operator `!@`".
- `docs/05-decisions.md`, "Tokens are created by `lifetime.token`":
  there is no token syntax; `token` is an ordinary name.

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
- `f !@ a`, `f !@ scope`, `f !@ (a, b)`, `a or b !@ s` (hooking `a or
  b`), `local h = function() … end !@ scope` parse to `Hook` nodes with
  the same anchor items as `@`; `5 !@ a` is accepted by the parser (the
  runtime raises on the value); `f !@` with no anchor is a syntax error.
- `function() … end !@ scope` and `obj.close !@ obj` are statements; `a
  or b !@ s` at statement start is a syntax error (needs parentheses);
  `function () end` at statement start without `!@` is a syntax error.
- `f !@ a @ b` is `Anchor(Hook(f, a), b)`.
- A `Hook` node that is the value bound to `local NAME`, `NAME` or
  `t.NAME` records `NAME`; one bound to `t[k]`, passed as an argument, or
  standing as a statement records none. In `local a, b = f !@ x, g !@ y`
  the two nodes record `a` and `b`.
- `!@` is one token; `! @` is a syntax error; `a != b` raises
  `unexpected symbol near '!' (use '~=' for inequality)`.
- `defer` is an ordinary name: `local defer = 1` parses.
- `token` is an ordinary name: `local token = 1` and
  `lifetime.token("p") @ a` parse as Lua and an `@`.
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
- A precedence case: `x + y !@ s` hooks `x + y` (the runtime will reject
  the number; the parser does not); `(f @ a) !@ s` hooks the anchored
  function.

The sentence most likely to be misread: "`!@` has the precedence and the
right operand of `@`", under which `!@` binds to the whole expression on
its left, exactly as `@` does. The `a or b !@ s` case pins it.

## Performance

Hot path: the transpiler, not the program. Benchmark: lex and parse time
of the largest file in the corpus, recorded in `bench/` so later parser
changes can be compared. Must stay free: nothing at run time.

## Out of scope

- Code generation: task 006.
- Any runtime behaviour.

## Spec issues found

## Review log
