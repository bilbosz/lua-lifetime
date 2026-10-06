# Examples

Each `NAME.lt` is a program in Lua with lifetime syntax
(`docs/02-semantics.md`). Each `NAME.lt.expected` holds the exact standard
output that program must produce; the expected file carries the full name
of the program it belongs to. The conformance runner
(`tests/conformance.lua`) compares them byte for byte, under every
interpreter it finds on `PATH` among `lua5.1` and `luajit`; at least one
must be present or the run fails.

The `-->` comments inside the `.lt` files are documentation of the same
output for human readers and may carry explanatory text after two or more
spaces. The `.lt.expected` file is the authority.

A program expected to end with an uncaught error ends its `.lt.expected`
with a final line `!error: <message prefix>`.

Precisely, the runner reads `NAME.lt.expected` as bytes and:

- if its last line (ignoring one final `\n`) starts with `!error: `, the
  program must end with an uncaught error whose message starts with the rest
  of that line, and everything before that line is the expected standard
  output;
- otherwise the whole file is the expected standard output, and the program
  must finish without an uncaught error.

Standard output is compared byte for byte, including the final newline that
`print` writes, and must be the same under every interpreter, so a program
never prints a table address or a float whose rendering could differ. Every
`NAME.lt` must have a `NAME.lt.expected` and vice versa; a missing partner
is a collection error that names the missing file.

Each program is transpiled to `build/examples/NAME.lua` and runs under the
chunk name `examples/NAME.lt`, so a position in an error message reads
`examples/NAME.lt:LINE:` in both the expected output and an `!error:` line;
the emitter keeps every statement on its source line to make that true. A
program without an `!error:` line must exit with status 0; one with it must
exit with status 1 after the interpreter reports `<interpreter>: <message>`
on standard error (task 007 switches the runner to `lifetime run`, which
reports `lifetime: <message>`).

Every example must pass; there is no expected-failure marker. The examples
ported from `xd/examples/` and how each relates to its original are
recorded in `docs/07-conformance.md`.
