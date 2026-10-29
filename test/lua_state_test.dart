import 'dart:convert';
import 'dart:typed_data';

import 'package:lua_dart/lua_dart.dart';
import 'package:test/test.dart';

LuaState sandboxed({int memoryLimit = 0}) =>
    LuaState.newState(memoryLimit: memoryLimit)..openLibs(sandbox: true);

/// Runs [code] and returns its first result as text, or throws its error.
String? eval(LuaState ls, String code) {
  final top = ls.getTop();
  if (!ls.doString(code, chunkName: '=test')) {
    final message = ls.toStr(-1);
    ls.setTop(top);
    throw LuaError(message ?? '?');
  }
  final result = ls.getTop() > top ? ls.toStr(top + 1) : null;
  ls.setTop(top);
  return result;
}

void main() {
  late LuaState ls;
  setUpAll(
    () => LuaState.loadRuntime(
      moduleUri: Uri.parse('packages/lua_dart/web/lua_dart_module.mjs'),
    ),
  );
  setUp(() => ls = sandboxed());
  tearDown(() => ls.close());

  test('build info names the ABI and the pinned Lua release', () {
    expect(LuaState.buildInfo, 'lua_dart ABI 1; Lua 5.4.9');
    expect(eval(ls, 'return _VERSION'), 'Lua 5.4');
  });

  group('values', () {
    test('numbers keep their Lua subtype and tostring format', () {
      expect(eval(ls, 'return 1 + 2'), '3');
      expect(eval(ls, 'return 10 / 4'), '2.5');
      expect(eval(ls, 'return 3.0'), '3.0');
      expect(eval(ls, 'return 2^63'), '9.2233720368548e+18');
      expect(eval(ls, 'return math.maxinteger'), '9223372036854775807');
      expect(eval(ls, 'return 1/0'), 'inf');

      // dart2js has 53-bit ints.
      final big = identical(0, 0.0) ? -(1 << 52) : luaMinInteger;
      ls.pushInteger(big);
      expect(ls.isInteger(-1), isTrue);
      expect(ls.toIntegerX(-1), big);
      ls.pushNumber(1.5);
      expect(ls.isInteger(-1), isFalse);
      expect(ls.toIntegerX(-1), isNull);
      expect(ls.toNumber(-1), 1.5);
      ls.pushString('42');
      expect(ls.isNumber(-1), isTrue);
      expect(ls.toIntegerX(-1), 42);
      expect(ls.type(-1), LuaType.luaString);
    });

    test('toStr of a number does not change the value on the stack', () {
      ls.pushNumber(2.5);
      expect(ls.toStr(-1), '2.5');
      expect(ls.type(-1), LuaType.luaNumber);
    });

    test('strings round-trip as UTF-8, and bytes as bytes', () {
      const text = 'héllo — 世界 🌍';
      ls.pushString(text);
      expect(ls.toStr(-1), text);
      expect(ls.rawLen(-1), utf8.encode(text).length);
      ls.pushString('a\u0000b');
      expect(ls.rawLen(-1), 3);
      expect(ls.toStr(-1), 'a\u0000b');

      ls.pushBytes(Uint8List.fromList([0xff, 0x00, 0x41]));
      expect(ls.toBytes(-1), [0xff, 0x00, 0x41]);
      expect(ls.toStr(-1), '\ufffd\u0000A');
    });

    test('tables: get, set, raw access, next and length', () {
      ls.createTable(2, 1);
      ls.pushString('a');
      ls.rawSetI(-2, 1);
      ls.pushString('b');
      ls.rawSetI(-2, 2);
      ls.pushInteger(7);
      ls.setField(-2, 'x');
      ls.pushNumber(0.5);
      ls.pushString('half');
      ls.setTable(-3);
      ls.setGlobal('t');

      expect(
        eval(ls, 'return #t .. t[1] .. t[2] .. t.x .. t[0.5]'),
        '2ab7half',
      );
      ls.getGlobal('t');
      expect(ls.rawLen(-1), 2);
      expect(ls.len2(-1), 2);
      expect(ls.getField(-1, 'x'), LuaType.luaNumber);
      expect(ls.toInteger(-1), 7);
      ls.pop(1);
      expect(ls.getI(-1, 2), LuaType.luaString);
      ls.pop(1);

      final keys = <String>[];
      ls.pushNil();
      while (ls.next(-2)) {
        // toStr on a number key must not break the traversal.
        keys.add(ls.toStr(-2)!);
        ls.pop(1);
      }
      expect(keys, unorderedEquals(['1', '2', 'x', '0.5']));
      expect(ls.getTop(), 1);
    });

    test('metatables and metamethods', () {
      eval(ls, '''
        V = setmetatable({}, {
          __index = function(_, k) return k .. "!" end,
          __len = function() return 99 end,
          __tostring = function() return "a V" end,
          __lt = function() return true end,
        })''');
      ls.getGlobal('V');
      expect(ls.getField(-1, 'hey'), LuaType.luaString);
      expect(ls.toStr(-1), 'hey!');
      ls.pop(1);
      expect(ls.len2(-1), 99);
      expect(ls.toString2(-1), 'a V');
      ls.pop(1);
      ls.pushValue(-1);
      expect(ls.compare(-2, -1, CmpOp.luaOpLt), isTrue);
      expect(ls.rawEqual(-2, -1), isTrue);
      expect(ls.getMetatable(-1), isTrue);
    });

    test('arith, concat and stringToNumber', () {
      ls.pushInteger(7);
      ls.pushInteger(2);
      ls.arith(ArithOp.luaOpIdiv);
      expect(ls.toInteger(-1), 3);
      ls.arith(ArithOp.luaOpUnm);
      expect(ls.toInteger(-1), -3);
      ls.pushString('x');
      ls.pushNumber(1.5);
      ls.concat(3);
      expect(ls.toStr(-1), '-3x1.5');
      expect(ls.stringToNumber('0x10'), isTrue);
      expect(ls.toInteger(-1), 16);
      expect(ls.stringToNumber('nope'), isFalse);
    });

    test('registry references', () {
      ls.pushString('kept');
      final ref = ls.ref(luaRegistryIndex);
      expect(ref, greaterThan(0));
      expect(ls.rawGetI(luaRegistryIndex, ref), LuaType.luaString);
      expect(ls.toStr(-1), 'kept');
      ls.pop(1);
      ls.unRef(luaRegistryIndex, ref);
      ls.pushNil();
      expect(ls.ref(luaRegistryIndex), luaRefNil);
    });
  });

  group('checked stack indices', () {
    test('bad indices throw instead of corrupting memory', () {
      void throwsArg(void Function() f) => expect(
        f,
        throwsA(
          isA<LuaError>().having(
            (e) => e.status,
            'status',
            ThreadStatus.luaErrArg,
          ),
        ),
      );
      throwsArg(() => ls.pushValue(1));
      throwsArg(() => ls.pushValue(-1));
      throwsArg(() => ls.setTable(1));
      throwsArg(() => ls.pop(1));
      throwsArg(() => ls.absIndex(3));
      ls.pushInteger(1);
      throwsArg(() => ls.next(1)); // not a table
      throwsArg(() => ls.rawSetI(1, 1));
      throwsArg(() => ls.setMetatable(1)); // top is not a table
      throwsArg(() => ls.rotate(1, 3));
      throwsArg(() => ls.arith(ArithOp.luaOpAdd));
      expect(ls.getTop(), 1);
      expect(ls.type(5), LuaType.luaNone);
      expect(ls.type(-5), LuaType.luaNone);
      expect(ls.toStr(9), isNull);
    });

    test('the stack grows on demand and reports overflow', () {
      for (var i = 0; i < 10000; i++) {
        ls.pushInteger(i);
      }
      expect(ls.getTop(), 10000);
      expect(ls.toInteger(1), 0);
      ls.setTop(0);
      expect(ls.checkStack(2000000), isFalse);
    });
  });

  group('load and call', () {
    test('syntax and runtime errors', () {
      expect(ls.loadString('x = = 1'), ThreadStatus.luaErrSyntax);
      expect(ls.toStr(-1), contains("unexpected symbol near '='"));
      ls.pop(1);
      expect(ls.doString('error("boom")', chunkName: '=chunk'), isFalse);
      expect(ls.toStr(-1), 'chunk:1: boom');
      ls.pop(1);
      expect(ls.doString('error({code = 7})'), isFalse);
      expect(ls.getField(-1, 'code'), LuaType.luaNumber);
      expect(ls.toInteger(-1), 7);
      ls.setTop(0);
    });

    test('call throws LuaError and pops the error object', () {
      eval(
        ls,
        'function f(a, b) if a then return a + b, a * b end '
        'error("no a") end',
      );
      ls.getGlobal('f');
      ls.pushInteger(3);
      ls.pushInteger(4);
      ls.call(2, 2);
      expect([ls.toInteger(-2), ls.toInteger(-1)], [7, 12]);
      ls.setTop(0);
      ls.getGlobal('f');
      expect(
        () => ls.call(0, 0),
        throwsA(
          isA<LuaError>().having((e) => e.message, 'message', 'test:1: no a'),
        ),
      );
      expect(ls.getTop(), 0);
    });

    test('pCall with a traceback and with a message handler', () {
      ls.loadString(
        'local function inner() error("deep") end inner()',
        chunkName: '=tb',
      );
      expect(ls.pCall(0, 0, 0, traceback: true), ThreadStatus.luaErrRun);
      expect(
        ls.toStr(-1),
        allOf(contains('tb:1: deep'), contains('stack traceback')),
      );
      ls.setTop(0);

      eval(ls, 'function handler(e) return "handled: " .. e end');
      ls.getGlobal('handler');
      ls.loadString('error("x", 0)');
      expect(ls.pCall(0, 0, 1), ThreadStatus.luaErrRun);
      expect(ls.toStr(-1), 'handled: x');
      ls.setTop(0);
    });

    test('binary chunks are refused by the API and by load()', () {
      final dumped = eval(ls, 'return string.dump(function() return 1 end)');
      expect(dumped, isNotNull);
      final bytes = Uint8List.fromList([0x1b, ...utf8.encode('Lua')]);
      expect(ls.load(bytes, '=bin'), ThreadStatus.luaErrSyntax);
      expect(ls.toStr(-1), contains('binary'));
      ls.pop(1);
      expect(
        eval(ls, '''
          local f, e = load(string.dump(function() end))
          return tostring(f) .. " " .. e'''),
        allOf(startsWith('nil '), contains('binary')),
      );
    });
  });

  group('host functions', () {
    test('arguments, results and closures over Dart state', () {
      var calls = 0;
      ls.register('add', (ls) {
        calls++;
        ls.pushInteger(ls.checkInteger(1) + ls.checkInteger(2));
        ls.pushString('sum');
        return 2;
      });
      expect(eval(ls, 'local n, s = add(2, 3) return s .. n'), 'sum5');
      expect(calls, 1);
      ls.getGlobal('add');
      expect(ls.isDartFunction(-1), isTrue);
      expect(ls.isFunction(-1), isTrue);
      ls.pop(1);
    });

    test('argument errors name the function and the caller position', () {
      ls.register('needs_string', (ls) {
        ls.checkString(1);
        return 0;
      });
      expect(
        () => eval(ls, 'needs_string({})'),
        throwsA(
          isA<LuaError>().having(
            (e) => e.message,
            'message',
            "test:1: bad argument #1 to 'needs_string' (string expected, got table)",
          ),
        ),
      );
      expect(
        () => eval(ls, '\n\nneeds_string()'),
        throwsA(
          isA<LuaError>().having(
            (e) => e.message,
            'message',
            "test:3: bad argument #1 to 'needs_string' (string expected, got no value)",
          ),
        ),
      );
    });

    test('error2 adds the position; Dart exceptions become messages', () {
      ls.register('fail', (ls) => ls.error2('it failed'));
      ls.register('throws', (ls) => throw StateError('dart side'));
      // As luaL_error: the position of the Lua caller; none for a C caller.
      expect(
        eval(ls, '''
        local ok, e = pcall(function() fail() end)
        return e'''),
        'test:1: it failed',
      );
      expect(eval(ls, 'local ok, e = pcall(fail) return e'), 'it failed');
      expect(
        eval(ls, '''
        local ok, e = pcall(throws)
        return e'''),
        'Bad state: dart side',
      );
    });

    test('error() raises the error object itself', () {
      ls.register('raise_table', (ls) {
        ls.createTable(0, 1);
        ls.pushInteger(404);
        ls.setField(-2, 'code');
        ls.error();
      });
      expect(
        eval(ls, '''
        local ok, e = pcall(raise_table)
        return type(e) .. e.code'''),
        'table404',
      );
    });

    test('host functions call back into Lua, re-entrantly', () {
      ls.register('apply', (ls) {
        ls.pushValue(1);
        ls.pushValue(2);
        ls.call(1, 1);
        return 1;
      });
      expect(
        eval(ls, '''
        local function fact(n)
          if n <= 1 then return 1 end
          return n * apply(fact, n - 1)
        end
        return fact(10)'''),
        '3628800',
      );
    });

    test('a Lua error inside a nested call reaches the outer pcall', () {
      ls.register('apply', (ls) {
        ls.pushValue(1);
        ls.call(0, 0);
        return 0;
      });
      expect(
        eval(ls, '''
        local ok, e = pcall(apply, function() error("inner", 0) end)
        return tostring(ok) .. " " .. e'''),
        'false inner',
      );
    });

    test('host functions run inside coroutines and get the thread', () {
      final threads = <bool>[];
      ls.register('where', (ls) {
        threads.add(ls.isMainThread);
        ls.pushInteger(ls.getTop());
        return 1;
      });
      expect(
        eval(ls, '''
        local co = coroutine.wrap(function(a)
          local n = where(a, a)
          coroutine.yield(n)
        end)
        return co(1) + where()'''),
        '2',
      );
      expect(threads, [false, true]);
    });

    test('yield across pcall works (Lua 5.4)', () {
      expect(
        eval(ls, '''
        local co = coroutine.wrap(function()
          local ok, v = pcall(function() return coroutine.yield(1) + 1 end)
          return v
        end)
        co()
        return co(41)'''),
        '42',
      );
    });

    test('the collector releases dropped host functions', () {
      ls.register('kept', (ls) => 0);
      final before = ls.hostFunctionCount;
      ls.gc(LuaGcOp.stop); // No collection before the count.
      for (var i = 0; i < 50; i++) {
        ls.pushDartFunction((ls) => 0);
        ls.pop(1);
      }
      expect(ls.hostFunctionCount, before + 50);
      ls.gc(LuaGcOp.restart);
      ls.gc(LuaGcOp.collect);
      expect(ls.hostFunctionCount, before);
      expect(eval(ls, 'kept() return "ok"'), 'ok');
      expect(ls.gc(LuaGcOp.count), greaterThan(0));
    });

    test('finalizers that call host functions run during collection', () {
      final seen = <String>[];
      ls.register('note', (ls) {
        seen.add(ls.checkString(1));
        return 0;
      });
      eval(
        ls,
        'setmetatable({}, {__gc = function() note("gc") end}) '
        'collectgarbage()',
      );
      expect(seen, ['gc']);
    });

    test('close() inside a host function is refused', () {
      ls.register('close_me', (inner) {
        ls.close();
        return 0;
      });
      expect(
        eval(ls, 'local ok, e = pcall(close_me) return e'),
        contains('close() inside a host function'),
      );
      expect(ls.isClosed, isFalse);
    });
  });

  group('sandbox', () {
    test('dangerous functions are absent', () {
      expect(
        eval(ls, '''
        return tostring(io) .. tostring(package) .. tostring(debug)
          .. tostring(require) .. tostring(dofile) .. tostring(loadfile)
          .. tostring(os.execute) .. tostring(os.exit) .. tostring(os.getenv)
          .. tostring(os.remove) .. tostring(os.rename)
          .. tostring(os.setlocale) .. tostring(os.tmpname)'''),
        'nil' * 13,
      );
      expect(
        eval(ls, 'return type(os.time()) .. type(os.clock())'),
        'numbernumber',
      );
      expect(eval(ls, 'return load("return 1 + 1")()'), '2');
      expect(eval(ls, 'return load("return x", "n", "b", {x = 5})()'), '5');
    });

    test('a sandbox cannot open package, io or debug', () {
      final other = LuaState.newState();
      addTearDown(other.close);
      expect(
        () => other.openLibs(libs: {LuaLib.base, LuaLib.io}, sandbox: true),
        throwsArgumentError,
      );
      other.openLibs();
      expect(eval(other, 'return type(io.open)'), 'function');
    });
  });

  group('limits', () {
    test('interrupt stops Lua until clearInterrupt; pcall cannot catch it', () {
      ls.interrupt();
      ls.loadString('while true do end');
      expect(ls.pCall(0, 0, 0), ThreadStatus.luaErrInterrupt);
      expect(ls.toStr(-1), 'interrupted');
      ls.setTop(0);
      expect(() => eval(ls, 'local x = 1'), throwsA(isA<LuaError>()));
      ls.clearInterrupt();
      expect(
        eval(ls, 'local x = 0 for i = 1, 100000 do x = x + i end return x'),
        '5000050000',
      );
    });

    test('the memory limit fails allocations and the state recovers', () {
      final limited = sandboxed(memoryLimit: 4 << 20);
      addTearDown(limited.close);
      expect(limited.memoryUsed, greaterThan(0));
      expect(
        () => eval(limited, 'local t = {} for i = 1, 1e8 do t[i] = {} end'),
        throwsA(
          isA<LuaError>().having(
            (e) => e.message,
            'message',
            'not enough memory',
          ),
        ),
      );
      expect(
        () => eval(limited, 'return string.rep("x", 8 << 20)'),
        throwsA(isA<LuaError>()),
      );
      // A push over the limit throws in Dart too.
      expect(
        () => limited.pushString('y' * (8 << 20)),
        throwsA(
          isA<LuaError>().having(
            (e) => e.status,
            'status',
            ThreadStatus.luaErrMem,
          ),
        ),
      );
      limited.gc(LuaGcOp.collect);
      expect(eval(limited, 'return #string.rep("x", 1000)'), '1000');
      expect(limited.memoryUsed, lessThan(4 << 20));
    });

    test('a state needs some memory', () {
      expect(
        () => LuaState.newState(memoryLimit: 64),
        throwsA(isA<LuaError>()),
      );
    });
  });

  group('threads', () {
    test('resume, yield, and values on a suspended thread', () {
      eval(
        ls,
        'function gen(a) local b = coroutine.yield(a + 1) '
        'return b * 2 end',
      );
      final co = ls.newThread();
      expect(co.isMainThread, isFalse);
      co.getGlobal('gen');
      co.pushInteger(10);
      var (status, n) = co.resume(1);
      expect((status, n), (ThreadStatus.luaYield, 1));
      expect(co.toInteger(-1), 11);
      co.pop(1);
      expect(co.status, ThreadStatus.luaYield);
      // A protected push onto a suspended thread.
      co.pushString('21');
      (status, n) = co.resume(1);
      expect((status, n), (ThreadStatus.luaOk, 1));
      expect(co.toInteger(-1), 42);
      co.pop(1);
      expect(() => co.resume(0), throwsA(isA<LuaError>()));
      expect(ls.toThread(-1)!.address, co.address);
      ls.pop(1);
    });

    test('errors in a thread', () {
      final co = ls.newThread();
      co.loadString('error("in thread", 0)');
      final (status, _) = co.resume(0);
      expect(status, ThreadStatus.luaErrRun);
      expect(co.toStr(-1), 'in thread');
      expect(co.closeThread(), ThreadStatus.luaErrRun);
      ls.pop(1);
    });

    test('xmove between threads', () {
      final co = ls.newThread();
      ls.pushString('moved');
      ls.xmove(co, 1);
      expect(co.toStr(-1), 'moved');
      ls.pop(1);
    });
  });

  test('a closed state refuses calls', () {
    final other = LuaState.newState();
    other.close();
    other.close();
    expect(other.isClosed, isTrue);
    expect(() => other.getTop(), throwsStateError);
  });

  test('many states can be created and dropped', () {
    for (var i = 0; i < 200; i++) {
      final s = sandboxed();
      s.register('f', (ls) => 0);
      eval(s, 'f()');
      if (i.isEven) s.close();
    }
  });
}
