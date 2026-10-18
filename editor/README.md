# Editor support

Support for editing lua-lifetime source in an editor. Nothing here is
part of the runtime, the transpiler or the command; the rockspec does
not install it, and `bin/lifetime` never reads it.

| Path | What |
| --- | --- |
| `luals/plugin.lua` | A plugin for the Lua language server (LuaLS, the `sumneko.lua` extension of VS Code). It rewrites a `.lt` file into plain Lua of the same shape before the server parses it, so that `.lt` files get completion, hover, go to definition and diagnostics. The rewrite is for analysis only and is never run. |
| `luals/check.lua` | Runs the rewrite over `.lt` files and checks that each result compiles. `make luals-check`, part of `make test`, runs it over every `.lt` file of the repository. |
| `luals/meta/lifetime.lua` | A `---@meta` declaration of the `lifetime` module for LuaLS: the names of `docs/02-semantics.md`, "The `lifetime` table" and "The library form", typed. For a program that requires the runtime as a library (Treflove's lua-lifetime branch points its `workspace.library` at this directory). Never run. |
| `../.vscode/launch.json`, `../.vscode/launch.lua` | Run and debug configurations for VS Code with the "Local Lua Debugger" extension (`tomblind.local-lua-debugger-vscode`), and the script they run. |

## The language server plugin

The server reads only Lua, and `@` is not a Lua token, so without help it
reports a syntax error on every anchor. `Lua.runtime.plugin` names a Lua
file whose `OnSetText(uri, text)` may return diffs that the server
applies to the text before parsing; it maps every position back through
them, so hover and diagnostics land on the source.

The plugin lexes the file with the repository's own lexer
(`lifetime/lexer.lua`), so it reads exactly the tokens the transpiler
reads and follows the grammar of `docs/04-transpiler.md` as it changes.
It then rewrites:

| Source | Rewrite | Why |
| --- | --- | --- |
| `e @ a`, `f !@ a` | `e or a`, `f or a` | `@` and `!@` are postfix, of the lowest precedence, chaining to the left; `or` is the Lua operator of that shape. |
| `e @ (a, b)` | `e or (a or b)` | The list form: its commas. |
| `x @ a` as a statement | `local _ = x or a` | An expression is not a statement. `_` is a name the server never reports as unused or redefined. The statement form is told from the expression form by walking back over the left operand and looking at the token before it. |
| the first token | `local lifetime = require("lifetime")` before it | The header the transpiler emits ("The generated chunk header"), inserted when the file uses an anchor or names `lifetime`, so that `lifetime.*` resolves to `lifetime/init.lua` and `lifetime.scope` is the marker field the runtime has. |

When the lexer stops at a malformed token, as it does while a line is
being typed, the plugin returns nothing and the server sees the raw file
until the line is complete.

The workspace settings in `.vscode/settings.json` point the server at
the plugin. The first time the extension loads a workspace plugin it
asks whether to trust it; the answer is remembered. The plugin runs
under the server's Lua 5.4; `check.lua` runs under Lua 5.1 and LuaJIT,
and under the server's own interpreter when run by hand
(`<extension>/server/bin/lua-language-server editor/luals/check.lua FILE...`).

## Running and debugging

`.vscode/launch.json` has one configuration per interpreter, "lifetime
run: current file (LuaJIT)" and "(Lua 5.1)". With a `.lt` file open,
F5 runs it as `lifetime run` does, from the repository root, under the
chunk name the conformance runner uses (`examples/NAME.lt`), so the
debug console shows the output of `NAME.lt.expected`. A breakpoint set
in the `.lt` file stops there, in a coroutine too: the emitter keeps
every statement on its source line, and `.lt` is associated with Lua,
which is what lets the editor set it. The locals shown are the generated
chunk's, so a scope record (`__s1`) appears among them. A file under
`lifetime/` takes breakpoints the same way, and a transpiled `.lua` file
runs like its source.

The configurations run `.vscode/launch.lua`, not `bin/lifetime`. The
debugger replaces `error`, `assert`, `debug.traceback` and
`coroutine.wrap` with functions that stop at every raise and raise the
value again as a string, which neither the transpiler nor the runtime
survives; the script starts the debugger, puts the host's functions
back and then runs the command. Two things follow: the debugger does
not stop on an error, caught or uncaught (an uncaught one is reported
with its traceback, as `lifetime run` reports it), and
`"breakInCoroutines"` must stay `false`.

## Not here yet

A grammar for `.lt` that highlights `@` and `!@` needs a VS Code
extension of its own.
