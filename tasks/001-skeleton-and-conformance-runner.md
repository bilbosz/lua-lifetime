---
id: 001
title: Skeleton, `make test`, conformance runner, pass-through transpiler for plain Lua
status: review
depends: []
branch: task/001-skeleton-and-conformance-runner
pr: https://github.com/bilbosz/lua-lifetime/pull/6
commits:
review: APPROVE (round 2)
---

## Goal

The pipeline runs end to end on a program that uses no extension syntax:
`lifetime/lexer.lua` tokenises Lua 5.1, `lifetime/parser.lua` builds the AST,
`lifetime/emit.lua` writes it back out, and `lifetime/cli.lua`'s `build`
chains the three. A `.lt` file with no extension syntax transpiles to itself
modulo whitespace, and the conformance runner is green on `examples/plain.lt`
under every interpreter found. The bootstrap's placeholder `build`, which
returns the source unchanged, is replaced by the real round trip.

## Spec

- `docs/04-transpiler.md`, "Pipeline": "`lifetime/cli.lua`: the pipeline as
  one function, `build(source, chunkname)`"; "A plain Lua chunk with no
  extension syntax transpiles to itself modulo whitespace (task 001, the
  pass-through)"; "The emitter keeps every statement on its source line".
- `docs/04-transpiler.md`, "Grammar": Lua 5.1 as in `lparser.c` and the
  manual's §8. The additions are task 005; this task parses Lua 5.1 only
  and reports `@` and `!@` as syntax errors in Lua's own words
  (`unexpected symbol near '@'`).
- `CLAUDE.md`, "Rules that apply to everyone", rule 2 (every example has
  an `.expected`; the runner passes under every interpreter found) and
  rule 8 (`make test` runs everything; `make lint` clean).
- `CLAUDE.md`, "Technical decisions": no dependencies; hand-written lexer
  and parser; AST with a line on every node.
- `examples/README.md`: the `.expected` contract, the chunk name
  `examples/NAME.lt`, the `!error:` line, the exit status.

## Acceptance criteria

- `lifetime/lexer.lua` exports `tokenize(source, chunkname)` returning an
  array of tokens `{type, value, line}` for the whole of Lua 5.1: names,
  keywords, numbers (decimal, hex, exponent), strings (both quotes, every
  escape of §2.1, long brackets of any level), long comments, and every
  operator and punctuation of §8. A malformed token raises
  `chunkname:line: <message>` with Lua's wording (`unfinished string`,
  `malformed number`).
- `lifetime/parser.lua` exports `parse(tokens, chunkname)` returning an
  AST that covers every production of §8, with `line` on every node. A
  syntax error raises `chunkname:line: <message> near '<token>'` in Lua's
  wording.
- `lifetime/emit.lua` exports `emit(ast)` returning Lua source in which
  every statement starts on the line its node records, so that a chunk
  parsed and emitted again gives the same AST (modulo whitespace), and
  `loadstring` of the output reports the same line for an `error()` call
  as `loadstring` of the input.
- `lifetime/cli.lua` exports `build(source, chunkname)` returning the
  emitted source, or `nil, message` on a syntax error.
- The conformance runner (`tests/conformance.lua`) uses `build`, writes
  the output under `build/examples/NAME.lua`, runs it under every
  interpreter found among `lua5.1` and `luajit` with chunk name
  `examples/NAME.lt`, and compares standard output byte for byte. Fails
  loudly when no interpreter is found. (The bootstrap provides this; the
  task keeps it working with the real `build`.)
- `make test` is green under both interpreters; `make lint` is clean.
- `examples/plain.lt` is unchanged and still passes.

## Test cases

- `tests/test-lexer.lua`: a string containing every token class, checked
  token by token with lines; `"abc` raises `unfinished string`; `0x` raises
  `malformed number`.
- `tests/test-parser.lua`: a chunk using every statement and expression
  form of §8 (including `function t.a.b:c()`, `for k, v in pairs(t)`,
  `a.b[c] = d, e`, `repeat … until`, varargs, method calls, string-call
  and table-call sugar, every operator at every precedence level) parses;
  `local x = = 1` raises `unexpected symbol near '='`; in Lua's wording,
  the statement `x @ y` raises `'=' expected near '@'` and the expression
  form `local z = x @ y` raises `unexpected symbol near '@'`.
- `tests/test-emit.lua`: parse → emit → parse gives an equal AST for the
  chunk above; the emitted source of a chunk whose line 7 is
  `error("boom")` raises `examples/x.lt:7: boom` when loaded with that
  chunk name and run.
- Conformance: `examples/plain.lt` passes under both interpreters.

The sentence most likely to be misread: "transpiles to itself modulo
whitespace". Whitespace *and* line structure: the output must keep each
statement on its source line, not merely be semantically equal. The emit
test with `error("boom")` on line 7 pins it.

## Performance

Hot path: none at run time; the transpiler itself. Free: plain Lua must
come out byte-identical in structure, so a program that does not use the
extension runs exactly as fast as before. No benchmark is required in this
task (task 010 adds the harness); record the time `cli.build` takes on the
largest file of the test corpus in the handoff, as a first baseline.

## Out of scope

- Any extension syntax (`@`, `!@`, `lifetime.scope`): task 005.
- The runtime: tasks 002 to 004.
- `lifetime run`, `lifetime build` as a command, the rockspec: task 007.
- Lua 5.2+ syntax (`goto`, `::label::`) in the input: task 005 covers
  LuaJIT's `goto`.

## Spec issues found

- **`x @ y` and Lua's wording (task text vs. Lua 5.1).** *Test cases*
  says `x @ y` raises `unexpected symbol near '@'`. As a statement,
  Lua 5.1 and LuaJIT both report `t:1: '=' expected near '@'`: `x`
  starts an assignment and `@` is not `=`. Lua says `unexpected symbol
  near '@'` only where `@` starts an expression or a statement
  (`local z = x @ y`, `f() @ x`). The acceptance criteria require "Lua's
  own words", and so does `CLAUDE.md` rule 1, so the parser follows Lua.
  `tests/test-parser.lua` pins both messages, and `tests/test-cli.lua`
  pins them through `build`. Decision needed: correct the test-case
  sentence. (Task 005 replaces both messages with the extension's
  grammar, so this affects only the interval until then.) Resolved in
  review round 1: the *Test cases* sentence now gives Lua's wording.
- **Where Lua 5.1 and LuaJIT lex differently (the docs are silent).**
  `docs/04-transpiler.md` says "Lua 5.1 (`lparser.c`, the manual's §8)".
  Three lexical points depend on the implementation, and the manual's
  §2.1 does not decide them:
  - `[[` inside a level-0 long string: Lua 5.1 raises `nesting of [[...]]
    is deprecated` (LUA_COMPAT_LSTR); LuaJIT accepts it.
  - an unknown escape such as `\q`: Lua 5.1 accepts it as `q`; LuaJIT
    raises `invalid escape sequence`.
  - a decimal escape above 255: Lua 5.1 says `escape sequence too large`;
    LuaJIT says `invalid escape sequence`.

  The lexer accepts what either interpreter accepts and uses Lua 5.1's
  wording where it rejects. The output keeps the spelling and line of
  every token, so an interpreter that rejects a construct does so when it
  loads the output, at the same line. No decision is needed unless the
  project wants the transpiler to reject the intersection instead.

  LuaJIT also has lexical extensions that Lua 5.1 lacks; the lexer
  follows Lua 5.1 and rejects them or reads them differently (found in
  review round 1):
  - the escapes `\z`, `\x41` and `\u{...}`;
  - the numeral suffixes `1LL`, `1ULL` and `1i`;
  - bytes >= 128 in identifiers;
  - a UTF-8 BOM and a `#!` first line, both of which LuaJIT skips.

  Task 005 decides whether any LuaJIT lexical extension beyond `goto` is
  in scope.

## Review log

### Round 1: REQUEST_CHANGES

Suite on `0deb6ee`: unit 44/44 under lua5.1 and luajit, conformance 5/5 under both, lint clean (16 files). `cli.build` on `lifetime/parser.lua`: lua5.1 7.5 ms, luajit 3.6 ms with `jit.off`, 27 ms without, `luajit -joff` 3.7 ms.

- F1 (blocking): the constructor lookahead makes the parser reject `x = { f\n(x) }`, which Lua 5.1 and LuaJIT accept. In `lparser.c`, `constructor` calls `luaX_lookahead` on a Name, which advances `linenumber` past the looked-at token, so when `funcargs` later sees a `(` that was itself the lookahead token, `lastline == linenumber` and no ambiguity is reported. Only the token immediately after the looked-at Name is affected: `{ f.g\n(x) }` stays ambiguous. Fix: record the looked-at token's index in `constructor`'s not-followed-by-`=` branch and skip the ambiguity check in `funcargs` for that one position. Tests: `x = { f\n(x) }` and `t = { f\n\n(1) }` parse; `x = { f\n(x) = 1 }` gives `t:2: '}' expected (to close '{' at line 1) near '='`; `x = { f.g\n(x) }` still gives `t:2: ambiguous syntax (function call x new statement) near '('`; `x = { f\n(x) }` added to the emit round trip.
- F2 (non-blocking): the `jit.off` comment cites no reproducible benchmark; justified by the reviewer's own measurement. To be named when task 010's transpiler benchmark exists.
- F3 (non-blocking): unused exports `lexer.KEYWORDS`, `parser.LEFT`, `parser.RIGHT`, `parser.UNARY_PRIORITY`.
- Design points accepted: the `lines` array on token-owning nodes is the convention for tasks 005 and 006, to be stated in `docs/04-transpiler.md`, "Pipeline"; `jit.off(true, true)` in parser and emitter stays (transpiler only, output unchanged, measured 7x).
- Task text: the `x @ y` test-case sentence corrected to Lua's wording; spec issue 2 extended with the LuaJIT-only lexical extensions for task 005.

### Round 2: APPROVE

Suite on `587a013`: unit 46/46 under lua5.1 and luajit, conformance 5/5 under both, lint clean (16 files). `cli.build` on `lifetime/parser.lua`: lua5.1 7.8 ms, luajit 3.7 ms steady.

- F1 fixed in `f920b06` as described: `constructor` records the looked-at token's index, `funcargs` skips the ambiguity check for that one position. Traced by hand against `lparser.c`; 19 nested-constructor probes and the 151-chunk differential batch give 0 mismatches against `loadstring` under lua5.1 (the 10 luajit mismatches are the LuaJIT-only lexical extensions recorded under *Spec issues found*). Tests pin the three error forms, the accepting forms and the emit round trip; a mutation check (skip clause removed) fails 3 cases.
- F3 fixed in `8c666a5`: the four exports removed, kept as module locals; nothing referenced them.
- Docs (`587a013`): wording only in `docs/04-transpiler.md`, "Pipeline".
- F2 carried, non-blocking: the `jit.off` comment names task 010's transpiler benchmark once it exists.
- Notes for later tasks: 005 decides the LuaJIT lexical extensions listed above; 007 strips a `#!` first line before `build` as `luaL_loadfile` does and replaces the chunkname-prefix test in `cli.build`'s error classification with a marker; 010 names the transpiler benchmark (`cli.build` on the largest corpus file; baselines lua5.1 7.5 to 7.8 ms, luajit 3.6 to 3.7 ms).
