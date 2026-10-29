@TestOn('vm')
library;

import 'dart:isolate';

import 'package:lua_dart/lua_dart.dart';
import 'package:test/test.dart';

import 'lua_state_test.dart' show eval, sandboxed;

/// Interrupts while the spawning isolate runs Lua on its own thread.
Future<void> _interruptLater(
  (SharedLuaInterruptHandle, SendPort) message,
) async {
  final (shared, port) = message;
  final handle = LuaInterruptHandle.receive(shared);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  handle.trigger();
  port.send(true);
}

void main() {
  setUpAll(LuaState.loadRuntime);
  late LuaState ls;
  setUp(() => ls = sandboxed());
  tearDown(() => ls.close());

  for (final (name, code) in [
    ('a plain loop', 'while true do end'),
    (
      'a loop in pcall',
      'while true do pcall(function() while true do end end) end',
    ),
    (
      'a loop in an xpcall handler',
      'xpcall(error, function() while true do end end)',
    ),
    ('a coroutine', 'coroutine.wrap(function() while true do end end)()'),
    (
      'nested coroutines',
      '''
      coroutine.wrap(function()
        coroutine.resume(coroutine.create(function() while true do end end))
      end)()''',
    ),
    (
      'coroutines that yield',
      '''
      local co = coroutine.wrap(function()
        while true do coroutine.yield() end
      end)
      while true do co() end''',
    ),
    ('a host function that calls back into Lua', 'spin()'),
  ]) {
    test('interrupt from another isolate stops $name', () async {
      ls.register('spin', (ls) {
        ls.loadString('while true do end');
        ls.call(0, 0);
        return 0;
      });
      final ready = ReceivePort();
      final handle = LuaInterruptHandle();
      ls.attachInterruptHandle(handle);
      await Isolate.spawn(_interruptLater, (handle.share(), ready.sendPort));
      final stopwatch = Stopwatch()..start();
      ls.loadString(code);
      expect(ls.pCall(0, 0, 0), ThreadStatus.luaErrInterrupt);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
      expect(await ready.first, isTrue);
      ls.setTop(0);
      ls.detachInterruptHandle();
      ls.clearInterrupt();
      expect(eval(ls, 'return coroutine.wrap(function() return 7 end)()'), '7');
    });
  }

  test('a handle triggered after its state closed is safe', () async {
    final handle = LuaInterruptHandle();
    final other = sandboxed()..attachInterruptHandle(handle);
    other.close();
    final ready = ReceivePort();
    await Isolate.spawn(_interruptLater, (handle.share(), ready.sendPort));
    expect(await ready.first, isTrue);
    expect(handle.triggered, isTrue);
  });

  test('a handle crosses a channel of plain values as an int', () async {
    final handle = LuaInterruptHandle();
    final ready = ReceivePort();
    await Isolate.spawn(_triggerAddress, (
      handle.share().address,
      ready.sendPort,
    ));
    expect(await ready.first, isTrue);
    expect(handle.triggered, isTrue);
  });
}

void _triggerAddress((int, SendPort) message) {
  final (address, port) = message;
  LuaInterruptHandle.receive(
    SharedLuaInterruptHandle.fromAddress(address),
  ).trigger();
  port.send(true);
}
