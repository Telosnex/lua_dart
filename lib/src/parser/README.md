# Lua parser (Dart)

A Lua 5.4 parser to an AST, for static analysis. It never runs code; the C
runtime of this package compiles with Lua's own parser (lparser.c).

From the LuaDardo project (Apache 2.0; https://github.com/arcticfox1919/LuaDardo),
through the Telosnex fork lua_dardo_plus at 79a43e6, which added Lua 5.4
local attributes (`<const>`, `<close>`). Only the lexer, parser, AST, and two
number helpers are kept.

Changed here, as test/parser_conformance_test.dart found, to match Lua 5.4.9:
numerals follow lobject.c (hex floats without an exponent, hex integers
that wrap around, "malformed number" for a numeral that touches a letter),
`\u{...}` takes up to 2^31 - 1, `\ddd` above 255 fails, `\x` takes exactly
two hex digits, and input that ends inside an escape no longer throws a
RangeError.

test/parser_conformance_test.dart checks that this parser accepts exactly the
chunks that the C runtime compiles. A Lua bump must keep it passing.
