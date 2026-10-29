@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:lua_dart/lua_dart.dart';
import 'package:test/test.dart';

void main() {
  test('the .wasm file loads with the version query of the module', () async {
    await LuaState.loadRuntime(
      moduleUri: Uri.parse('packages/lua_dart/web/lua_dart_module.mjs'),
    );
    final performance = globalContext['performance']! as JSObject;
    final entries =
        (performance.callMethod('getEntriesByType'.toJS, 'resource'.toJS)
                as JSArray<JSObject>)
            .toDart
            .map((e) => (e['name']! as JSString).toDart);
    final module = entries.singleWhere(
      (n) => n.contains('lua_dart_module.mjs'),
    );
    final wasm = entries.singleWhere((n) => n.contains('lua_dart_module.wasm'));
    final v = Uri.parse(module).queryParameters['v'];
    expect(v, isNotEmpty);
    expect(Uri.parse(wasm).queryParameters['v'], v);
  });
}
