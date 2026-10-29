@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:test/test.dart';

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory _Worker(JSString url);
  external void postMessage(JSAny message);
  external set onmessage(JSFunction f);
  external void terminate();
}

extension type _Event._(JSObject _) implements JSObject {
  external JSObject get data;
}

extension type _Reply._(JSObject _) implements JSObject {
  external JSNumber? get status;
  external JSString? get text;
  external JSString? get error;
}

void main() {
  test('a classic Worker, as squadron starts, can import the module', () async {
    final worker = _Worker('support/classic_worker.js'.toJS);
    addTearDown(() => worker.terminate());
    final reply = Completer<_Reply>();
    worker.onmessage = ((_Event e) => reply.complete(_Reply._(e.data))).toJS;
    final moduleUrl = Uri.base
        .resolve('packages/lua_dart/web/lua_dart_module.mjs')
        .toString();
    worker.postMessage({'moduleUrl': moduleUrl}.jsify()!);
    final r = await reply.future.timeout(const Duration(seconds: 20));
    expect(r.error?.toDart, isNull);
    expect(r.status?.toDartInt, 0);
    expect(r.text?.toDart, 'Lua 5.4');
  });
}
