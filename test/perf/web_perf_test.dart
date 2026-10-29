// The benchmarks of this directory in a browser, where lua_dart runs as
// WebAssembly and lua_dardo_plus as JavaScript or WebAssembly:
//
//   dart test -p chrome web_perf_test.dart
//   dart test -p chrome -c dart2wasm web_perf_test.dart
@TestOn('browser')
@Timeout(Duration(minutes: 10))
library;

import 'package:test/test.dart';

import 'countdown_widget_perf.dart' as countdown_widget;
import 'fixed_stack_perf.dart' as fixed_stack;
import 'lexer_perf.dart' as lexer;
import 'opacity_shadow_contrast_perf.dart' as opacity_shadow_contrast;
import 'stat_parser_perf.dart' as stat_parser;
import 'string_format_perf.dart' as string_format;

void main() {
  test('fixed stack', fixed_stack.main);
  test('string format', string_format.main);
  test('countdown widget', countdown_widget.main);
  test('opacity shadow contrast', opacity_shadow_contrast.main);
  test('lexer', lexer.main);
  test('stat parser', stat_parser.main);
}
