---
id: 005
title: Lexer and parser: Lua 5.1 plus `@`, the list form, the hook operator `!@`, `lifetime.scope`
status: done
depends: [001, 010]
branch: task/005-lexer-and-parser
pr: https://github.com/bilbosz/lua-lifetime/pull/18
commits: 10afecbbffe6183aa48c1ec204f9e35e6f9d2424
review: APPROVE (round 2)
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
  raises `')' expected near ','` (a nested list is not a list, it is
  Lua's parenthesised expression, which cannot hold a comma; Lua's
  wording for `x = (b, c)`).
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

- **`@ (a, (b, c))` and Lua's wording (task text vs. Lua 5.1).** The
  criterion says this raises `unexpected symbol near ','`. A nested list
  is Lua's parenthesised expression (the criterion says so too), and for
  that Lua 5.1 and LuaJIT both report `')' expected near ','` (`x = (b,
  c)`), with `(to close '(' at line N)` when the `(` is on an earlier
  line. The parser follows Lua (CLAUDE.md, rule 1), as task 001 did for
  `x @ y`; `tests/test-parser.lua` pins the message. Decision needed:
  correct the criterion's wording.
- **A statement carries one operator.** The grammar's `stat ::= prefixexp
  '@' anchor | prefixexp '!@' anchor | functiondef '!@' anchor` has no
  chain, so `x @ a @ b` and `f !@ a @ b` as statements are syntax errors
  (`unexpected symbol near '@'` at the second operator); as expressions
  they chain (`local m = f !@ a @ b` is `Anchor(Hook(f, a), b)`). The
  parser follows the grammar. If a statement should chain, the grammar
  needs `stat ::= prefixexp ('@' | '!@') anchor {('@' | '!@') anchor}`;
  the parser change is two lines. Question, current choice: no chain. Resolved on master (`8ee0825`, 05, "A statement chains `@` and `!@` like an expression"); round 2 implements the chain.
- **`{` after `lifetime.scope`.** `docs/04-transpiler.md`, "Grammar",
  defines the scope anchor as the spelling "with nothing after them that
  would continue a `prefixexp` (no `.x`, `[`, `(`, `:` or string
  argument)". A table argument (`lifetime.scope {…}`, a call) continues
  a prefixexp too, so the parser treats `{` like `(` and the string
  argument. Suggest adding `{` to the parenthesis; no decision needed.
- **Named hooks through `@` and parentheses.** "Named hooks" names the
  hook of `local NAME = f !@ …`. The parser also names it when the hook
  is moved or parenthesised in the bound value (`local h = f !@ a @ b`,
  `local h = (f !@ a)`), since the value bound is the hook in both. A
  hook anywhere else in the value (an argument, a table field, an
  operand) stays anonymous. Question, current choice: name through `@`
  and `( )`.
- **`lifetime.scope` followed by an operator in a list** (no decision
  needed, recorded so the reviewer can check the reading). The parser
  tries the scope anchor before `exp` in `anchoritem`, and an operator
  does not continue a prefixexp, so `x @ (lifetime.scope + 1)` and `x @
  (lifetime.scope or a)` are syntax errors (`')' expected near '+'`).
  Anchoring to an expression of the marker would raise at run time
  anyway (02, "Scopes: `lifetime.scope`").
- **For task 006: an anchor item is one value.** `x @ f()` and `x @ (a,
  f())` hold a call as the last item. Emitted as the last argument of
  `__lt_attach`, a call or `...` would pass all its results; 02,
  "Acquiring a lifetime", evaluates "each element", so the emitter has to
  truncate (parenthesise) a multi-value last item.
- **For task 007: the `#` first line.** The decision recorded on this
  branch (05, "The lexer accepts LuaJIT's lexical extensions") moves the
  skipping of a `#` first line into the lexer, which task 001's review
  had assigned to task 007's command.

## Review log

### Round 1: APPROVE

Suite on `cc0e598`: unit 85/85 under lua5.1 and luajit, conformance 5/5 under both, lint clean (23 files). `make bench BASE=master` (base `c57b6e2`): no benchmark SLOWER on two consecutive runs; `parse/lifetime-largest` marked in alternate luajit runs only, 1.018 with a 2 s budget; plain-path benchmarks unchanged. Bytecode identity of `cli.build` output for 24 repository files under both interpreters; 3200-chunk differential against `loadstring` under both: 0 mismatches. Every claim of the decision "The lexer accepts LuaJIT's lexical extensions" checked against both interpreters and confirmed; the rule applied consistently. Precedence, error texts, `lifetime.scope` by spelling (including across lines and after `local lifetime = t`), named hooks through `@` and parentheses, `goto`/labels: all as specified. Master's decision entries intact after the merge.

- F1 (non-blocking): the decision's "Not accepted" paragraph says accepting `0x1p-4` and `0x1.8` "would change a valid Lua 5.1 chunk"; neither appears in a valid 5.1 chunk (both are errors there); only `0x1..8` is the valid-chunk case. Reword: hex floats and binary exponents are not accepted because they would need a numeral delimiter that differs from Lua 5.1's, and `0x1..8` is the valid chunk that delimiter must keep.
- Orchestrator's settled items: nested-list wording follows Lua (task text corrected); statement chaining and `{` are the spec change on master (round 2 implements chaining); naming a hook through `@` and parentheses is correct.
- Reading fixed for `x @ (lifetime.scope).f`: a one-element parenthesised item followed by a suffix is Lua's parenthesised prefixexp (so the inner `lifetime.scope` is the ordinary marker, as `x @ (t).owner` is); stated in `docs/04`, "Grammar" (round 2, wording only).
- For task 006: `x @ (a)` (`list = true`) and `x @ a` emit identically, and a one-element `(lifetime.scope)` item the same as the bare one; a call or `...` as the last anchor item is truncated to one value. For task 007: the `#` first line is the lexer's; `lifetime build` output has an empty first line in that case.

### Round 2: APPROVE

Suite on `b6f936a`: unit 95/95 under lua5.1 and luajit, conformance 5/5 under both, lint clean (23 files). Bytecode identity of `cli.build` output for 24 repository files; token-mutation differential against `loadstring` under both interpreters, 1600 chunks each, 0 mismatches. Statement chaining traced against `docs/04`, "Grammar": `anchor_statement` is `expr()`'s loop, the node tagged by the outermost operator, the `function (` form still requiring `!@` first; ten uncovered chained programs behave as the grammar reads them. Merge verified: master's four decision entries intact and first; `docs/04` holds master's EBNF, bullet and `{` plus the branch's `goto` bullet. F1's rewording and the `docs/04` sentence are wording only. No findings.

- For task 006: `x @ (a)` and `x @ a` emit identically, a one-element `(lifetime.scope)` item the same as the bare one; a call or `...` as the last anchor item is truncated to one value; a `HookStat` may wrap a chain whose first operator is `@`; the placeholder tests in `tests/test-cli.lua` and `tests/test-emit.lua` ("until task 006 …") are replaced, not deleted silently. For task 007: the `#` first line is the lexer's.
