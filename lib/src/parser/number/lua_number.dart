// From LuaDardo (Apache 2.0); see lib/src/parser/README.md.
// Rewritten to follow l_str2int and l_str2d of lobject.c (Lua 5.4) for the
// numerals the lexer reads: no spaces, no sign.

import 'dart:math' as math;

class LuaNumber {
  static final _hexInt = RegExp(r'^0[xX][0-9a-fA-F]+$');
  static final _decInt = RegExp(r'^[0-9]+$');
  static final _hexFloat = RegExp(
    r'^0[xX]([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?(?:[pP]([+-]?[0-9]+))?$',
  );
  static final _decFloat = RegExp(
    r'^(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$',
  );

  static bool isInteger(double f) {
    return f == f.toInt();
  }

  /// An integer numeral, or null. A hexadecimal one wraps around modulo
  /// 2^64; a decimal one that overflows is a float, as in Lua.
  static int? parseInteger(String str) {
    if (_hexInt.hasMatch(str)) {
      return BigInt.parse(str.substring(2), radix: 16).toSigned(64).toInt();
    }
    if (_decInt.hasMatch(str)) return int.tryParse(str);
    return null;
  }

  /// A float numeral, decimal or hexadecimal (with an optional binary
  /// exponent), or null.
  static double? parseFloat(String str) {
    if (_decFloat.hasMatch(str)) return double.parse(str);
    final hex = _hexFloat.firstMatch(str);
    if (hex == null) return null;
    final whole = hex[1]!;
    final fraction = hex[2] ?? '';
    if (whole.isEmpty && fraction.isEmpty) return null;
    final mantissa = BigInt.parse('0$whole$fraction', radix: 16).toDouble();
    final exponent = int.parse(hex[3] ?? '0') - 4 * fraction.length;
    return mantissa * math.pow(2.0, exponent);
  }
}
