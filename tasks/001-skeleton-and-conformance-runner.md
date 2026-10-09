---
id: 001
title: Skeleton, `make test`, conformance runner, pass-through transpiler for plain Lua
status: in-progress
depends: []
branch: task/001-skeleton-and-conformance-runner
pr:
commits:
review:
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
  `local x = = 1` raises `unexpected symbol near '='`; `x @ y` raises
  `unexpected symbol near '@'`.
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
  grammar, so this affects only the interval until then.)
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

## Review log
