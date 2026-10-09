# The transpiler

Lua 5.1 source with the additions of [02-semantics.md](02-semantics.md)
goes in; plain Lua 5.1 that runs on Lua 5.1 and LuaJIT comes out. The
design follows decisions 5, 6, 10 and 11 of
`xd/docs/10-lua-lifetime-decisions.md`. Tasks 005 to 007 implement it.

## Pipeline

```
source (.lt)  →  lexer  →  parser (AST)  →  emit  →  Lua 5.1 source
```

- `lifetime/lexer.lua`: Lua 5.1 tokens plus `@` and `!@`.
- `lifetime/parser.lua`: a recursive-descent parser for the grammar
  below, producing a plain table AST that records the line of every node.
- `lifetime/emit.lua`: code generation from the AST.
- `lifetime/cli.lua`: the pipeline as one function, `build(source,
  chunkname)`, and the command (`lifetime build FILE -o OUT`, `lifetime run
  FILE [ARGS]`).

The emitter keeps every statement on its source line, so that positions
in error messages and tracebacks name the `.lt` file and its line; where
generated code needs extra lines it is written on the same line, separated
by `;`. A plain Lua chunk with no extension syntax transpiles to itself
modulo whitespace (task 001, the pass-through).

## Grammar

Lua 5.1 (`lparser.c`, the manual's §8) plus:

```ebnf
exp        ::= … | exp '@' anchor | exp '!@' anchor
stat       ::= … | prefixexp '@' anchor
             | prefixexp '!@' anchor | functiondef '!@' anchor
anchor     ::= scopeanchor | prefixexp | '(' anchorlist ')'
anchorlist ::= anchoritem { ',' anchoritem }
anchoritem ::= scopeanchor | exp
scopeanchor ::= 'lifetime' '.' 'scope'
```

- `@` has the lowest precedence of any operator and is postfix.
- `!@` has the precedence and the right operand of `@`. The lexer
  produces `!@` as one token when `!` is immediately followed by `@`; a
  lone `!` is a syntax error, and `!=` is reported as `unexpected symbol
  near '!' (use '~=' for inequality)`.
- A statement may start with `function (`, an anonymous function, which
  must then be followed by `!@`; `function name` keeps its Lua meaning.
- `scopeanchor` is the two Names `lifetime` and `scope` joined by `.`,
  with nothing after them that would continue a `prefixexp` (no `.x`, `[`,
  `(`, `:` or string argument). The parser tries it before `prefixexp`
  where `anchor` and `anchoritem` name it and matches by spelling, whatever
  `lifetime` names at that point; anywhere else `lifetime.scope` is an
  ordinary `prefixexp` and `lifetime.scope.x` or `lifetime.scope()` are
  ordinary expressions. `@()` is a syntax error. Lists do not nest.
- Reserved words: none added. `defer`, `token`, `scope` and `caller` are
  ordinary names ([05-decisions.md](05-decisions.md), "The scope anchor is
  spelled `lifetime.scope`").

## The generated chunk header

Every output chunk that uses the extension begins with one line that
binds the runtime, and the runtime functions the chunk calls, to locals:

```lua
local lifetime = require("lifetime"); local destroy, discard = lifetime.destroy, lifetime.discard; local __lt_attach = lifetime.attach
```

so that `destroy(x)`, `discard(x)` and `lifetime.*` in the source resolve
without installing globals, and generated code reaches the runtime
through locals (upvalues in nested functions), never through a global and
a field lookup. The header names only what the chunk uses; a chunk that
uses no extension syntax and names no lifetime builtin gets no header
and is its input unchanged. `destroyerror` is not bound: the runtime reads
it raw from `_G` (02, "Errors in destructors"). A source file that shadows
these names gets what it wrote.

## What `@` expands to

| Source | Generated |
| --- | --- |
| `e @ a` | `__lt_attach(e, false, a)` |
| `e @ (a, b)` | `__lt_attach(e, false, a, b)` |
| `e @ lifetime.scope` | `__lt_attach(e, false, <scope local>)` |
| `e @ lifetime.pin(a, b)` | `__lt_attach(e, false, lifetime.pin(a, b))` (the value carries no term) |
| `x @ a` as a statement | the same call as a statement |
| `f !@ a` | `lifetime.hook(f, nil, a)` |
| `f !@ lifetime.scope` | `lifetime.hook(f, nil, <scope local>)` |
| `f !@ (a, b)` | `lifetime.hook(f, nil, a, b)` |
| `local h = f !@ a`, `h = f !@ a`, `t.h = f !@ a` | `… = lifetime.hook(f, "h", a)`: the name of the binding target ([02-semantics.md](02-semantics.md), "Named hooks") |

`attach` returns its first argument, so the expression form keeps its
value. `lifetime.token("t")` is an ordinary call and is emitted as
written; `lifetime.token("t") @ a` is the `@` row. The rows below that still read `lifetime.x` are bound to a local in
the header the same way when the chunk uses them; the table shows the
runtime entry point, not the spelling. The implicit `reachable` term is the runtime's business
(`lifetime.attach` adds it unless every anchor is a pinned value), not the
emitter's. The exact names are the emitter task's to fix with the runtime
tasks; this table fixes the shape.

## Blocks: prologue and epilogue on every exit path

A block **needs a scope record** if it contains, directly (not in a nested
function), `lifetime.scope` as an anchor (after `@` or `!@`, alone or in a list). Only such
blocks get code; every
other block is emitted verbatim. For a block that needs one:

```lua
do local __s1 = lifetime.enter(<line of end>)
  …
lifetime.exit(__s1, <line>) end
```

The line passed to `enter` is the line of the block's `end`, which the
runtime reports for an object the error path unwinds; the line passed to
`exit` is the line of the exit that runs it.

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
  innermost first. A `goto` into a block that needs a record is a compile
  error ("jumps into the scope of a lifetime").
- **A loop body** is a block: the record is created and destroyed once per
  iteration.
- **A function body** is a block; its epilogue runs on fall-through and on
  every `return`.

## The error path: unwinding at the catch site

Scope destructors must run when an error unwinds through the block
(decision 10, "Every exit path"). The transpiler emits nothing for it:
the runtime keeps a stack of the active scope records per coroutine, and
its replacements for `pcall`, `xpcall`, `coroutine.resume` and
`coroutine.wrap` unwind, innermost first, every record pushed since the
call began before they return `false` or re-raise
([03-runtime.md](03-runtime.md), "The scope stack and the error path";
[05-decisions.md](05-decisions.md), "Scopes unwind at the catch site").
What this buys the generated code:

- A block body stays a block body: no closure, no rewrite of `return` and
  `break`, no forwarding of `...`. A loop whose body owns something is
  still one trace for LuaJIT.
- A block that anchors to `lifetime.scope` may yield on plain Lua 5.1.
- A `return f(x)` inside such a block is still not a tail call, because
  the epilogue runs after `f(x)`; that is the only cost that remains.
- Message handlers of an enclosing `xpcall` run at the raise point, before
  any epilogue, as they would in Lua.
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
  interpreter with the chunk name `FILE`, `arg` set as the standalone
  interpreter sets it, and the exit flag of 03, "Program end", set after
  the chunk returns. An uncaught error is reported as `lifetime: <message>`
  with a traceback on standard error and exit status 1, as the standalone
  interpreter reports it.
- `bin/lifetime` is the installed script; the rockspec installs it.
