## 1.0.0

- First stable release. Requires kiln 1.0.0, whose source key leaves out the pubspec's `version` and `description`, so a release that changes only those needs no new native build.

## 0.2.3

- Shorter package description, and a usage example for pub.dev. The README example now calls `LuaState.loadRuntime()`, which every isolate needs before its first state.

## 0.2.2

- Requires `code_assets` 2.2, `hooks` 2.2 and `kiln` 0.2. With `code_assets` 1.x, the package could not be installed with current `objective_c` and `shared_preferences_foundation`.
- The build uses the complete iOS and macOS deployment version, such as 12.3, not only the major version.

## 0.2.1

- The package no longer includes the Lua source tarballs from `third_party/`
  (about 770 KB). The build hook never used them. No code changes.

## 0.2.0

- Lua 5.5.1, up from 5.4.9. 5.4 gets no more releases. Lua code: `global`
  declarations, read-only `for` loop variables, named varargs, and floats
  that print with enough digits to read back. `global` is a keyword only at
  the start of a declaration (LUA_COMPAT_GLOBAL), so `global` as a name
  still works. `math.pow`, `math.log10` and the others of LUA_COMPAT_MATHLIB
  stay. `__le` no longer falls back to `__lt`.
- ABI 3: `luaRegistryIndex` is the new LUA_REGISTRYINDEX of Lua 5.5, and
  lua_dart.h has its own LUADART_GC* values. `LuaGcOp.step` takes the size_t
  of LUA_GCSTEP.
- `math.random` gets a random seed in every state again; string hashes keep
  their fixed seed.

## 0.1.0

- First release on pub.dev: Lua 5.4.9 behind a stable C ABI, native
  (FFI) and web (WebAssembly).
