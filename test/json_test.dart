// json.decode and json.encode give the values that a host gets with
// dart:convert and the conversion between Dart and Lua values below. The
// conversion is a copy of lua_bridge.dart of Telosnex, the first host: its
// json_decode and json_encode were jsonDecode + dartToLua and
// luaToDart + jsonEncode.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:lua_dart/lua_dart.dart';
import 'package:test/test.dart';

/// Compiled to JavaScript, Dart ints are doubles: the reference loses
/// integers beyond 2^53, gives 1.0 as an int, and prints integral doubles
/// without ".0". The parity tests then cannot run; the golden tests do.
final bool _js = identical(1, 1.0);

// ── The reference: lua_bridge.dart of Telosnex ─────────────────────────

void dartToLua(LuaState ls, Object? value) {
  if (value == null) {
    ls.pushNil();
  } else if (value is bool) {
    ls.pushBoolean(value);
  } else if (value is int) {
    ls.pushInteger(value);
  } else if (value is double) {
    ls.pushNumber(value);
  } else if (value is String) {
    ls.pushString(value);
  } else if (value is List) {
    ls.createTable(value.length, 0);
    for (var i = 0; i < value.length; i++) {
      dartToLua(ls, value[i]);
      ls.rawSetI(-2, i + 1);
    }
    if (value.isEmpty) {
      ls.createTable(0, 1);
      ls.pushBoolean(true);
      ls.setField(-2, luaJsonArrayMarker);
      ls.setMetatable(-2);
    }
  } else if (value is Map) {
    ls.createTable(0, value.length);
    for (final entry in value.entries) {
      ls.pushString(entry.key.toString());
      dartToLua(ls, entry.value);
      ls.setTable(-3);
    }
  } else {
    ls.pushString(value.toString());
  }
}

Object? luaToDart(LuaState ls, int index) {
  final t = ls.type(index);
  switch (t) {
    case LuaType.luaNil:
    case LuaType.luaNone:
      return null;
    case LuaType.luaBoolean:
      return ls.toBoolean(index);
    case LuaType.luaNumber:
      final asInt = ls.toIntegerX(index);
      if (asInt != null) {
        final asNum = ls.toNumber(index);
        if (asNum == asInt.toDouble()) return asInt;
        return asNum;
      }
      return ls.toNumber(index);
    case LuaType.luaString:
      return ls.toStr(index);
    case LuaType.luaTable:
      return _tableToDart(ls, index);
    default:
      return ls.toStr(index) ?? ls.typeName(t);
  }
}

Object? _tableToDart(LuaState ls, int index) {
  final absIdx = ls.absIndex(index);
  final len = ls.rawLen(absIdx);
  if (len == 0 && ls.getMetatable(absIdx)) {
    ls.getField(-1, luaJsonArrayMarker);
    final isArray = ls.toBoolean(-1);
    ls.pop(2);
    if (isArray) return <Object?>[];
  }
  if (len > 0) {
    var isArray = true;
    var keyCount = 0;
    ls.pushNil();
    while (ls.next(absIdx)) {
      final key = ls.toIntegerX(-2);
      if (key == null || key < 1 || key > len) {
        isArray = false;
        ls.pop(2);
        break;
      }
      keyCount++;
      ls.pop(1);
    }
    if (isArray && keyCount == len) {
      final list = <Object?>[];
      for (var i = 1; i <= len; i++) {
        ls.rawGetI(absIdx, i);
        list.add(luaToDart(ls, -1));
        ls.pop(1);
      }
      return list;
    }
  }
  final map = <String, Object?>{};
  ls.pushNil();
  while (ls.next(absIdx)) {
    final key = ls.toStr(-2) ?? ls.toInteger(-2).toString();
    map[key] = luaToDart(ls, -1);
    ls.pop(1);
  }
  return map;
}

// ── Comparison in Lua ──────────────────────────────────────────────────

const _same = r'''
local function same(a, b)
  if type(a) ~= type(b) then
    return false, "type " .. type(a) .. " vs " .. type(b)
  end
  if type(a) == "number" then
    if math.type(a) ~= math.type(b) then
      return false, "subtype " .. math.type(a) .. " vs " .. math.type(b)
    end
    if a == 0 and b == 0 and 1 / a ~= 1 / b then return false, "sign of 0" end
    return a == b, string.format("%.17g vs %.17g", a, b)
  end
  if type(a) ~= "table" then
    return a == b, tostring(a) .. " vs " .. tostring(b)
  end
  if rawlen(a) ~= rawlen(b) then
    return false, "rawlen " .. rawlen(a) .. " vs " .. rawlen(b)
  end
  local ma, mb = getmetatable(a), getmetatable(b)
  if (ma == nil) ~= (mb == nil) or
      (ma and ma.__json_array) ~= (mb and mb.__json_array) then
    return false, "metatable"
  end
  for k, v in next, a do
    local ok, why = same(v, rawget(b, k))
    if not ok then return false, tostring(k) .. ": " .. why end
  end
  for k in next, b do
    if rawget(a, k) == nil then return false, "extra key " .. tostring(k) end
  end
  return true
end
return same
''';

late LuaState ls;

/// Decodes [input] both ways. Null if both fail, else the reason they
/// differ, or '' if they agree.
String? decodeBoth(Uint8List input) {
  ls.setTop(0);
  ls.getGlobal('same'); // 1
  // The reference, as json_decode of the bridge: the Lua string as Dart
  // text (invalid UTF-8 as U+FFFD), jsonDecode, dartToLua.
  ls.pushBytes(input);
  final text = ls.toStr(-1)!;
  ls.pop(1);
  Object? decoded;
  var refOk = true;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    refOk = false;
  }
  if (refOk) dartToLua(ls, decoded); // 2
  // json.decode.
  ls.getGlobal('json');
  ls.getField(-1, 'decode');
  ls.remove(-2);
  ls.pushBytes(input);
  final cOk = ls.pCall(1, 1, 0) == ThreadStatus.luaOk; // 2 or 3
  if (!refOk && !cOk) return null;
  if (refOk != cOk) {
    return refOk
        ? 'only dart:convert accepts it; json.decode: ${ls.toStr(-1)}'
        : 'only json.decode accepts it';
  }
  ls.call(2, 2);
  return ls.toBoolean(1) ? '' : ls.toStr(2);
}

/// Encodes the value on the top of the stack both ways and pops it.
/// Returns null if both fail, else the reason they differ, or ''.
String? encodeBoth() {
  final v = ls.getTop();
  String? ref;
  try {
    ref = jsonEncode(luaToDart(ls, v));
  } on JsonUnsupportedObjectError {
    ref = null;
  }
  ls.getGlobal('json');
  ls.getField(-1, 'encode');
  ls.remove(-2);
  ls.pushValue(v);
  final cOk = ls.pCall(1, 1, 0) == ThreadStatus.luaOk;
  final c = ls.toStr(-1);
  ls.setTop(v - 1);
  if (ref == null && !cOk) return null;
  if (ref == null) return 'only json.encode accepts it: $c';
  if (!cOk) return 'only jsonEncode accepts it; json.encode: $c';
  return ref == c ? '' : 'jsonEncode $ref\njson.encode $c';
}

Uint8List bytes(String s) => utf8.encode(s);

// ── Random input ───────────────────────────────────────────────────────

final _maxInt = _js ? 9007199254740991 : (1 << 63) - 1;

double _randomDouble(Random r) {
  switch (r.nextInt(6)) {
    case 0:
      final data = ByteData(8);
      for (var i = 0; i < 8; i++) {
        data.setUint8(i, r.nextInt(256));
      }
      final d = data.getFloat64(0);
      return d.isFinite ? d : 0.5;
    case 1:
      return (r.nextDouble() - 0.5) * pow(10, r.nextInt(40) - 20);
    case 2:
      return r.nextInt(1000000) / 1000;
    case 3:
      return r.nextDouble() * 1e-300;
    case 4:
      return (r.nextInt(2000000) - 1000000).toDouble() * pow(10, r.nextInt(30));
    default:
      return r.nextDouble();
  }
}

int _randomInt(Random r) {
  switch (r.nextInt(4)) {
    case 0:
      return r.nextInt(100) - 50;
    case 1:
      return _maxInt - r.nextInt(5);
    case 2:
      return -_maxInt - 1 + r.nextInt(5);
    default:
      return (r.nextDouble() * 2 - 1) * 1e15 ~/ 1;
  }
}

const _alphabet = [
  'a', 'Z', '0', ' ', '"', r'\', '/', '\n', '\t', '\b', '\f', '\r', //
  '\u0000', '\u0001', '\u001f', '\u007f', '\u00e9', '\u20ac',
  '\u{1F600}', '\u2028', '\ud800', '\udc00', '\ufeff', '\uffff',
];

String _randomString(Random r) {
  final b = StringBuffer();
  for (var i = r.nextInt(8); i > 0; i--) {
    b.write(_alphabet[r.nextInt(_alphabet.length)]);
  }
  return '$b';
}

Object? _randomValue(Random r, int depth) {
  switch (r.nextInt(depth > 3 ? 6 : 8)) {
    case 0:
      return null;
    case 1:
      return r.nextBool();
    case 2:
      return _randomInt(r);
    case 3:
      return _randomDouble(r);
    case 4:
    case 5:
      return _randomString(r);
    case 6:
      return [
        for (var i = r.nextInt(5); i > 0; i--) _randomValue(r, depth + 1),
      ];
    default:
      return {
        for (var i = r.nextInt(5); i > 0; i--)
          _randomString(r): _randomValue(r, depth + 1),
      };
  }
}

/// JSON text of a random value, with random whitespace, sometimes damaged.
Uint8List _randomJson(Random r) {
  var text = jsonEncode(_randomValue(r, 0));
  if (r.nextInt(3) == 0) {
    const ws = [' ', '\t', '\n', '\r'];
    final b = StringBuffer();
    for (final c in text.split('')) {
      if (r.nextInt(4) == 0) b.write(ws[r.nextInt(4)]);
      b.write(c);
    }
    text = '$b';
  }
  final out = utf8.encode(text).toList();
  switch (r.nextInt(6)) {
    case 0 when out.isNotEmpty:
      out.removeRange(r.nextInt(out.length), out.length); // truncated
    case 1 when out.isNotEmpty:
      out[r.nextInt(out.length)] = r.nextInt(256); // one byte changed
    case 2:
      out.insert(r.nextInt(out.length + 1), r.nextInt(256));
  }
  return Uint8List.fromList(out);
}

/// [s] as a Lua string literal of its UTF-8 bytes; lone surrogates as
/// U+FFFD.
String _luaString(String s) =>
    '"${utf8.encode(s).map((b) => '\\${b.toString().padLeft(3, '0')}').join()}"';

/// Lua code for a random table, with keys and values that JSON text cannot
/// give: sparse and mixed keys, float and boolean keys, invalid UTF-8.
String _randomLua(Random r, int depth) {
  String value() => switch (r.nextInt(depth > 2 ? 7 : 9)) {
    0 => 'nil',
    1 => 'true',
    2 => '${_randomInt(r)}',
    // A Dart double's JSON text is a Lua float literal.
    3 => '(${jsonEncode(_randomDouble(r))})',
    4 => r'"\xff\xfe"',
    5 => _luaString(_randomString(r)),
    6 => '-0.0',
    7 => _randomLua(r, depth + 1),
    _ => 'print',
  };
  final parts = <String>[];
  for (var i = r.nextInt(6); i > 0; i--) {
    switch (r.nextInt(6)) {
      case 0:
        parts.add('[${r.nextInt(6)}] = ${value()}');
      case 1:
        parts.add('[${r.nextInt(3)}.5] = ${value()}');
      case 2:
        parts.add('[${r.nextBool()}] = ${value()}');
      case 3:
        parts.add('["${r.nextInt(3)}"] = ${value()}');
      case 4:
        parts.add('["\\xff${r.nextInt(2)}"] = ${value()}');
      default:
        parts.add(value());
    }
  }
  return '{${parts.join(', ')}}';
}

void main() {
  setUpAll(
    () => LuaState.loadRuntime(
      moduleUri: Uri.parse('packages/lua_dart/web/lua_dart_module.mjs'),
    ),
  );
  setUp(() {
    ls = LuaState.newState()..openLibs(sandbox: true);
    expect(ls.doString(_same), isTrue);
    ls.setGlobal('same');
  });
  tearDown(() => ls.close());

  final noReference = _js
      ? 'dart:convert compiled to JavaScript has no int/double distinction; '
            'the golden tests cover dart2js'
      : null;

  test('the sandbox opens json', () {
    expect(ls.doString('return json.encode(json.decode("[1,2]"))'), isTrue);
    expect(ls.toStr(-1), '[1,2]');
  });

  group('golden', () {
    // Results of the parity tests below, on native and dart2wasm: the C code
    // gives them on every platform, also where the reference cannot run.
    const roundTrips = {
      '[1,1.0,-0,-0.0,1e2,0.1,1e21,1e-7,9223372036854775807]':
          '[1,1,0,0,100,0.1,1e+21,1e-7,9223372036854775807]',
      '[1.5,1e20,12345678901234567890,-9223372036854775808]':
          '[1.5,100000000000000000000.0,12345678901234567000.0,'
          '-9223372036854775808]',
      r'["\u00e9\ud83d\ude00\ud83d",true,[],{}]':
          '["\u00e9\u{1F600}\ufffd",true,[],{}]',
      // As with dart:convert and the bridge: null leaves a hole, and a table
      // with a hole is an object.
      '{"a":[1,null,3]}': '{"a":{"1":1,"3":3}}',
      '"\\t/\\u0001\\u2028"': '"\\t/\\u0001\u2028"',
    };
    for (final MapEntry(key: input, value: output) in roundTrips.entries) {
      test(input, () {
        ls.pushString(input);
        ls.setGlobal('input');
        expect(
          ls.doString('return json.encode(json.decode(input))'),
          isTrue,
          reason: ls.toStr(-1),
        );
        expect(ls.toStr(-1), output);
      });
    }
    test('types', () {
      expect(
        ls.doString('''
          local v = json.decode('[1, 1.0, 9223372036854775807, 1e400, "x"]')
          return math.type(v[1]) .. math.type(v[2]) .. tostring(v[3]) ..
            tostring(v[4]) .. #v .. tostring(#json.decode("[1,null,3]"))
        '''),
        isTrue,
        reason: ls.toStr(-1),
      );
      expect(ls.toStr(-1), 'integerfloat9223372036854775807inf53');
    });
    test('errors', () {
      for (final bad in ['', '[1,]', '01', 'nul', '"\t"', '1 2', '{"a"}']) {
        ls.pushString(bad);
        ls.setGlobal('input');
        expect(ls.doString('return json.decode(input)'), isFalse, reason: bad);
        ls.setTop(0);
      }
      expect(ls.doString('return json.encode(0/0)'), isFalse);
    });
  });

  group('decode', skip: noReference, () {
    final cases = <String>[
      '1', '-0', '-0.0', '0', '1.0', '1e2', '1E+2', '1e-0', '0.5e-3', //
      '12345678901234567890', '9223372036854775807', '9223372036854775808',
      '-9223372036854775808', '-9223372036854775809', '1e400', '-1e400',
      '1e-400', '4.9e-324', '2.2250738585072011e-308', '0.1', '123.456e7',
      'true', 'false', 'null', '"x"', ' 1 ', '\t\n\r 1', '[]', '{}',
      '[1,null,3]', '[null]', '[null,null]', '[1,2,null]', '{"a":null}',
      '{"a":1,"a":2}', '{"a":1,"a":null}', '{"a":null,"a":1}', '{"1":1}',
      '[[],[[]],{}]', r'"\u0041\u00e9\u20ac"', r'"\ud83d\ude00"',
      r'"\ud83d"', r'"\ude00"', r'"\ude00\ud83d"', r'"\ud83dx"',
      r'"\ud83d\u0041"', r'"\uD83D\uDE00"', r'"\/"', r'"\b\f\n\r\t"',
      r'"\"\\"', '"\u00e9\u{1F600}"', '{"\u00e9":[1,{"x":"y"}]}',
      // Invalid.
      '', ' ', '[1,]', '{"a":1,}', '01', '-01', '1.', '.5', '-', '1e',
      '1e+', '+1', '0x10', 'NaN', 'Infinity', 'nul', 'tru', 'True', '[',
      '{', '"', '"abc', r'"\x"', r'"\u12"', r'"\u12G4"', '"\t"', '\ufeff1',
      'true false', '[1 2]', '{"a" 1}', '{1:2}', "{'a':1}", '[1]x',
      '/*c*/1', '1//c',
    ];
    for (final c in cases) {
      test(jsonEncode(c), () => expect(decodeBoth(bytes(c)) ?? '', ''));
    }

    test('invalid UTF-8 in strings', () {
      final inputs = <List<int>>[
        [0x22, 0xFF, 0x22],
        [0x22, 0x61, 0xED, 0xA0, 0x80, 0x62, 0x22],
        [0x22, 0xF0, 0x9F, 0x98, 0x63, 0x22],
        [0x22, 0xC0, 0xAF, 0x22],
        [0x22, 0xE2, 0x82, 0x22],
        [0x22, 0xF4, 0x90, 0x80, 0x80, 0x22],
        [0x22, 0xF0, 0x9F, 0x98, 0x80, 0x22],
        [0x22, 0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x22],
        [0x22, 0x00, 0x22],
        [0x31, 0xFF],
        [0x5B, 0x22, 0xFF, 0x22, 0x5D],
      ];
      for (final input in inputs) {
        expect(
          decodeBoth(Uint8List.fromList(input)) ?? '',
          '',
          reason: '$input',
        );
      }
    });

    test('nesting deeper than 1000 fails, 1000 works', () {
      expect(
        ls.doString('return json.decode(("["):rep(1000) .. ("]"):rep(1000))'),
        isTrue,
      );
      expect(
        ls.doString('return json.decode(("["):rep(1001) .. ("]"):rep(1001))'),
        isFalse,
      );
      expect(ls.toStr(-1), contains('too deeply nested'));
    });

    test('random JSON text, also damaged', () {
      final r = Random(1);
      var accepted = 0;
      for (var i = 0; i < 3000; i++) {
        final input = _randomJson(r);
        final result = decodeBoth(input);
        if (result != null) accepted++;
        expect(
          result ?? '',
          '',
          reason: utf8.decode(input, allowMalformed: true),
        );
      }
      expect(accepted, greaterThan(1000));
    });
  });

  group('encode', skip: noReference, () {
    final values = <String>[
      'nil', 'true', 'false', '0', '-0.0', '1', '-1', '2.0', '2.5', '1e20', //
      '1e21', '1e-7', '1e-6', '1.5e-6', '0.1 + 0.2', '123.456', '5e-324',
      '1.7976931348623157e308', '2^53', '2^63', '-2^63', 'math.maxinteger',
      'math.mininteger', '1/0', '-1/0', '0/0', '"x"', r'"a\"b\\c/d"',
      r'"\0\1\8\t\n\11\12\r\31\127"', r'"é😀\u{2028}"', r'"\xff"',
      r'"a\xed\xa0\x80b"', '{}', '{1, 2, 3}', '{1, nil, 3}', '{nil, 2}',
      '{[1] = "a", [3] = "c"}', '{[1] = "a", x = "b"}', '{[0] = 1}',
      '{[-1] = 1}', '{[1.5] = 1}', '{[true] = 1}', '{[false] = 1, [0] = 2}',
      '{["1"] = 1}', '{"a", ["1"] = "b"}', '{[1] = 1, ["1"] = 2}',
      r'{["\xff"] = 1, ["\xfe"] = 2}', '{[2^63] = 1}', '{[math.huge] = 1}',
      'setmetatable({}, {__json_array = true})',
      'setmetatable({}, {__json_array = false})',
      'setmetatable({1}, {__json_array = true})',
      'setmetatable({}, {__index = {__json_array = true}})',
      'setmetatable({x = 1}, {__pairs = function() end, '
          '__len = function() return 9 end})',
      'print', 'coroutine.create(print)', '{f = print}', '{{{}}}',
      '{a = {b = {c = {1, 2, {d = "e"}}}}}',
    ];
    for (final v in values) {
      test(v, () {
        expect(ls.doString('return $v'), isTrue, reason: ls.toStr(-1));
        expect(encodeBoth() ?? '', '');
      });
    }

    test('a cycle fails', () {
      expect(
        ls.doString('local t = {} t.t = t return json.encode(t)'),
        isFalse,
      );
      expect(ls.toStr(-1), contains('cycle'));
    });

    test('random doubles print as Dart prints them', () {
      final r = Random(2);
      for (var i = 0; i < 5000; i++) {
        final d = _randomDouble(r);
        ls.pushNumber(d);
        expect(encodeBoth() ?? '', '', reason: '$d');
      }
    });

    test('random tables', () {
      final r = Random(3);
      for (var i = 0; i < 2000; i++) {
        final code = 'return ${_randomLua(r, 0)}';
        expect(ls.doString(code), isTrue, reason: '$code\n${ls.toStr(-1)}');
        expect(encodeBoth() ?? '', '', reason: code);
      }
    });

    test('decoded random JSON encodes as jsonEncode does', () {
      final r = Random(4);
      for (var i = 0; i < 2000; i++) {
        final text = jsonEncode(_randomValue(r, 0));
        ls.getGlobal('json');
        ls.getField(-1, 'decode');
        ls.remove(-2);
        ls.pushString(text);
        ls.call(1, 1);
        expect(encodeBoth() ?? '', '', reason: text);
      }
    });
  });
}
