# Lua parser (Dart)

A Lua 5.5 parser to an AST, for static analysis. It never runs code; the C
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

Lua 5.5 syntax, added here: `global` declarations (`global x`, `global *`,
`global function f`), with `global` a keyword only where it starts a
declaration (LUA_COMPAT_GLOBAL, the default of Lua 5.5.1); an attribute before
the names of `local`; and named vararg parameters (`function f(...args)`).

test/parser_conformance_test.dart checks that this parser accepts exactly the
chunks that the C runtime compiles. A Lua bump must keep it passing.
