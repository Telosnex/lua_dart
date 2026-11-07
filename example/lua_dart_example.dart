import 'package:lua_dart/lua_dart.dart';

/// Runs Lua code in a sandboxed state with a memory limit, and calls a Dart
/// function from it.
Future<void> main() async {
  // Once per isolate, before the first state.
  await LuaState.loadRuntime();
  final ls = LuaState.newState(memoryLimit: 64 << 20);
  ls.openLibs(sandbox: true);
  ls.register('greet', (ls) {
    ls.pushString('hello, ${ls.checkString(1)}');
    return 1;
  });
  if (!ls.doString('return greet("lua")')) throw LuaError(ls.toStr(-1)!);
  print(ls.toStr(-1)); // hello, lua
  ls.close();
}
