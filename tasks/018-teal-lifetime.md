---
id: 018
title: teal-lifetime: the Teal front end, Teal output, the `lifetime` declaration file and the second rockspec
status: in-progress
depends: [007]
branch: task/018-teal-lifetime
pr:
commits:
review:
---

## Goal

`lifetime build FILE.tlt -o OUT.tl` turns Teal source with the extension
(`@`, the list form, `!@`, `lifetime.scope`) into plain Teal, and
`lifetime run FILE.tlt` type-checks and compiles that Teal with the `tl`
module in the current interpreter and runs it, with the runtime's
`pcall`, the exit flag and the error report of the Lua path. The
transpiler core and the command are shared with the Lua path: the
lexer, the parser and the emitter take a *dialect*, and the Teal dialect
lives in one module, `lifetime.teal`, installed with the declaration
file `lifetime/init.d.tl` by a second rockspec, `teal-lifetime`, which
depends on `lua-lifetime` for the runtime and on `tl`. Source files are
`.tlt`; the conformance suite gains `examples/teal/*.tlt`.

## Spec

- `docs/01-overview.md`, "Rocks": "`teal-lifetime`, later, from the same
  repository: a second rockspec that depends on `lua-lifetime` for the
  runtime and on `tl`, with a Teal front end and Teal output; the
  transpiler core and the CLI are shared, and its lexer reads `!@` before
  Teal's postfix `!`".
- `docs/05-decisions.md`, "`!@` survives Teal's macro operator": "One
  lexer rule therefore separates the two: `!` immediately followed by `@`
  is `!@`; any other `!` is Teal's. That rule is the contract with
  `teal-lifetime`, whose lexer reads `!@` before Teal's `!`."
- `docs/02-semantics.md`, "Hooks: the `!@` operator": "`!@` is one token:
  `!` immediately followed by `@`. A lone `!` is a syntax error, and `a !=
  b` reads `unexpected symbol near '!' (use '~=' for inequality)`."
- `docs/04-transpiler.md`, "Pipeline": "The emitter keeps every statement
  on its source line, so that positions in error messages and tracebacks
  name the `.lt` file and its line"; "A plain Lua chunk with no extension
  syntax transpiles to itself modulo whitespace".
- `docs/04-transpiler.md`, "Grammar", "What `@` expands to", "Blocks:
  prologue and epilogue on every exit path", "The generated chunk header":
  the Teal output has the same shape, typed; the table of "What `@`
  expands to" holds row for row.
- `docs/04-transpiler.md`, "The command": `build`, `run`, the
  `FILE:LINE: <message>` shape of a syntax error, the uncaught-error
  report, the exit flag.
- `docs/02-semantics.md`, "The `lifetime` table": the names the
  declaration file types; "`__destroy` and reasons", rule 5: the four
  reasons, the `Reason` enum of the declaration file.
- `docs/05-decisions.md`, "The source file extension is `.lt`": the
  reasoning that gives Teal source `.tlt`.
- `CLAUDE.md`, rule 5 and "Technical decisions": code that does not use
  the extension pays nothing, which here means that the Lua path does
  not pay for the dialect hooks; no dependencies in the core (the `tl`
  module is required by `lifetime.teal` only, and only by `run`).

## Acceptance criteria

- `lexer.tokenize(source, chunkname, deferred, "teal")` reads Teal's
  operators `//`, `<<`, `>>`, `&`, `|` and `~`, the `?` of optional
  arguments, and still reads `!@` as one token and reports `!=` with the
  pointer to `~=`; a lone `!` is a symbol the Teal parser takes as Teal's
  macro call (05, "`!@` survives Teal's macro operator").
- `parser.parse(tokens, chunkname, dialect)` with the Teal dialect
  accepts the grammar of Teal 0.24 (`tl`'s `docs/grammar.md`): type
  annotations on locals, globals, parameters, varargs, returns and table
  fields; `<const>`, `<total>` and `<close>` attributes; `local`/`global`
  `record`, `interface`, `enum`, `type` and `macroexp` declarations with
  their bodies (`is`, `where`, `userdata`, `metamethod`, nested types);
  `global` declarations and functions; type arguments on functions; the
  operators `as`, `is`, `//`, `&`, `|`, `~`, `<<`, `>>` with Teal's
  precedences; and Teal's macro call `name!(…)`, `name!"s"`, `name!{…}`
  (the development branch). Without a dialect the parser is unchanged:
  the same AST for every Lua 5.1 chunk, token for token.
- Types, attributes and type declarations are kept as the tokens they
  were and written back on their lines; a Teal chunk with no extension
  syntax transpiles to itself modulo whitespace and comments (04,
  "Pipeline").
- The emitted Teal has the shape of 04, typed: the header binds the
  runtime and the functions used; `e @ a` is `__lt_attach(e, false, a)`,
  whose declared type `attach<T>(obj: T, pin: boolean, ...: any): T`
  keeps the type of `e`; `f !@ a` is `__lt_hook(f, name, a)`; a block
  that anchors to `lifetime.scope` gets `__lt_enter` and `__lt_exit`
  with the same positions; a `return` that passes a call's values through
  an epilogue packs them with two typed locals and casts the unpacked
  values to the enclosing function's declared return types, so that the
  output type-checks (04, "Blocks"); a `return` ending in `e as (T1, …,
  Tn)` returns n values through n locals.
- `lifetime/init.d.tl` declares the `lifetime` table of 02, "The
  `lifetime` table", plus `attach`, `hook`, `enter`, `exit` and
  `set_exiting`, the opaque records `Lifetime`, `Hook`, `Token` and
  `Scope`, and the enum `Reason` with the four reasons of 02,
  "`__destroy` and reasons", rule 5; `tl` finds it next to the runtime
  from a checkout and from the installed layout (`?/init.lua` →
  `lifetime/init.d.tl`).
- `lifetime build FILE.tlt -o OUT` writes the Teal; `-o OUT.lua`
  compiles it with `tl` first; `lifetime run FILE.tlt [ARGS]` compiles
  with `tl` (target 5.1) and runs with the runtime's `pcall`, the chunk
  name `FILE.tlt`, `arg`, the exit flag and the uncaught-error report of
  04, "The command"; a Teal type error is reported as `FILE:LINE:COL:
  <message>` (one line per error, `tl`'s own shape) with exit status 1,
  after a syntax error of the extension would have been reported in the
  shape of 04. A missing `lifetime.teal` or a missing `tl` is reported
  as `lifetime: <what is missing>` with exit status 1.
- `teal-lifetime-dev-1.rockspec` depends on `lua-lifetime` and `tl` and
  installs `lifetime.teal` and `lifetime/init.d.tl`; `luarocks make` of
  it (where luarocks runs) and the layout it installs are checked as
  task 007 checked the first rockspec.
- The conformance runner runs every `examples/teal/NAME.tlt` against
  `NAME.tlt.expected` under every interpreter on which `require("tl")`
  works, under the chunk name `examples/teal/NAME.tlt`, with the
  `!error:` contract of `examples/README.md`; with `tl` on no
  interpreter the Teal examples are skipped with a note, not failed.
- `make test` green under both interpreters with and without `tl`;
  `make lint` clean.

## Test cases

1. `examples/teal/connection.tlt`: `connection.lt` with records, typed
   locals and a typed `serve(sock: Socket)`; expected output the same
   lines: `serving`, `closing connection`, `socket closed`, `freeing
   buffer of 1024 bytes` twice.
2. `examples/teal/exit_paths.tlt`: every `return` shape through two
   epilogues in a function declared `: any, any, any` (the packed
   return's cast) and a `break` from a nested block; the same output as
   `exit_paths.lt` without its `goto` part: `destroy b (anchor)`, `destroy
   a (anchor)` after each `return …` line, then `returned N values:` with
   trailing `nil`s kept.
3. `examples/teal/uncaught_error.tlt`: the `.expected` ends with `!error:
   examples/teal/uncaught_error.tlt:N: request 2 failed`, N the line of
   the `error(...)` in the `.tlt`: the Teal output keeps every statement
   on its line and `tl` keeps them too.
4. `examples/teal/generics.tlt`: a generic `function pool<T>(make:
   function(): T): T` whose body anchors to `lifetime.scope`, an enum,
   `as` and `is` on a union, a record with `where`, and a hook typed
   `function(reason: lifetime.Reason)`: the Teal-only grammar through
   the pipeline, with the destruction order printed.
5. `tests/test-teal.lua`: the Teal tokens; a chunk with every Teal form
   parses, round-trips through `emit` to an equal AST and, with no
   extension syntax, to itself modulo whitespace; the exact output of a
   small `.tlt` (header, `__lt_attach`, `__lt_enter`/`__lt_exit`, the
   packed return with its cast); `tl` reports no error on that output
   and on `lifetime/init.d.tl` (when `tl` is installed); `cli.build` on
   every `.lt` example gives the same output with the dialect argument
   absent and `"lua"`; the command's `build` and `run` on a `.tlt`, a
   type error's report and exit status, and the message for a missing
   `tl`.
6. The sentence most likely to be misread: "its lexer reads `!@` before
   Teal's postfix `!`". `f !@ a` is the hook; `m!(a) !@ s` is Teal's
   macro call hooked to the scope; `m!@` is not a macro call named `m`
   followed by `@` but `m` hooked to whatever follows. A case in
   `tests/test-teal.lua` pins all three.

## Performance

Hot path: the transpiler on a Teal file, measured by `build/teal-5000`
in `bench/bench-build.lua` (`cli.build` on a generated 5 000-line Teal
file that uses types and the extension on most lines, against
`loadstring` of the same program as plain Lua). What stays free: the Lua
path. The dialect is a nil upvalue in the parser and the emitter, tested
at the points where Teal syntax can start and nowhere in the per-token
loops; `build/plain.lt`, `build/generated-5000`, `build/lifetime-largest`,
`parse/*` and `build/extension-5000` must not move against `master`
beyond the threshold of `bench/README.md`. The runtime is not touched.
Generated Teal costs what the generated Lua costs: the same calls, the
same locals; `tl`'s compat preamble for `table.unpack` is one line.

## Out of scope

- A `package.loaders` entry for `.lt` or `.tlt` modules at run time (a
  program requires transpiled modules, as today); `lifetime run` installs
  `tl.loader()` so that plain `.tl` modules load as under `tl run`.
- Teal's macro declarations (`local macro name!(…)` with backtick quotes
  and `$` splices, development branch only): the macro *call* is read,
  the declaration is not.
- `--#pragma` lines: comments are not kept by the emitter, so a pragma is
  dropped; a program sets them in `tlconfig.lua` or on the `tl` command.
- Editor support (`editor/luals`) and the VS Code launcher for `.tlt`.
- Type-checking the runtime's own code with `tl`; `init.d.tl` is a
  declaration, not a translation.
- Any change to the generated Lua of the `.lt` path, or to the runtime.

## Spec issues found

1. **`any` in Teal and the packed `return`.** Nothing in `docs/` could
   say it, since it is Teal's rule: `any` is assignable to no declared
   type, a type variable is not inferred from `{any}`, and a function
   with no return annotation infers no returns from an `any...` return.
   So the Lua shape of 04, "Blocks" (`__lt_pack`/`__lt_unpack`) cannot
   type-check as it is. Implemented: typed helpers in the header and a
   cast of the unpacked values to the function's declared return types;
   no cast when the function declares none or ends them with `...`, and
   `tl` then reports the `any...` as it reports `return select(…)` in
   plain Teal. Recorded in 04, "The Teal front end", and 05, "The Teal
   front end is a dialect of the shared transpiler". The Lua path's shape
   is unchanged.
2. **`lifetime.format` of a dead token.** 02, "The `lifetime` table",
   says `format` renders "a token or a hook" and that "a dead anchor in a
   snapshot renders as `dead <name>`", and "Tokens" says the tombstone's
   message uses the same text as `tostring`. `lifetime.format(tok)` on a
   token that has died raises `attempt to index a dead table (token pool,
   died at …)` while `tostring(tok)` gives `dead token pool`. Not this
   task's (the runtime is out of scope); `examples/teal/generics.tlt`
   uses `tostring`. Whether `format` should render a dead object like
   `tostring` does is for the human.
3. **Teal's `where` clause and macroexp bodies are expressions**, so the
   grammar of 04 lets them contain `@`; the emitter expands it there like
   anywhere else and `tl` judges the result. Nothing in `docs/` forbids
   it; nothing recommends it.

## Review log
