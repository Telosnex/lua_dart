// The Emscripten module of the web backend (tool/kiln/build_web.dart).

import 'dart:js_interop';

import '../web_runtime.g.dart';
import 'api_web.g.dart';

/// Where the lua_dart build hook installs the module in a Flutter web app
/// (kiln ADR 002 D1, D8).
const defaultModuleUrl = 'kiln/lua_dart/lua_dart_module.mjs';

extension type _Factory._(JSFunction _) implements JSFunction {
  JSPromise<LuaDartModule> call() =>
      callAsFunction() as JSPromise<LuaDartModule>;
}

extension type _EsModule._(JSObject _) implements JSObject {
  @JS('default')
  external _Factory get factory;
}

/// An instance of the module: the exports of the C ABI and the Emscripten
/// runtime functions of build_web.dart.
extension type LuaDartModule._(JSObject _) implements LuaDartExports {
  /// The memory. Read it again after any call: memory growth replaces it.
  @JS('HEAPU8')
  external JSUint8Array get heap;

  @JS('_malloc')
  external JSNumber malloc(JSNumber bytes);

  @JS('_free')
  external void free(JSNumber address);

  external JSNumber addFunction(JSFunction f, JSString signature);

  @JS('UTF8ToString')
  external JSString utf8ToString(JSNumber address);
}

LuaDartModule? _module;

LuaDartModule get exports =>
    _module ??
    (throw StateError(
      'lua_dart: call `await LuaState.loadRuntime()` before using Lua on the '
      'web.',
    ));

bool get moduleLoaded => _module != null;

@JS('document.baseURI')
external JSString? get _documentBase;

@JS('location.href')
external JSString? get _locationHref;

@JS('document')
external JSObject? get _document;

/// [moduleUri] resolved against the base URI of the page, with the query
/// `v=<webRuntimeVersion>` unless it has a `v` query already (ADR 002 D7).
/// A Worker has no page, so it resolves against the location of the Worker
/// script: pass an absolute [moduleUri] there.
Uri resolveModuleUrl(Uri? moduleUri) {
  final base = Uri.parse(
    (_document != null ? _documentBase : _locationHref)?.toDart ?? '',
  );
  final resolved = base.resolveUri(moduleUri ?? Uri.parse(defaultModuleUrl));
  if (resolved.queryParameters.containsKey('v')) return resolved;
  return resolved.replace(
    queryParameters: {...resolved.queryParameters, 'v': webRuntimeVersion},
  );
}

Future<void>? _loading;

Future<void> loadModule(Uri? moduleUri) {
  if (_module != null) return Future.value();
  return _loading ??= () async {
    try {
      final url = resolveModuleUrl(moduleUri).toString();
      final esModule = await importModule(url.toJS).toDart as _EsModule;
      _module = await esModule.factory().toDart;
    } catch (e) {
      _loading = null;
      throw StateError('lua_dart: cannot load the web runtime: $e');
    }
  }();
}

@JS('BigInt')
external JSBigInt _bigInt(JSAny value);

@JS('Number')
external JSNumber _number(JSAny value);

@JS('String')
external JSString _string(JSAny value);

const _maxSafe = 0x1FFFFFFFFFFFFF;

/// An int64 of the C ABI.
JSBigInt toBigInt(int n) => n >= -_maxSafe && n <= _maxSafe
    ? _bigInt(n.toJS)
    : _bigInt(n.toString().toJS);

int fromBigInt(JSBigInt b) {
  final d = _number(b).toDartDouble;
  if (d >= -_maxSafe && d <= _maxSafe) return d.toInt();
  return int.parse(_string(b).toDart);
}
