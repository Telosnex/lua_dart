import 'package:lua_dart/lua_parser.dart';
import 'package:test/test.dart';

LocalVarDeclStat _decl(String code) =>
    Parser.parse(code, 'test').stats.whereType<LocalVarDeclStat>().first;

void main() {
  group('local attributes', () {
    test('parse into attribList', () {
      expect(_decl('local x <const> = 1').attribList, [LocalAttrib.const_]);
      expect(_decl('local f <close> = nil').attribList, [LocalAttrib.close]);
      final d = _decl('local a, b <const>, c <close> = 1, 2, nil');
      expect(d.nameList, ['a', 'b', 'c']);
      expect(d.attribList, [null, LocalAttrib.const_, LocalAttrib.close]);
      expect(d.expList, hasLength(3));
    });

    test('an attribute before the names is the default (Lua 5.5)', () {
      final d = _decl('local <const> a, b <close>, c = 1, nil, 3');
      expect(d.nameList, ['a', 'b', 'c']);
      expect(d.attribList, [
        LocalAttrib.const_,
        LocalAttrib.close,
        LocalAttrib.const_,
      ]);
      expect(
        () => Parser.parse('local <close> a, b = nil, nil', 'test'),
        throwsException,
      );
    });

    test('no attributes: attribList is null', () {
      expect(_decl('local a, b = 1, 2').attribList, isNull);
      expect(_decl('local a').attribList, isNull);
    });

    test('a comparison after a local is not an attribute', () {
      final block = Parser.parse('local a = 1 < 2', 'test');
      expect(
        block.stats.whereType<LocalVarDeclStat>().first.attribList,
        isNull,
      );
    });

    test('invalid attributes fail, as in Lua', () {
      for (final code in [
        'local x <foo> = 1',
        'local x <const = 1',
        'local x <> = 1',
        'local a <close>, b <close> = nil, nil',
      ]) {
        expect(() => Parser.parse(code, 'test'), throwsException, reason: code);
      }
    });
  });

  group('global declarations (Lua 5.5)', () {
    Stat stat(String code) => Parser.parse(code, 'test').stats.first;

    test('global names, with attributes and values', () {
      final d = stat('global <const> a, b = 1, 2') as GlobalVarDeclStat;
      expect(d.nameList, ['a', 'b']);
      expect(d.attribList, [LocalAttrib.const_, LocalAttrib.const_]);
      expect(d.expList, hasLength(2));
      final plain = stat('global x') as GlobalVarDeclStat;
      expect(plain.nameList, ['x']);
      expect(plain.attribList, isNull);
      expect(plain.expList, isEmpty);
    });

    test('global *', () {
      expect((stat('global *') as GlobalCollectiveDeclStat).attrib, isNull);
      expect(
        (stat('global <const> *') as GlobalCollectiveDeclStat).attrib,
        LocalAttrib.const_,
      );
    });

    test('global function', () {
      final d = stat('global function f(a) return a end') as GlobalFuncDefStat;
      expect(d.name, 'f');
      expect(d.exp.parList, ['a']);
    });

    test('global is a name where it starts no declaration', () {
      final assign = stat('global = 1') as AssignStat;
      expect((assign.varList.single as NameExp).name, 'global');
      expect(stat('global.x = 1'), isA<AssignStat>());
      expect(stat('global(1)'), isA<FuncCallStat>());
      expect(stat('global:m()'), isA<FuncCallStat>());
      expect(stat('local global = 1'), isA<LocalVarDeclStat>());
    });

    test('a global cannot be to-be-closed', () {
      expect(() => Parser.parse('global <close> x', 'test'), throwsException);
      expect(() => Parser.parse('global x <close>', 'test'), throwsException);
    });
  });

  group('vararg parameters', () {
    FuncDefExp def(String code) =>
        (Parser.parse(code, 'test').stats.single as LocalFuncDefStat).exp;

    test('a named vararg parameter (Lua 5.5)', () {
      final d = def('local function f(a, ...rest) end');
      expect(d.parList, ['a']);
      expect(d.isVararg, isTrue);
      expect(d.varargName, 'rest');
    });

    test('plain ... has no name; no vararg has neither', () {
      final plain = def('local function f(...) end');
      expect(plain.isVararg, isTrue);
      expect(plain.varargName, isNull);
      final none = def('local function f(a) end');
      expect(none.isVararg, isFalse);
      expect(none.varargName, isNull);
    });
  });

  test('a call with a string argument', () {
    final stat =
        Parser.parse('call_tool("web_get", {url = u})', 'test').stats.single
            as FuncCallStat;
    expect((stat.exp.prefixExp as NameExp).name, 'call_tool');
    expect((stat.exp.args.first as StringExp).str, 'web_get');
    expect(stat.exp.args[1], isA<TableConstructorExp>());
  });

  test('errors give the chunk name and line', () {
    expect(
      () => Parser.parse('local x = 1\nx = = 2', 'mod.lua'),
      throwsA(predicate((e) => '$e'.contains('mod.lua:2:'))),
    );
  });
}
