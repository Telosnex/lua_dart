import 'lua_state.dart';

/// The pseudo-index of the registry (LUA_REGISTRYINDEX of Lua 5.4).
const luaRegistryIndex = -1001000;

/// lua_pcall and lua_call: all results.
const luaMultret = -1;

/// The registry index of the global table (LUA_RIDX_GLOBALS).
const luaRidxGlobals = 2;

/// luaL_ref result for nil (LUA_REFNIL).
const luaRefNil = -1;

/// Largest and smallest Lua integers. Compiled to JavaScript (dart2js),
/// Dart ints are doubles: integers beyond 2^53 lose precision there, and
/// these two are not exact. Native and dart2wasm have all 64 bits.
const luaMaxInteger = (1 << 63) - 1;
const luaMinInteger = -1 << 63;

/// Value types. The names are those of package:lua_dardo_plus.
enum LuaType {
  luaNil,
  luaBoolean,
  luaLightUserdata,
  luaNumber,
  luaString,
  luaTable,
  luaFunction,
  luaUserdata,
  luaThread,
  luaNone;

  /// The type of a LUA_T* value; -1 (LUA_TNONE) is [luaNone].
  static LuaType fromCode(int code) =>
      code >= 0 && code < luaNone.index ? values[code] : luaNone;

  /// The name that `type()` gives in Lua; `no value` for [luaNone].
  String get luaName => switch (this) {
    luaNil => 'nil',
    luaBoolean => 'boolean',
    luaLightUserdata || luaUserdata => 'userdata',
    luaNumber => 'number',
    luaString => 'string',
    luaTable => 'table',
    luaFunction => 'function',
    luaThread => 'thread',
    luaNone => 'no value',
  };
}

/// The status of a load, call or thread.
enum ThreadStatus {
  luaOk(0),
  luaYield(1),
  luaErrRun(2),
  luaErrSyntax(3),
  luaErrMem(4),
  luaErrErr(5),

  /// A stack index is not valid, or an argument is out of range. No error
  /// object is pushed.
  luaErrArg(100),

  /// The stack cannot grow. No error object is pushed.
  luaErrStack(101),

  /// [LuaState.interrupt] or [LuaInterruptHandle.trigger] was called.
  luaErrInterrupt(103);

  const ThreadStatus(this.code);

  /// The LUADART_* status value.
  final int code;

  static ThreadStatus fromCode(int code) => switch (code) {
    0 => luaOk,
    1 => luaYield,
    2 => luaErrRun,
    3 => luaErrSyntax,
    4 => luaErrMem,
    5 => luaErrErr,
    100 => luaErrArg,
    101 => luaErrStack,
    103 => luaErrInterrupt,
    _ => throw StateError('lua_dart: unknown status $code'),
  };

  bool get isError => this != luaOk && this != luaYield;

  /// True if no error object was pushed.
  bool get hasNoErrorObject => this == luaErrArg || this == luaErrStack;
}

/// Arithmetic operations of [LuaState.arith], in the order of lua.h.
enum ArithOp {
  luaOpAdd,
  luaOpSub,
  luaOpMul,
  luaOpMod,
  luaOpPow,
  luaOpDiv,
  luaOpIdiv,
  luaOpBand,
  luaOpBor,
  luaOpBxor,
  luaOpShl,
  luaOpShr,
  luaOpUnm,
  luaOpBnot,
}

/// Comparisons of [LuaState.compare], in the order of lua.h.
enum CmpOp { luaOpEq, luaOpLt, luaOpLe }

/// The field that marks an empty JSON array: json.decode gives `[]` a
/// metatable with this field set to true, and json.encode writes an empty
/// table with such a metatable as `[]`, not `{}`.
const luaJsonArrayMarker = '__json_array';

/// Standard libraries of [LuaState.openLibs], and [json] of lua_dart.
enum LuaLib {
  base(1 << 0),
  package(1 << 1),
  coroutine(1 << 2),
  table(1 << 3),
  io(1 << 4),
  os(1 << 5),
  string(1 << 6),
  math(1 << 7),
  utf8(1 << 8),
  debug(1 << 9),

  /// `json.decode` and `json.encode` in C, with the values of dart:convert
  /// (src/lua_dart_json.c has the rules).
  json(1 << 10);

  const LuaLib(this.bit);

  final int bit;

  /// The libraries that a sandbox may open: all except package, io and
  /// debug.
  static const Set<LuaLib> safe = {
    base,
    coroutine,
    table,
    os,
    string,
    math,
    utf8,
    json,
  };
}

/// Operations of [LuaState.gc], with the values of lua.h.
enum LuaGcOp {
  stop(0),
  restart(1),
  collect(2),

  /// The memory in use, in KiB.
  count(3),

  /// The remainder of [count], in bytes.
  countBytes(4),
  step(5),
  isRunning(9);

  const LuaGcOp(this.code);

  final int code;
}

/// A host function. It gets its arguments at 1 .. [LuaState.getTop], pushes
/// its results and returns their count. It reports an error by throwing; see
/// [LuaState.error2].
typedef DartFunction = int Function(LuaState ls);

/// A failed Lua operation.
///
/// Thrown by the operations that raise a Lua error in the C API, such as
/// [LuaState.call], [LuaState.getField] with an `__index` metamethod, or a
/// push that runs out of memory. Thrown inside a host function, it becomes a
/// Lua error with [message].
class LuaError implements Exception {
  LuaError(this.message, [this.status = ThreadStatus.luaErrRun]);

  /// The error object as text: a string or number as is, else its
  /// `__tostring`, else a description of its type.
  final String message;

  final ThreadStatus status;

  @override
  String toString() => 'LuaError(${status.name}): $message';
}
