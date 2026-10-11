# Editor support

Support for editing lua-lifetime source in an editor. Nothing here is
part of the runtime, the transpiler or the command; the rockspec does
not install it, and `bin/lifetime` never reads it.

| Path | What |
| --- | --- |
| `luals/plugin.lua` | A plugin for the Lua language server (LuaLS, the `sumneko.lua` extension of VS Code). It rewrites a `.lt` file into plain Lua of the same shape before the server parses it, so that `.lt` files get completion, hover, go to definition and diagnostics. The rewrite is for analysis only and is never run. |
| `luals/check.lua` | Runs the rewrite over `.lt` files and checks that each result compiles. `make luals-check`, part of `make test`, runs it over every `.lt` file of the repository. |

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

## Not here yet

A grammar for `.lt` that highlights `@` and `!@`, and the debugger
configuration, need a VS Code extension of their own.
