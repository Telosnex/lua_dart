/// A Lua 5.4 parser to an AST, for static analysis: it never runs code.
///
/// It accepts the chunks that LuaState compiles
/// (test/parser_conformance_test.dart). From LuaDardo (Apache 2.0); see
/// lib/src/parser/README.md.
library;

export 'src/parser/ast/block.dart' show Block;
export 'src/parser/ast/exp.dart';
export 'src/parser/ast/node.dart' show Node;
export 'src/parser/ast/stat.dart';
export 'src/parser/parser/parser.dart' show Parser;
