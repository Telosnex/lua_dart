/// The reference Lua 5.4 (PUC-Rio) behind the stable C ABI of
/// src/lua_dart.h.
///
/// ```dart
/// final ls = LuaState.newState(memoryLimit: 64 << 20);
/// ls.openLibs(sandbox: true);
/// ls.register('greet', (ls) {
///   ls.pushString('hello, ${ls.checkString(1)}');
///   return 1;
/// });
/// if (!ls.doString('return greet("lua")')) throw LuaError(ls.toStr(-1)!);
/// print(ls.toStr(-1)); // hello, lua
/// ls.close();
/// ```
library;

export 'src/lua_state.dart' show LuaInterrupter, LuaRaise, LuaState;
export 'src/types.dart';
