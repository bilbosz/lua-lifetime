---
id: 005
title: Lexer and parser: Lua 5.1 plus `@`, the list form, the hook operator `!@`, `lifetime.scope`
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
statement, single anchor and list, `lifetime.scope` as an anchor matched
by spelling), the hook operator `!@` (expression and statement, with the
name of its binding target for named hooks), plus LuaJIT's `goto` and
labels in the input. The extension adds no reserved word
(`docs/05-decisions.md`, "The scope anchor is spelled `lifetime.scope`").

## Spec

- `docs/04-transpiler.md`, "Grammar": the EBNF; "`@` has the lowest
  precedence of any operator and is postfix"; "`!@` has the precedence
  and the right operand of `@`"; `!@` is one token; the `!=` error; a
  statement may start with `function (`; "`@()` is a syntax error. Lists
  do not nest"; `scopeanchor` matched by spelling before `prefixexp`; no
  reserved words.
- `docs/02-semantics.md`, "Acquiring a lifetime: the `@` operator": the
  statement form's left side must be a `prefixexp`; `x @ (a)` is `x @ a`;
  `x @ (cond and a or b)` is a one-element list.
- `docs/02-semantics.md`, "Scopes: `lifetime.scope`": the spelling is
  matched in anchor position, "whatever `lifetime` names at that point";
  anywhere else it is an ordinary expression; there is no `caller` anchor.
- `docs/02-semantics.md`, "Hooks: the `!@` operator": the anchor is
  always written; the statement form's left side; "Named hooks": which
  binding targets name a hook.
- `docs/05-decisions.md`, "Hooks are made with the operator `!@`".
- `docs/05-decisions.md`, "Tokens are created by `lifetime.token`":
  there is no token syntax; `token` is an ordinary name.

- `tasks/001-skeleton-and-conformance-runner.md`, *Spec issues found*,
  item 2: the lexical points where Lua 5.1 and LuaJIT differ and the
  LuaJIT-only lexical extensions (`\z`, `\x41`, `\u{...}`, `1LL`/`1ULL`/`1i`,
  bytes >= 128 in identifiers, a BOM, a `#!` first line). This task decides
  whether any of them beyond `goto` is in scope and records the answer in
  `docs/05-decisions.md`; task 001's lexer follows Lua 5.1 for all of them.
- `tasks/001-skeleton-and-conformance-runner.md`, review round 1: the AST
  records, on nodes that own tokens, the lines of those tokens (`lines`);
  new nodes of this task follow that convention so the emitter keeps every
  token on its line.

## Acceptance criteria

- `e @ a`, `e @ (a, b, c)`, `e @ lifetime.scope`, `e @ (a, lifetime.scope)`
  parse to an `Anchor` node holding the expression and an array of anchor
  items, where `lifetime.scope` is a marked item, not a field access.
- `e @ lifetime.scope.x`, `e @ lifetime.scope()` and `e @ lifetime.pin(a)`
  parse as `@` on an ordinary `prefixexp`; `local lifetime = t; x @
  lifetime.scope` still parses as the scope anchor (spelling, not
  binding).
- `scope` and `caller` are ordinary names: `local scope, caller = 1, 2`,
  `e @ lifetime.scope` and `e @ caller` parse as Lua and an `@` on the variable.
- `a + b @ s` parses as `(a + b) @ s`; `f(x) @ s` as `(f(x)) @ s`;
  `x @ y @ z` as `(x @ y) @ z`.
- The statement form accepts a `prefixexp` on the left; `{} @ lifetime.scope`
  alone is `unexpected symbol near '{'` or Lua's equivalent wording.
- `@()` raises a syntax error naming the empty list; `@ (a, (b, c))`
  raises `unexpected symbol near ','` (a nested list is not a list, it is
  Lua's parenthesised expression, which cannot hold a comma).
- `f !@ a`, `f !@ lifetime.scope`, `f !@ (a, b)`, `a or b !@ s` (hooking `a or
  b`), `local h = function() … end !@ lifetime.scope` parse to `Hook` nodes with
  the same anchor items as `@`; `5 !@ a` is accepted by the parser (the
  runtime raises on the value); `f !@` with no anchor is a syntax error.
- `function() … end !@ lifetime.scope` and `obj.close !@ obj` are statements; `a
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

Known from task 010's review, to measure with `make bench BASE=master`:
`jit.off(true, true)` in the parser costs about 25% on the small inputs
(`build/plain.lt`, `build/generated-5000`) under luajit while saving 7x
on `build/lifetime-largest`, and the lexer is superlinear on
`build/generated-5000` (about 13x the time for 8x the lines). Fix the
superlinearity if the lexer is touched anyway; otherwise record the
numbers in the handoff.

## Out of scope

- Code generation: task 006.
- Any runtime behaviour.

## Spec issues found

## Review log
