import 'dart:isolate';

import 'package:lua_dart/lua_dart.dart';
import 'package:test/test.dart';

void main() {
  test('a state needs loadRuntime first, on every platform', () async {
    // A new isolate: loadRuntime is per isolate.
    final error = await Isolate.run(() {
      try {
        LuaState.newState().close();
        return null;
      } on StateError catch (e) {
        return e.message;
      }
    });
    expect(error, contains('loadRuntime'));

    final after = await Isolate.run(() async {
      await LuaState.loadRuntime();
      final ls = LuaState.newState();
      final ok = LuaState.isRuntimeLoaded && ls.doString('return 1');
      ls.close();
      return ok;
    });
    expect(after, isTrue);
  }, testOn: 'vm');

  test('runtimeModuleUri is null on native', () async {
    await LuaState.loadRuntime();
    expect(LuaState.runtimeModuleUri, isNull);
  }, testOn: 'vm');
}
