# lua_dart

The reference Lua 5.4 (PUC-Rio, 5.4.9) for Dart and Flutter, behind a stable
C ABI, with an API in the style of the Lua C API. Native platforms use
`dart:ffi`; the web uses the same C compiled to WebAssembly.

```dart
import 'package:lua_dart/lua_dart.dart';

void main() {
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
```

- **Memory limit:** `LuaState.newState(memoryLimit: bytes)`; an allocation
  over it fails with a Lua memory error.
- **Interrupts:** `interrupt()` on the state, or a `LuaInterruptHandle` that
  any isolate can trigger, to stop runaway Lua code.
- **Sandbox:** `openLibs(sandbox: true)` opens only the safe libraries,
  removes `dofile`, `loadfile` and the `os` functions that reach the host
  (`execute`, `exit`, `getenv`, `remove`, `rename`, `setlocale`, `tmpname`),
  and `load` accepts text chunks only. Without it, Lua code can read and
  write files and run programs.
- **A Lua error never unwinds through Dart frames:** every call that can
  raise runs protected in C.

The native libraries are prebuilt for Android, iOS, macOS, Linux and
Windows ([Kiln](https://pub.dev/packages/kiln)): the build hook downloads
the one for your target and checks its SHA-256. It builds from source when
the sources differ from the release.

## License

MIT. Lua itself is MIT (Lua.org, PUC-Rio); both are in LICENSE.
