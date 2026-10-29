// The Dart parser (lua_parser.dart) against Lua's own compiler (lparser.c,
// through LuaState.load): a parser differential test.
//
// The rule: every chunk that Lua compiles, the Dart parser parses. A chunk
// that the Dart parser refuses would cost an analyzer its result. The other
// way, the Dart parser may accept a chunk that Lua refuses only for a check
// that lparser.c makes after the grammar (kSemanticChecks): such a chunk
// cannot run anyway.
//
// A Lua bump must keep this test passing.
import 'dart:math';

import 'package:lua_dart/lua_dart.dart';
import 'package:lua_dart/lua_parser.dart';
import 'package:test/test.dart';

/// Chunks that cover the Lua 5.4 grammar (manual section 9).
const kSeeds = <String>[
  '',
  ';;',
  'local a',
  'local a, b, c = 1, 2.5, "x"',
  'local x <const> = 10 local y <close> = nil',
  'a = 1 b, c = 2, 3 t.x, t[1] = 4, 5',
  'a.b.c = d.e:f(g)[h]',
  'f() f"s" f[[long]] f{1, 2} o:m() o:m"s" o:m{}',
  'f(a)(b)(c) ("s"):upper()',
  'do local a = 1 end',
  'while x do x = x - 1 end',
  'repeat local y = 1 until y',
  'if a then elseif b then else end',
  'for i = 1, 10 do end for i = 10, 1, -1 do end',
  'for k, v in pairs(t) do end for a, b, c in f() do end',
  'function f() end function a.b.c:d(x, ...) return ... end',
  'local function f(a, b) return a + b end',
  'local f = function(...) local t = {...} return #t, select("#", ...) end',
  'return',
  'return 1, 2, 3;',
  'do return end',
  'while true do break end',
  'goto done ::done::',
  'for i = 1, 3 do if i == 2 then goto continue end ::continue:: end',
  'x = 1 + 2 - 3 * 4 / 5 // 6 % 7 ^ 8',
  'x = 1 .. 2 .. "s" .. 3.0',
  'x = a == b and c ~= d or e < f and g <= h or i > j and k >= l',
  'x = not a x = -a x = #t x = ~a',
  'x = a & b | c ~ d << 1 >> 2',
  'x = 2^-3^2 x = -2^2 x = not not a',
  'x = 0x10 + 0xA.8p1 + 1e10 + 1E-3 + .5 + 3. + 0x.1P4',
  'x = 9007199254740993 x = 0xffffffffffffffff',
  r'''x = "a\n\t\\\"\'\a\b\f\r\v" .. '\65\066\x41\u{48}\u{7FFFFFFF}' .. "\z
       continued"''',
  'x = [[\nfirst newline skipped]] y = [==[ ]] ]=] ]==]',
  '-- comment\n--[[ long\ncomment ]] x = 1 --[==[ ]] ]==] y = 2',
  'x = {} x = {1, 2, 3,} x = {a = 1; b = 2, [3] = 4, f(), ...}',
  'local t = {[1] = {[2] = {x = {y = {}}}}}',
  'x = (f())',
  'x = function() end x = {function() end}',
  'local a <const>, b = 1, 2 return a + b',
  'local s = ("x"):rep(3)',
  'return function(...) return select(2, ...) end',
  'x = a.b["c"].d:e(f).g',
  'local _ENV = {} x = 1',
  'x = 1 // 0 x = 1 % 0',
  r'x = "\xff\xfe"',
  'if a then return elseif b then return 1 else return 2 end',
  'local function g() local function h() return h end return h end',
  'for i = 1, 2 do for j = 1, 2 do for k = 1, 2 do end end end',
];

/// Chunks that both must refuse.
const kInvalid = <String>[
  'x =',
  'local',
  'local 1 = 2',
  'f(',
  'x = {',
  'if a then',
  'for i = 1 do end',
  'function end',
  'x = 1 +',
  'return return',
  'x = "unfinished',
  'x = [[unfinished',
  '--[[ unfinished',
  r'x = "\q"',
  r'x = "\xZZ"',
  r'x = "\u{110000000}"',
  'x = 0x',
  'x = 1e',
  'x = 3..2',
  'local x <foo> = 1',
  'x = = 1',
  'a.b:c = 1',
  'f() = 1',
  '(a) = 1',
  'goto',
  '::a',
  'x = @',
  r'x = $',
  'x = !a',
  'x = a ? b : c',
  'x = a += 1',
  'local function a.b() end',
  'return 1 x = 2',
  'break break 1',
  '#!shebang line\nreturn 1',
];

/// Messages of the checks that lparser.c makes beyond the grammar. Only
/// these may make Lua refuse a chunk that the Dart parser accepts.
final kSemanticChecks = RegExp(
  r'break outside (a )?loop|no visible label|label .* already defined|'
  r'attempt to assign to const variable|multiple to-be-closed|'
  r'cannot use .\.\.\.. outside a vararg function|too many|overflow|'
  r'jumps into the scope of local',
);

/// Null if Lua compiles [code]; else its message.
String? _luaError(LuaState ls, String code) {
  final status = ls.loadString(code, chunkName: '=chunk');
  final message = status == ThreadStatus.luaOk ? null : ls.toStr(-1);
  ls.pop(1);
  return message;
}

/// Null if the Dart parser parses [code]; else its message.
String? _dartError(String code) {
  try {
    Parser.parse(code, 'chunk');
    return null;
  } on Exception catch (e) {
    return '$e';
  }
  // Errors (a RangeError from the lexer, say) are not caught: they fail
  // the test, as they are parser bugs.
}

/// The ways the two parsers disagree on [code], or empty.
List<String> _disagreements(LuaState ls, String code) {
  final lua = _luaError(ls, code);
  final dart = _dartError(code);
  if (lua == null && dart != null) {
    return ['Lua compiles it, Dart refuses it: $dart'];
  }
  if (lua != null && dart == null && !kSemanticChecks.hasMatch(lua)) {
    return ['Dart parses it, Lua refuses it: $lua'];
  }
  return const [];
}

const _kFragments = [
  ' ',
  '\n',
  '(',
  ')',
  '{',
  '}',
  '[',
  ']',
  '[[',
  ']]',
  '=',
  '==',
  '~=',
  '.',
  '..',
  '...',
  ',',
  ';',
  ':',
  '::',
  '"',
  "'",
  '\\',
  '#',
  '-',
  '--',
  '<',
  '>',
  '<const>',
  '<close>',
  '0x',
  '1',
  '.5',
  'e',
  'local',
  'end',
  'do',
  'then',
  'function',
  'return',
  'nil',
  'not',
  'and',
  'goto',
  'x',
];

/// [seed] with one random edit: a character deleted, a fragment inserted,
/// or two characters swapped.
String _mutate(String seed, Random random) {
  if (seed.isEmpty) return _kFragments[random.nextInt(_kFragments.length)];
  final at = random.nextInt(seed.length);
  switch (random.nextInt(3)) {
    case 0:
      return seed.substring(0, at) + seed.substring(at + 1);
    case 1:
      final fragment = _kFragments[random.nextInt(_kFragments.length)];
      return seed.substring(0, at) + fragment + seed.substring(at);
    default:
      final other = random.nextInt(seed.length);
      final chars = seed.split('');
      final c = chars[at];
      chars[at] = chars[other];
      chars[other] = c;
      return chars.join();
  }
}

void main() {
  late LuaState ls;
  setUpAll(
    () => LuaState.loadRuntime(
      moduleUri: Uri.parse('packages/lua_dart/web/lua_dart_module.mjs'),
    ),
  );
  setUp(() => ls = LuaState.newState());
  tearDown(() => ls.close());

  test('the seeds compile in Lua and parse in Dart', () {
    for (final code in kSeeds) {
      expect(_luaError(ls, code), isNull, reason: code);
      expect(_dartError(code), isNull, reason: code);
    }
  });

  test('both refuse the invalid chunks', () {
    for (final code in kInvalid) {
      expect(_luaError(ls, code), isNotNull, reason: code);
      expect(_dartError(code), isNotNull, reason: code);
    }
  });

  test('mutated chunks: the parsers agree', () {
    final random = Random(54);
    final found = <String, List<String>>{};
    var compiled = 0;
    for (var i = 0; i < 20000; i++) {
      var code = kSeeds[random.nextInt(kSeeds.length)];
      for (var edits = 1 + random.nextInt(3); edits > 0; edits--) {
        code = _mutate(code, random);
      }
      if (_luaError(ls, code) == null) compiled++;
      final d = _disagreements(ls, code);
      if (d.isNotEmpty) found.putIfAbsent(code, () => d);
    }
    expect(
      found.entries.map((e) => '${e.key}\n  ${e.value.join('\n  ')}').toList(),
      isEmpty,
      reason: found.entries
          .map((e) => '>>> ${e.key}\n  ${e.value.join('\n  ')}')
          .join('\n'),
    );
    // The mutations must not all be garbage.
    expect(compiled, greaterThan(2000));
  });
}
