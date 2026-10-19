# The transpiler

Lua 5.1 source with the additions of [02-semantics.md](02-semantics.md)
goes in; plain Lua 5.1 that runs on Lua 5.1 and LuaJIT comes out. The
design follows decisions 5, 6, 10 and 11 of
`xd/docs/10-lua-lifetime-decisions.md`. Tasks 005 to 007 implement it.

## Pipeline

```
source (.lt)  →  lexer  →  parser (AST)  →  emit  →  Lua 5.1 source
```

- `lifetime/lexer.lua`: Lua 5.1 tokens plus `@` and `!@`, LuaJIT's `::`,
  and LuaJIT's lexical extensions ([05-decisions.md](05-decisions.md),
  "The lexer accepts LuaJIT's lexical extensions").
- `lifetime/parser.lua`: a recursive-descent parser for the grammar
  below, producing a plain table AST that records the line of every node
  and, on nodes that own tokens, the lines of those tokens (`lines`), so
  that the emitter can put every token back on its source line.
- `lifetime/emit.lua`: code generation from the AST.
- `lifetime/cli.lua`: the pipeline as one function, `build(source,
  chunkname [, lang])`, and the command (`lifetime build FILE -o OUT`, `lifetime run
  FILE [ARGS]`).
- `lifetime/teal.lua`: the Teal dialect of the three stages and the
  bridge to the `tl` compiler ("The Teal front end" below; the
  `teal-lifetime` rock of [01-overview.md](01-overview.md), "Rocks").

The emitter keeps every statement on its source line, so that positions
in error messages and tracebacks name the `.lt` file and its line; where
generated code needs extra lines it is written on the same line, separated
by `;`. A plain Lua chunk with no extension syntax transpiles to itself
modulo whitespace (task 001, the pass-through).

## Grammar

Lua 5.1 (`lparser.c`, the manual's §8) plus:

```ebnf
exp        ::= … | exp anchorop
stat       ::= … | prefixexp anchorop { anchorop }
             | functiondef '!@' anchor { anchorop }
anchorop   ::= '@' anchor | '!@' anchor
anchor     ::= scopeanchor | prefixexp | '(' anchorlist ')'
anchorlist ::= anchoritem { ',' anchoritem }
anchoritem ::= scopeanchor | exp
scopeanchor ::= 'lifetime' '.' 'scope'
```

- `@` has the lowest precedence of any operator and is postfix. A
  statement chains `@` and `!@` exactly as an expression does, left to
  right: `f !@ a @ b` as a statement creates the hook on `a` and moves it
  to `b` ([05-decisions.md](05-decisions.md), "A statement chains `@`
  and `!@` like an expression").
- `!@` has the precedence and the right operand of `@`. The lexer
  produces `!@` as one token when `!` is immediately followed by `@`; a
  lone `!` is a syntax error, and `!=` is reported as `unexpected symbol
  near '!' (use '~=' for inequality)`.
- A statement may start with `function (`, an anonymous function, which
  must then be followed by `!@`; `function name` keeps its Lua meaning.
- `scopeanchor` is the two Names `lifetime` and `scope` joined by `.`,
  with nothing after them that would continue a `prefixexp` (no `.x`, `[`,
  `(`, `:`, string argument or `{` table argument). The parser tries it before `prefixexp`
  where `anchor` and `anchoritem` name it and matches by spelling, whatever
  `lifetime` names at that point; anywhere else `lifetime.scope` is an
  ordinary `prefixexp` and `lifetime.scope.x` or `lifetime.scope()` are
  ordinary expressions. `@()` is a syntax error. Lists do not nest.
  A one-element parenthesised item followed by a suffix (`x @
  (lifetime.scope).f`, `x @ (t).owner`) is Lua's parenthesised
  `prefixexp`, not a list, so the inner `lifetime.scope` is the ordinary
  marker.
- Reserved words: none added. `defer`, `token`, `scope` and `caller` are
  ordinary names ([05-decisions.md](05-decisions.md), "The scope anchor is
  spelled `lifetime.scope`").
- LuaJIT's `stat ::= 'goto' Name | '::' Name '::'` is accepted in the
  input; as in LuaJIT, `goto` starts a statement only when a Name follows
  it, and is an ordinary name everywhere else
  ([05-decisions.md](05-decisions.md), "The lexer accepts LuaJIT's
  lexical extensions").

## The generated chunk header

Every output chunk that uses the extension begins with one line that
binds the runtime, and the runtime functions the chunk calls, to locals:

```lua
local lifetime = require("lifetime"); local __lt_attach = lifetime.attach
```

so that `lifetime.*` in the source (`lifetime.destroy(x)`,
`lifetime.discard(x)`, `lifetime.of`, …) resolves without installing
globals, and generated code reaches the runtime through locals (upvalues
in nested functions), never through a global and a field lookup. The
header names only what the chunk uses; a chunk that uses no extension
syntax and does not name `lifetime` gets no header and is its input
unchanged. There are no builtins: `destroy` and `discard` are ordinary
names, and a program that defines its own is not shadowed
([05-decisions.md](05-decisions.md), "`destroy` and `discard` are spelled
`lifetime.destroy` and `lifetime.discard`"). `destroyerror` is not bound:
the runtime reads it raw from `_G` (02, "Errors in destructors"). A
source file that shadows `lifetime` gets what it wrote. An assignment to
the global `lifetime` in a transpiled chunk assigns the header's local (an
assignment target counts as naming it); a program that wants the global
sets `_G.lifetime`.

## What `@` expands to

| Source | Generated |
| --- | --- |
| `e @ a` | `__lt_attach(e, a)` |
| `e @ (a, b)` | `__lt_attach(e, a, b)` |
| `e @ lifetime.scope` | `__lt_attach(e, <scope local>)` |
| `e @ lifetime.pin(a, b)` | `__lt_attach(e, (lifetime.pin(a, b)))` (the value carries no term) |
| `x @ a` as a statement | the same call as a statement |
| `f !@ a` | `__lt_hook(f, a)` |
| `f !@ lifetime.scope` | `__lt_hook(f, <scope local>)` |
| `f !@ (a, b)` | `__lt_hook(f, a, b)` |
| `local h = f !@ a`, `h = f !@ a`, `t.h = f !@ a` | `… = __lt_named_hook("h", f, a)`: the name of the binding target ([02-semantics.md](02-semantics.md), "Named hooks") |

`attach` returns its first argument, so the expression form keeps its
value. A call or `...` as the last item of a list is parenthesised in the
generated call, so an anchor item is always one value (02, "Acquiring a
lifetime", step 2). `lifetime.token("t")` is an ordinary call and is emitted as
written; `lifetime.token("t") @ a` is the `@` row. `__lt_hook` and
`__lt_named_hook` are bound in the header the same way when the chunk
uses them. The implicit `reachable` term is the runtime's business
(`lifetime.attach` adds it unless every anchor is a pinned value), not the
emitter's. The calls are the library form's ([02-semantics.md](02-semantics.md),
"The library form"): a program that is not transpiled writes
`lifetime.attach(e, a)`, `lifetime.hook(f, a)` and
`lifetime.named_hook("h", f, a)` itself, and `lifetime.block` in place
of the block prologue and epilogue below (task 021).

## Blocks: prologue and epilogue on every exit path

A block **needs a scope record** if it contains, directly (not in a nested
function), `lifetime.scope` as an anchor (after `@` or `!@`, alone or in a list). Only such
blocks get code; every
other block is emitted verbatim. For a block that needs one:

```lua
do local __s1 = lifetime.enter("<chunk>:<line of end>")
  …
lifetime.exit(__s1, "<chunk>:<line>") end
```

The position passed to `enter` is that of the block's `end`, which the
runtime reports for an object the error path unwinds; the position passed
to `exit` is that of the exit that runs it. Both are constant
`"chunk:line"` strings the emitter writes, since the runtime may not read
`debug.*` on a per-block path and cannot learn the chunk name otherwise;
the runtime stores and renders them as given. For a block closed by `elseif`, `else` or `until` the position is that
token's; for the main chunk it is the line of `<eof>`.

- **Fall-through**: the epilogue at the end of the block.
- **`return explist`** inside the block (at any nesting below it that is
  not a nested function): the values are evaluated first, then every
  epilogue from the innermost block up to the function body runs, then the
  values are returned. Trailing `nil`s survive by packing with
  `select("#", …)` and unpacking with `unpack(t, 1, n)`. A `return f(x)`
  that was a tail call is no longer one when an epilogue is needed; this
  is the cost of a destructor at block exit and is accepted.
- **`break`**: the epilogues of the blocks between the `break` and the
  loop body it leaves, innermost first, then the `break`.
- **`goto` (LuaJIT)**: the epilogues of the blocks the jump leaves,
  innermost first. A `goto` to a label at the end of a block (the `continue` idiom) runs
  that block's epilogue before the jump, with the position of the block's
  `end`, as fall-through would. A `goto` into a block that needs a record is a compile
  error ("jumps into the scope of a lifetime").
- **A loop body** is a block: the record is created and destroyed once per
  iteration.
- **A function body** is a block; its epilogue runs on fall-through and on
  every `return`.

## The error path: unwinding at the raise point

Scope destructors must run when an error unwinds through the block
(decision 10, "Every exit path"). The transpiler emits nothing for it:
the runtime keeps a stack of the active scope records per coroutine, and
its replacements for `pcall`, `xpcall`, `coroutine.resume` and
`coroutine.wrap` unwind, innermost first, every record pushed since the
call began, at the raise point: `pcall` and `xpcall` from a message
handler, while the frames that raised are still on the stack; `resume`
and the `wrap` function in the resumer's context, while the dead
coroutine still holds its frames; all before they return `false` or
re-raise ([03-runtime.md](03-runtime.md), "The scope stack and the
error path"; [05-decisions.md](05-decisions.md), "Scopes unwind at the
raise point"). What this buys the generated code:

- A block body stays a block body: no closure, no rewrite of `return` and
  `break`, no forwarding of `...`. A loop whose body owns something is
  still one trace for LuaJIT.
- A block that anchors to `lifetime.scope` may yield on plain Lua 5.1.
- A `return f(x)` inside such a block is still not a tail call, because
  the epilogue runs after `f(x)`; that is the only cost that remains.
- Message handlers of an enclosing `xpcall` run at the raise point, before
  any epilogue, as they would in Lua; the runtime's unwinding follows at
  the same point, so a dependent is reachable until its destructor runs.
- The main chunk is a block like any other. `lifetime run` calls it
  through the runtime's `pcall`, so an uncaught error still unwinds the
  main scope before the error is reported ("The command"); an embedding
  host that loads the chunk itself gets the same by calling it through
  `pcall` after requiring `lifetime`.

## Functions

A function body is a block and gets code only under the block rule above:
a record and an epilogue on fall-through and before every `return`, when
and only when the body anchors to `lifetime.scope`. A function that does
not is emitted verbatim, and a call costs what it costs in Lua.
There is no per-function prologue: the anchor for the caller's block that
would have needed one is not part of the language
([05-decisions.md](05-decisions.md), "`caller` is removed").

## The command

- `lifetime build FILE -o OUT`: transpile `FILE` to `OUT`; `-o -` writes
  to standard output. Exit status 1 and a message on standard error for a
  syntax error, in the shape `FILE:LINE: <message>`.
- `lifetime run FILE [ARGS]`: transpile and run in the current
  interpreter. The runtime is loaded first, so the chunk and every
  module it requires run with the runtime's `pcall`, `xpcall`,
  `coroutine.resume` and `coroutine.wrap` in place and pay their cost
  (03, "Performance") even in a chunk that uses no extension syntax; a
  program that wants no runtime runs its generated file under the
  interpreter directly. It transpiles and runs in the current
  interpreter with the chunk name `FILE`, `arg` set as the standalone
  interpreter sets it, and the exit flag of 03, "Program end", set after
  the chunk returns. An uncaught error is reported as `lifetime: <message>`
  with a traceback on standard error and exit status 1, as the standalone
  interpreter reports it.
- `bin/lifetime` is the installed script; the rockspec installs it.

## The Teal front end

*Task 018; [01-overview.md](01-overview.md), "Rocks"; [05-decisions.md](05-decisions.md),
"`!@` survives Teal's macro operator", "The Teal source extension is
`.tlt`", "The Teal front end is a dialect of the shared transpiler".*

The same pipeline, with Teal in and Teal out:

```
source (.tlt)  →  lexer  →  parser (AST)  →  emit  →  Teal source  →  tl  →  Lua 5.1
```

A `.tlt` file is Teal ([tl](https://github.com/teal-language/tl) 0.24's
grammar, `docs/grammar.md` there, plus the macro call `m!(…)` of its
development branch) with the additions of this document. `lifetime build
FILE.tlt -o OUT.tl` writes the Teal the stages produce; `lifetime run
FILE.tlt` compiles that Teal with the `tl` module, in the current
interpreter, and runs the Lua as it runs a `.lt` file. The three stages
take a **dialect**, the object `lifetime/teal.lua` exports: the lexer
reads Teal's `//`, `<<` and `>>`; the parser calls the dialect's hooks
where Teal syntax can start; the emitter writes what the hooks kept.
Without a dialect the stages are those of the sections above, and a
`.lt` file pays nothing for the Teal grammar (the hooks are a nil upvalue
tested at those points, never in a per-token loop; `build/teal-5000`
against `build/extension-5000` in `bench/bench-build.lua` is the
measure).

- **`!@` before `!`.** The lexer reads `!@` as one token wherever `!` is
  immediately followed by `@`; any other `!` is Teal's macro call,
  `prefixexp '!' args`, read like a call. `m!(a) !@ s` hooks the macro
  call's value to the scope; `m!@ s` hooks `m` to `s`. `!=` keeps its
  error. This is the contract of [05-decisions.md](05-decisions.md),
  "`!@` survives Teal's macro operator".
- **Types pass through.** A type (after a local's or global's names, a
  parameter, a vararg, a function's `)`, a table field's name, `as`, `is`),
  an attribute (`<const>`, `<total>`, `<close>`), type arguments
  (`function f<T>(…)`) and a whole type declaration (`local`/`global`
  `record`, `interface`, `enum`, `type`, `macroexp`, with `is`, `where`,
  `userdata`, `metamethod` and nested types) are kept as the tokens they
  were, with their lines, and written back unchanged; the transpiler
  never interprets a type, `tl` does. The expressions inside a type
  declaration (a `where` clause, a macroexp's `return`) are parsed and
  may use the extension. `global` declarations and `global function` are
  statements of their own. Teal's `as` binds above every operator and
  `is` at the level of the comparisons, `//`, `&`, `|`, `~`, `<<` and
  `>>` with Teal's precedences; `global`, `record`, `enum`, `interface`,
  `type`, `macroexp`, `as`, `is`, `where`, `userdata` and `metamethod` are
  contextual, ordinary names where Teal reads them so (`local type = 1`,
  `global = 2`).
- **The same shape, typed.** The table of "What `@` expands to" holds row
  for row, and so does "Blocks": `e @ a` is `__lt_attach(e, a)`,
  whose declaration `attach<T>(obj: T, pin: boolean, ...: any): T` keeps
  the type of `e`, so `local conn: Conn = Conn.open(s) @ lifetime.scope`
  type-checks; `f !@ a` is `__lt_hook(f, a)` (`__lt_named_hook("h", f, a)` bound to a name); a block that anchors
  to `lifetime.scope` gets `__lt_enter` and `__lt_exit` with the same
  positions; the header binds the same locals. Two rows differ because
  `any` is assignable to no declared type in Teal and a type variable is
  not inferred from `{any}`:
  - the header's packing helpers are typed, `local __lt_unpack:
    function({any}, integer, integer): any... = table.unpack` and a
    `__lt_pack(...: any): {any}, integer` that returns the table and the
    count;
  - a `return` that passes a call's or `...`'s values through an epilogue
    reads `local __r, __n = __lt_pack(…); <epilogues> return
    __lt_unpack(__r, 1, __n) as (T1, …, Tn)`, the cast being the
    enclosing function's declared return types. A function that declares
    none, or ends them with `...` (which no cast can spell), gets no
    cast, and `tl` reports the `any...` as it does for any such return;
    the program declares or casts by hand. A `return` whose last value
    is a tuple cast, `e as (T1, …, Tn)`, is n values through n locals
    and is not packed.
- **The declaration file.** `lifetime/init.d.tl` declares the `lifetime`
  table of [02-semantics.md](02-semantics.md), "The `lifetime` table",
  with `attach`, `hook`, `enter`, `exit` and `set_exiting`, the opaque
  records `Lifetime`, `Hook`, `Token` and `Scope`, and the enum `Reason`
  (`"anchor"`, `"destroy"`, `"unreachable"`, `"exit"`). `tl` finds it
  next to the runtime through the `?/init.lua` entry of the path
  (`lifetime/init.d.tl`), from a checkout and from the installed layout.
  A destructor is written on the metatable, which `metatable<T>` does not
  know as a field: `{__index = R, __destroy = function(self: R, reason:
  lifetime.Reason) … end} as metatable<R>`.
- **The command.** `lifetime build FILE.tlt -o OUT` writes the Teal; with
  an OUT ending in `.lua` it compiles the Teal with `tl` first. `lifetime
  run FILE.tlt [ARGS]` compiles with `tl` (target 5.1, every statement
  kept on its line, so positions name the `.tlt` file) and runs as "The
  command" says, installing `tl.loader()` so that the program can require
  plain `.tl` modules. A syntax error of the extension is reported as
  above, `FILE:LINE: <message>`; a Teal error as `tl` reports it,
  `FILE:LINE:COL: <message>`, one line per error (each behind
  `lifetime: ` under `run`), exit status 1. The line is the `.tlt` file's;
  the column is the generated Teal's, which differs from the source's on
  the lines the emitter rewrote (line 1, which carries the header, and
  every line with `@`, `!@` or a packed `return`). A `.tlt` file without
  the `teal-lifetime` rock installed, or `run` without the `tl` module,
  is reported as `lifetime: <what is missing>`.
- **Not kept.** Comments, so a `--#pragma` line is dropped (set pragmas
  in `tlconfig.lua` or on the `tl` command); and Teal's macro
  *declarations* (`local macro name!(…)` with backtick quotes and `$`
  splices, development branch only): the call is read, the declaration
  is not.
