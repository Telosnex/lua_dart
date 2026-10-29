import 'dart:convert';
import 'dart:typed_data';

import 'backend/api_native.dart'
    if (dart.library.js_interop) 'backend/api_web.dart';
import 'backend/constants.g.dart';
import 'types.dart';

/// A Lua state, or one thread of it.
///
/// The methods follow the Lua 5.4 C API and the names of
/// package:lua_dardo_plus. Stack indices are checked: a bad index throws a
/// [LuaError] with [ThreadStatus.luaErrArg] instead of corrupting memory.
///
/// A state and its threads are used on the isolate that created them, one
/// call at a time. Call [close] when done; an unreachable state is closed by
/// a finalizer.
final class LuaState implements Finalizable {
  LuaState._(this._vm, this._l);

  /// Loads the WebAssembly runtime on the web; returns at once on native
  /// platforms. Await it on each isolate (or Worker) before its first
  /// [LuaState.newState], on every platform: a missing call then fails in
  /// native tests too, not only on the web. Idempotent.
  ///
  /// [moduleUri] is the URL of `lua_dart_module.mjs`, by default
  /// `kiln/lua_dart/lua_dart_module.mjs` resolved against the base URI of the
  /// page (its `<base href>`), where the build hook installs it. In a Worker,
  /// pass an absolute [moduleUri], for example the [runtimeModuleUri] of the
  /// page: a Worker has no page to resolve against.
  static Future<void> loadRuntime({Uri? moduleUri}) =>
      loadRuntime_(moduleUri: moduleUri);

  /// True when [loadRuntime] has completed on this isolate or Worker.
  static bool get isRuntimeLoaded => runtimeLoaded;

  /// On the web, the absolute URL of `lua_dart_module.mjs`: the URL it was
  /// loaded from, or before that, the default resolved against the base URI
  /// of the page. A page sends it to its Workers. Null on native platforms,
  /// and in a Worker before [loadRuntime].
  static Uri? get runtimeModuleUri => runtimeModuleUri_;

  /// A new state with no libraries.
  ///
  /// [memoryLimit] is in bytes; 0 means no limit. An allocation over the
  /// limit fails with [ThreadStatus.luaErrMem].
  factory LuaState.newState({int memoryLimit = 0}) =>
      _Vm.create(memoryLimit).main;

  final _Vm _vm;
  final int _l;

  /// The ABI version and the Lua release of the native library, for example
  /// `lua_dart ABI 1; Lua 5.4.9`.
  static String get buildInfo => readCString(luadart_build_info());

  /// True for the main thread of the state.
  bool get isMainThread => _l == _vm.mainPointer;

  bool get isClosed => _vm.closed;

  /// The address of the native lua_State, for identity checks.
  int get address => _l;

  /// Closes the state. Only the main thread can close it, and not from a
  /// host function. Lua code does not run during the close.
  void close() {
    if (_vm.closed) return;
    if (!isMainThread) {
      throw StateError('lua_dart: close() the main thread of the state.');
    }
    if (_vm.callbackDepth > 0) {
      throw StateError('lua_dart: close() inside a host function.');
    }
    _vm.close();
  }

  int get _p {
    if (_vm.closed) throw StateError('lua_dart: the state is closed.');
    return _l;
  }

  // --- Limits ----------------------------------------------------------------

  /// Bytes; 0 means no limit.
  set memoryLimit(int bytes) {
    RangeError.checkNotNegative(bytes, 'bytes');
    luadart_set_memory_limit(_p, bytes);
  }

  /// Bytes in use by the state.
  int get memoryUsed => luadart_memory_used(_p);

  /// Makes the running Lua code fail with [ThreadStatus.luaErrInterrupt] at
  /// its next instruction, and all Lua code after it until
  /// [clearInterrupt], so a `pcall` in the script cannot continue. Lua code
  /// that runs no VM instructions, for example one long `string.rep`, is
  /// not interrupted. From another isolate, use [attachInterruptHandle].
  void interrupt() => luadart_interrupt(_p);

  /// Lets Lua code run again after [interrupt].
  void clearInterrupt() => luadart_clear_interrupt(_p);

  /// Attaches [handle]: [LuaInterruptHandle.trigger] from any isolate then
  /// interrupts this state, as [interrupt]. If the handle was triggered
  /// already, Lua code fails at once. [close] detaches it. Throws
  /// [StateError] if the state or the handle has one attached already.
  void attachInterruptHandle(LuaInterruptHandle handle) {
    final p = _p;
    luadart_interrupt_handle_retain(handle._address);
    if (luadart_attach_interrupt_handle(p, handle._address) != LUADART_OK) {
      throw StateError('lua_dart: an interrupt handle is attached already');
    }
  }

  /// Detaches the handle of [attachInterruptHandle], if any.
  void detachInterruptHandle() => luadart_detach_interrupt_handle(_p);

  /// lua_gc. Returns the result of lua_gc, for example the KiB in use for
  /// [LuaGcOp.count].
  int gc(LuaGcOp what, [int arg = 0]) {
    final out = _vm.i32;
    _check(luadart_gc(_p, what.code, arg, out));
    return readI32(out);
  }

  // --- Libraries ---------------------------------------------------------------

  /// Opens the standard libraries in [libs] as globals.
  ///
  /// With [sandbox], [libs] must be within [LuaLib.safe]; `load` accepts
  /// text chunks only; `dofile` and `loadfile` are removed; and `os.execute`,
  /// `os.exit`, `os.getenv`, `os.remove`, `os.rename`, `os.setlocale` and
  /// `os.tmpname` are removed. Without a sandbox, Lua code can read and write
  /// files and run programs.
  void openLibs({Set<LuaLib>? libs, bool sandbox = false}) {
    final selected = libs ?? (sandbox ? LuaLib.safe : LuaLib.values.toSet());
    var mask = 0;
    for (final lib in selected) {
      mask |= lib.bit;
    }
    final status = luadart_open_libs(
      _p,
      mask,
      sandbox ? LUADART_OPEN_SANDBOX : 0,
    );
    if (status == LUADART_ERRARG) {
      throw ArgumentError.value(
        selected,
        'libs',
        'a sandbox cannot open package, io or debug',
      );
    }
    _check(status);
  }

  // --- Stack -------------------------------------------------------------------

  int getTop() => luadart_gettop(_p);

  /// Throws for an index that is not valid.
  int absIndex(int idx) {
    final abs = luadart_absindex(_p, idx);
    if (abs == 0) _badIndex(idx);
    return abs;
  }

  bool checkStack(int n) => luadart_checkstack(_p, n) != 0;

  void setTop(int idx) => _check(luadart_settop(_p, idx));

  void pop(int n) => setTop(-n - 1);

  void pushValue(int idx) => _check(luadart_pushvalue(_p, idx));

  void rotate(int idx, int n) => _check(luadart_rotate(_p, idx, n));

  void copy(int fromIdx, int toIdx) => _check(luadart_copy(_p, fromIdx, toIdx));

  void insert(int idx) => rotate(idx, 1);

  void remove(int idx) {
    rotate(idx, -1);
    pop(1);
  }

  void replace(int idx) {
    copy(-1, idx);
    pop(1);
  }

  /// Pops [n] values and pushes them on [to], a thread of the same state.
  void xmove(LuaState to, int n) {
    if (!identical(to._vm, _vm)) {
      throw ArgumentError.value(to, 'to', 'a thread of another state');
    }
    _check(luadart_xmove(_p, to._p, n));
  }

  // --- Access ------------------------------------------------------------------

  LuaType type(int idx) => LuaType.fromCode(luadart_type(_p, idx));

  String typeName(LuaType t) => t.luaName;

  /// The type name of the value at [idx] (luaL_typename).
  String typeName2(int idx) => type(idx).luaName;

  bool isNone(int idx) => type(idx) == LuaType.luaNone;
  bool isNil(int idx) => type(idx) == LuaType.luaNil;
  bool isNoneOrNil(int idx) => luadart_type(_p, idx) <= LUADART_TNIL;
  bool isBoolean(int idx) => type(idx) == LuaType.luaBoolean;
  bool isInteger(int idx) => luadart_isinteger(_p, idx) != 0;

  /// True for a number or a string convertible to a number.
  bool isNumber(int idx) => luadart_isnumber(_p, idx) != 0;

  /// True for a string or a number.
  bool isString(int idx) => luadart_isstring(_p, idx) != 0;
  bool isTable(int idx) => type(idx) == LuaType.luaTable;
  bool isThread(int idx) => type(idx) == LuaType.luaThread;
  bool isFunction(int idx) => type(idx) == LuaType.luaFunction;

  /// True for a function of [pushDartFunction].
  bool isDartFunction(int idx) => luadart_is_host_function(_p, idx) != 0;
  bool isUserdata(int idx) {
    final t = type(idx);
    return t == LuaType.luaUserdata || t == LuaType.luaLightUserdata;
  }

  bool toBoolean(int idx) => luadart_toboolean(_p, idx) != 0;

  /// The integer, or 0 (lua_tointeger).
  int toInteger(int idx) => luadart_tointegerx(_p, idx, 0);

  /// The integer, or null if the value is not convertible to an integer.
  int? toIntegerX(int idx) {
    final ok = _vm.i32;
    final n = luadart_tointegerx(_p, idx, ok);
    return readI32(ok) != 0 ? n : null;
  }

  /// The number, or 0 (lua_tonumber).
  double toNumber(int idx) => luadart_tonumberx(_p, idx, 0);

  /// The number, or null if the value is not convertible to a number.
  double? toNumberX(int idx) {
    final ok = _vm.i32;
    final n = luadart_tonumberx(_p, idx, ok);
    return readI32(ok) != 0 ? n : null;
  }

  /// A string, or a number in the format of `tostring`; else null. Invalid
  /// UTF-8 becomes U+FFFD. The value on the stack does not change.
  String? toStr(int idx) {
    final len = _vm.u64;
    final bytes = luadart_tolstring(_p, idx, len);
    if (bytes == 0) return null;
    return decodeUtf8(bytes, readU64(len));
  }

  /// The bytes of a string or of a number, as [toStr]; else null.
  Uint8List? toBytes(int idx) {
    final len = _vm.u64;
    final bytes = luadart_tolstring(_p, idx, len);
    if (bytes == 0) return null;
    return copyBytes(bytes, readU64(len));
  }

  int rawLen(int idx) => luadart_rawlen(_p, idx);

  bool rawEqual(int idx1, int idx2) => luadart_rawequal(_p, idx1, idx2) != 0;

  /// The thread at [idx], or null. It is valid while Lua refers to it, for
  /// example from the stack or the registry.
  LuaState? toThread(int idx) {
    final thread = luadart_tothread(_p, idx);
    if (thread == 0) return null;
    return _vm.viewOf(thread);
  }

  /// The status of this thread.
  ThreadStatus get status => ThreadStatus.fromCode(luadart_status(_p));

  // --- Push --------------------------------------------------------------------

  void pushNil() => _check(luadart_pushnil(_p));

  void pushBoolean(bool b) => _check(luadart_pushboolean(_p, b ? 1 : 0));

  void pushInteger(int n) => _check(luadart_pushinteger(_p, n));

  void pushNumber(double n) => _check(luadart_pushnumber(_p, n));

  /// Pushes [s] as UTF-8, or nil for null.
  void pushString(String? s) {
    if (s == null) return pushNil();
    final p = _p;
    final (bytes, len) = _vm.encode(s);
    _check(luadart_pushlstring(p, bytes, len));
  }

  void pushBytes(Uint8List bytes) {
    final p = _p;
    final buffer = _vm.scratch(bytes.length + 1);
    writeBytes(buffer, bytes);
    _check(luadart_pushlstring(p, buffer, bytes.length));
  }

  void pushGlobalTable() => _check(luadart_pushglobaltable(_p));

  /// Pushes a Lua function that calls [f]. The garbage collector frees [f]
  /// when Lua drops the last reference to the function.
  void pushDartFunction(DartFunction f) {
    final p = _p;
    final id = _vm.addFunction(f);
    final status = luadart_push_host_function(p, id);
    if (status != LUADART_OK) {
      _vm.functions.remove(id);
      _check(status);
    }
  }

  /// The host functions that Lua can still call. The garbage collector
  /// releases the others.
  int get hostFunctionCount => _vm.functions.length;

  /// Sets global [name] to [f].
  void register(String name, DartFunction f) {
    pushDartFunction(f);
    setGlobal(name);
  }

  /// Pushes a new thread and returns it.
  LuaState newThread() {
    final out = _vm.thread;
    _check(luadart_newthread(_p, out));
    return _vm.viewOf(readPointer(out));
  }

  // --- Tables ------------------------------------------------------------------

  void newTable() => createTable(0, 0);

  void createTable(int nArr, int nRec) =>
      _check(luadart_createtable(_p, nArr, nRec));

  /// Pushes t[k], where t is at [idx] and k is on the top; pops k.
  LuaType getTable(int idx) {
    final type = _vm.i32;
    _check(luadart_gettable(_p, idx, type));
    return LuaType.fromCode(readI32(type));
  }

  LuaType getField(int idx, String k) {
    final p = _p;
    final (bytes, len) = _vm.encode(k);
    final type = _vm.i32;
    _check(luadart_getfield(p, idx, bytes, len, type));
    return LuaType.fromCode(readI32(type));
  }

  LuaType getI(int idx, int i) {
    final type = _vm.i32;
    _check(luadart_geti(_p, idx, i, type));
    return LuaType.fromCode(readI32(type));
  }

  LuaType getGlobal(String name) {
    final p = _p;
    final (bytes, len) = _vm.encode(name);
    final type = _vm.i32;
    _check(luadart_getglobal(p, bytes, len, type));
    return LuaType.fromCode(readI32(type));
  }

  /// Pushes t[k] without metamethods; pops k. t must be a table.
  LuaType rawGet(int idx) {
    final type = _vm.i32;
    _check(luadart_rawget(_p, idx, type));
    return LuaType.fromCode(readI32(type));
  }

  LuaType rawGetI(int idx, int i) {
    final type = _vm.i32;
    _check(luadart_rawgeti(_p, idx, i, type));
    return LuaType.fromCode(readI32(type));
  }

  /// Pushes the metatable of the value and returns true, or returns false.
  bool getMetatable(int idx) => luadart_getmetatable(_p, idx) != 0;

  /// t[k] = v, where t is at [idx] and k and v are on the top; pops both.
  void setTable(int idx) => _check(luadart_settable(_p, idx));

  /// t[k] = v, where v is on the top; pops it.
  void setField(int idx, String k) {
    final p = _p;
    final (bytes, len) = _vm.encode(k);
    _check(luadart_setfield(p, idx, bytes, len));
  }

  void setI(int idx, int i) => _check(luadart_seti(_p, idx, i));

  void setGlobal(String name) {
    final p = _p;
    final (bytes, len) = _vm.encode(name);
    _check(luadart_setglobal(p, bytes, len));
  }

  void rawSet(int idx) => _check(luadart_rawset(_p, idx));

  void rawSetI(int idx, int i) => _check(luadart_rawseti(_p, idx, i));

  /// Pops a table or nil and sets it as the metatable of the value at [idx].
  void setMetatable(int idx) => _check(luadart_setmetatable(_p, idx));

  /// lua_next: pops a key and pushes the next key and value, or returns
  /// false at the end. Do not change the table during the traversal.
  bool next(int idx) {
    final hasNext = _vm.i32;
    _check(luadart_next(_p, idx, hasNext));
    return readI32(hasNext) != 0;
  }

  // --- Operations --------------------------------------------------------------

  /// Pushes #v, with metamethods.
  void len(int idx) => _check(luadart_len(_p, idx));

  /// The length of the value as an integer (luaL_len).
  int len2(int idx) {
    len(idx);
    final n = toIntegerX(-1);
    pop(1);
    if (n == null) throw LuaError('object length is not an integer');
    return n;
  }

  bool compare(int idx1, int idx2, CmpOp op) {
    final result = _vm.i32;
    _check(luadart_compare(_p, idx1, idx2, op.index, result));
    return readI32(result) != 0;
  }

  /// Pops two operands (one for [ArithOp.luaOpUnm] and [ArithOp.luaOpBnot])
  /// and pushes the result.
  void arith(ArithOp op) => _check(luadart_arith(_p, op.index));

  void concat(int n) => _check(luadart_concat(_p, n));

  /// Pushes `tostring` of the value (luaL_tolstring), with `__tostring` and
  /// `__name`, and returns it.
  String toString2(int idx) {
    _check(luadart_tostring_meta(_p, idx));
    return toStr(-1) ?? '';
  }

  /// Pushes the number of [s] and returns true, or returns false.
  bool stringToNumber(String s) {
    final p = _p;
    final (bytes, len) = _vm.encode(s);
    return luadart_stringtonumber(p, bytes, len) != 0;
  }

  /// luaL_ref: pops a value and returns a reference in the table at [t].
  int ref(int t) {
    final out = _vm.i32;
    _check(luadart_ref(_p, t, out));
    return readI32(out);
  }

  void unRef(int t, int ref) => _check(luadart_unref(_p, t, ref));

  // --- Load and call -----------------------------------------------------------

  /// Loads a text chunk and pushes it as a function, or pushes the error
  /// message and returns an error status. Binary chunks are refused.
  ThreadStatus load(Uint8List chunk, String chunkName) {
    final p = _p;
    // Not the scratch buffer: the parser reads the chunk while the
    // collector can run finalizers that call host functions.
    final buffer = memAlloc(chunk.length + 3 * chunkName.length + 2);
    try {
      writeBytes(buffer, chunk);
      final name = buffer + chunk.length;
      encodeUtf8(chunkName, name);
      return ThreadStatus.fromCode(luadart_load(p, buffer, chunk.length, name));
    } finally {
      memFree(buffer);
    }
  }

  /// [load] of [s]. The chunk name is [chunkName], else [s] itself, as with
  /// luaL_loadstring.
  ThreadStatus loadString(String s, {String? chunkName}) =>
      load(utf8.encode(s), chunkName ?? s);

  /// Loads and runs [s] (luaL_dostring). Returns true on success and leaves
  /// the results on the stack; else returns false and leaves the error
  /// object.
  bool doString(String s, {String? chunkName}) {
    if (loadString(s, chunkName: chunkName) != ThreadStatus.luaOk) {
      return false;
    }
    return pCall(0, luaMultret, 0) == ThreadStatus.luaOk;
  }

  /// lua_pcall: calls the function below the top [nArgs] values. Leaves the
  /// results, or leaves the error object and returns an error status.
  /// [msgh] is 0 or the stack index of a message handler. With [traceback],
  /// the error object is a message with a stack traceback.
  ThreadStatus pCall(
    int nArgs,
    int nResults,
    int msgh, {
    bool traceback = false,
  }) {
    final status = luadart_pcall(
      _p,
      nArgs,
      nResults,
      msgh,
      traceback ? LUADART_PCALL_TRACEBACK : 0,
    );
    final result = ThreadStatus.fromCode(status);
    if (result == ThreadStatus.luaErrArg ||
        result == ThreadStatus.luaErrStack) {
      _check(status);
    }
    return result;
  }

  /// Calls the function below the top [nArgs] values and leaves
  /// [nResults] results. On a Lua error, pops the error object and throws
  /// it as a [LuaError].
  void call(int nArgs, int nResults) {
    _check(luadart_pcall(_p, nArgs, nResults, 0, 0));
  }

  /// lua_resume of this thread from [from] (the running thread; the main
  /// thread by default). Returns the status and the count of yielded or
  /// returned values. On an error, the error object is on the top of this
  /// thread. Throws for a thread that cannot be resumed.
  (ThreadStatus, int) resume(int nArgs, {LuaState? from}) {
    if (from != null && !identical(from._vm, _vm)) {
      throw ArgumentError.value(from, 'from', 'a thread of another state');
    }
    final nResults = _vm.i32;
    final status = luadart_resume(
      _p,
      from == null ? 0 : from._p,
      nArgs,
      nResults,
    );
    final result = ThreadStatus.fromCode(status);
    if (result.hasNoErrorObject) _check(status);
    return (result, readI32(nResults));
  }

  /// lua_closethread: closes the pending to-be-closed variables of this
  /// thread and resets it. On an error, the error object is on the top.
  ThreadStatus closeThread({LuaState? from}) {
    final status = luadart_closethread(_p, from == null ? 0 : from._p);
    final result = ThreadStatus.fromCode(status);
    if (result.hasNoErrorObject) _check(status);
    return result;
  }

  // --- Errors in host functions ------------------------------------------------

  /// Raises the value on the top as a Lua error (lua_error). In a host
  /// function, Lua gets the value itself. Elsewhere, it is popped and thrown
  /// as a [LuaError].
  Never error() {
    if (_vm.callbackDepth > 0) throw LuaRaise._();
    final message = _errorMessage();
    pop(1);
    throw LuaError(message);
  }

  /// Raises [message] as a Lua error, with the position of the calling Lua
  /// code in front, as luaL_error does.
  Never error2(String message) {
    if (_vm.callbackDepth == 0) throw LuaError(message);
    _check(luadart_where(_p, 1));
    pushString(message);
    concat(2);
    throw LuaRaise._();
  }

  /// Raises luaL_argerror for argument [arg] of the running host function.
  Never argError(int arg, String extraMsg) {
    if (_vm.callbackDepth == 0) {
      throw LuaError('bad argument #$arg ($extraMsg)');
    }
    final p = _p;
    final (bytes, len) = _vm.encode(extraMsg);
    _check(luadart_argerror(p, arg, bytes, len));
    throw LuaRaise._();
  }

  Never _typeError(int arg, String expected) {
    final actual = type(arg) == LuaType.luaNone ? 'no value' : typeName2(arg);
    argError(arg, '$expected expected, got $actual');
  }

  void checkAny(int arg) {
    if (type(arg) == LuaType.luaNone) argError(arg, 'value expected');
  }

  void checkType(int arg, LuaType t) {
    if (type(arg) != t) _typeError(arg, t.luaName);
  }

  void argCheck(bool cond, int arg, String extraMsg) {
    if (!cond) argError(arg, extraMsg);
  }

  int checkInteger(int arg) {
    final n = toIntegerX(arg);
    if (n != null) return n;
    if (isNumber(arg)) argError(arg, 'number has no integer representation');
    _typeError(arg, 'number');
  }

  double checkNumber(int arg) {
    final n = toNumberX(arg);
    if (n == null) _typeError(arg, 'number');
    return n;
  }

  String checkString(int arg) {
    final s = toStr(arg);
    if (s == null) _typeError(arg, 'string');
    return s;
  }

  int optInteger(int arg, int d) => isNoneOrNil(arg) ? d : checkInteger(arg);

  double optNumber(int arg, double d) =>
      isNoneOrNil(arg) ? d : checkNumber(arg);

  String optString(int arg, String d) =>
      isNoneOrNil(arg) ? d : checkString(arg);

  // --- Internals ----------------------------------------------------------------

  void _check(int status) {
    if (status == LUADART_OK) return;
    if (status == LUADART_ERRARG) {
      throw LuaError('invalid stack index or argument', ThreadStatus.luaErrArg);
    }
    if (status == LUADART_ERRSTACK) {
      throw LuaError('stack overflow', ThreadStatus.luaErrStack);
    }
    final message = _errorMessage();
    pop(1);
    throw LuaError(message, ThreadStatus.fromCode(status));
  }

  Never _badIndex(int idx) =>
      throw LuaError('invalid stack index $idx', ThreadStatus.luaErrArg);

  /// The error object on the top as text. Never throws.
  String _errorMessage() {
    final s = toStr(-1);
    if (s != null) return s;
    final t = type(-1);
    // luaL_tolstring: `__tostring`, else for example "table: 0x...".
    final status = luadart_tostring_meta(_l, -1);
    if (status == LUADART_OK) {
      final text = toStr(-1);
      luadart_settop(_l, -2);
      if (text != null) return text;
    } else if (status != LUADART_ERRARG && status != LUADART_ERRSTACK) {
      luadart_settop(_l, -2); // The error of __tostring.
    }
    return '(error object is a ${t.luaName} value)';
  }

  @override
  String toString() =>
      'LuaState(0x${_l.toRadixString(16)}'
      '${isMainThread ? '' : ', thread'}${_vm.closed ? ', closed' : ''})';
}

/// An interrupt that any isolate can trigger at any time, also while the
/// state that uses it closes, or after (luadart_interrupt_handle).
///
/// Each isolate holds its own reference, which its finalizer releases. To
/// give a handle to another isolate, send [share] and call
/// [LuaInterruptHandle.receive] there once.
final class LuaInterruptHandle implements Finalizable {
  factory LuaInterruptHandle() {
    final address = luadart_interrupt_handle_new();
    if (address == 0) throw OutOfMemoryError();
    return LuaInterruptHandle._(address);
  }

  /// Takes over the reference of [shared]. Call it once for each [share].
  factory LuaInterruptHandle.receive(SharedLuaInterruptHandle shared) =>
      LuaInterruptHandle._(shared._address);

  LuaInterruptHandle._(this._address) {
    attachRelease(this, _address);
  }

  final int _address;

  /// A new reference that can be sent to another isolate. If it is never
  /// received, its 32 bytes are not freed.
  SharedLuaInterruptHandle share() {
    luadart_interrupt_handle_retain(_address);
    return SharedLuaInterruptHandle._(_address);
  }

  /// Interrupts the attached state, and any state that attaches the handle
  /// later. Lua code fails with [ThreadStatus.luaErrInterrupt].
  void trigger() => luadart_interrupt_handle_trigger(_address);

  /// Whether [trigger] was called.
  bool get triggered => luadart_interrupt_handle_triggered(_address) != 0;
}

/// A reference to a [LuaInterruptHandle] in an isolate message.
final class SharedLuaInterruptHandle {
  const SharedLuaInterruptHandle._(this._address);

  /// The reference of [address], for channels that carry only plain values
  /// such as JSON. [address] must come from [SharedLuaInterruptHandle.address]
  /// in the same process; pass it to [LuaInterruptHandle.receive] once.
  const SharedLuaInterruptHandle.fromAddress(int address) : _address = address;

  final int _address;

  /// The reference as an int, for [SharedLuaInterruptHandle.fromAddress].
  int get address => _address;
}

/// Thrown by [LuaState.error] and its relatives in a host function: the
/// error object is on the top of the stack, and Lua gets it as is.
final class LuaRaise implements Exception {
  LuaRaise._();

  @override
  String toString() => 'LuaRaise: a Lua error escaped its host function';
}

/// The owner of a buffer for a finalizer.
final class _Token implements Finalizable {}

/// The native state and the Dart objects of its host functions.
final class _Vm implements Finalizable {
  _Vm._(this.token, this.mainPointer) {
    main = LuaState._(this, mainPointer);
    _buffers = memAlloc(_slotBytes);
    _scratch = memAlloc(_scratchCapacity);
    attachClose(this, mainPointer);
    attachFree(this, _buffers);
    _scratchOwner = _Token();
    attachFree(_scratchOwner, _scratch);
  }

  static int _nextToken = 1;
  static final _byToken = <int, WeakReference<_Vm>>{};
  static final _tokenFinalizer = Finalizer<int>(_byToken.remove);

  static int? _host;

  static bool _abiChecked = false;

  static _Vm create(int memoryLimit) {
    RangeError.checkNotNegative(memoryLimit, 'memoryLimit');
    if (!runtimeLoaded) {
      throw StateError(
        'lua_dart: await LuaState.loadRuntime() on this isolate before its '
        'first state (required on every platform).',
      );
    }
    if (!_abiChecked) {
      final abi = luadart_abi_version();
      if (abi != LUADART_ABI_VERSION) {
        throw StateError(
          'lua_dart: the native library has ABI $abi, the Dart code '
          'needs $LUADART_ABI_VERSION.',
        );
      }
      if (luadart_registry_index() != luaRegistryIndex) {
        throw StateError('lua_dart: unexpected LUA_REGISTRYINDEX.');
      }
      _abiChecked = true;
    }
    final token = _nextToken++;
    final host = _host ??= hostFunction(_dispatch);
    final pointer = luadart_new_state(memoryLimit, host, token);
    if (pointer == 0) {
      throw LuaError('not enough memory', ThreadStatus.luaErrMem);
    }
    final vm = _Vm._(token, pointer);
    _byToken[token] = WeakReference(vm);
    _tokenFinalizer.attach(vm, token, detach: vm);
    return vm;
  }

  final int token;
  final int mainPointer;
  late final LuaState main;
  final functions = <int, DartFunction>{};
  int _nextFunction = 1;
  int callbackDepth = 0;
  bool closed = false;
  LuaState? _lastView;

  // Out-parameters of the native calls: an int32, a uint64 and a pointer.
  static const _slotBytes = 24;
  late final int _buffers;
  int get i32 => _buffers;
  int get u64 => _buffers + 8;
  int get thread => _buffers + 16;

  // Strings to the native side. Each native call consumes the bytes before
  // it can run Lua code, so nested host functions can reuse the buffer.
  int _scratchCapacity = 256;
  late int _scratch;
  late _Token _scratchOwner;

  int addFunction(DartFunction f) {
    final id = _nextFunction++;
    functions[id] = f;
    return id;
  }

  LuaState viewOf(int pointer) {
    if (pointer == mainPointer) return main;
    final last = _lastView;
    if (last != null && last._l == pointer) return last;
    return _lastView = LuaState._(this, pointer);
  }

  int scratch(int bytes) {
    if (bytes > _scratchCapacity) {
      var capacity = _scratchCapacity;
      while (capacity < bytes) {
        capacity *= 2;
      }
      detachFree(_scratchOwner);
      memFree(_scratch);
      _scratch = memAlloc(capacity);
      _scratchCapacity = capacity;
      _scratchOwner = _Token();
      attachFree(_scratchOwner, _scratch);
    }
    return _scratch;
  }

  /// UTF-8 bytes of [s] with a NUL after them, in the scratch buffer.
  (int, int) encode(String s) {
    final buffer = scratch(3 * s.length + 1);
    return (buffer, encodeUtf8(s, buffer));
  }

  void close() {
    closed = true;
    detachClose(this);
    _tokenFinalizer.detach(this);
    luadart_close(mainPointer);
    _byToken.remove(token);
    functions.clear();
    detachFree(this);
    memFree(_buffers);
    detachFree(_scratchOwner);
    memFree(_scratch);
  }

  static int _dispatch(int token, int l, int functionId, int op) {
    final vm = _byToken[token]?.target;
    if (vm == null || vm.closed) return LUADART_HOST_ERROR_NO_OBJECT;
    if (op == LUADART_HOST_RELEASE) {
      vm.functions.remove(functionId);
      return 0;
    }
    final ls = vm.viewOf(l);
    final f = vm.functions[functionId];
    if (f == null) return _raise(ls, 'host function was released');
    vm.callbackDepth++;
    try {
      final n = f(ls);
      if (n < 0) return _raise(ls, 'host function returned $n');
      return n;
    } on LuaRaise {
      return luadart_gettop(l) > 0
          ? LUADART_HOST_ERROR
          : LUADART_HOST_ERROR_NO_OBJECT;
    } on LuaError catch (e) {
      return _raise(ls, e.message);
    } catch (e) {
      return _raise(ls, '$e');
    } finally {
      vm.callbackDepth--;
    }
  }

  static int _raise(LuaState ls, String message) {
    try {
      ls.pushString(message);
      return LUADART_HOST_ERROR;
    } catch (_) {
      return LUADART_HOST_ERROR_NO_OBJECT;
    }
  }
}
