// Telosnex's dartToLua / luaToDart (lua_bridge.dart) on both VMs, with a
// tool-result-sized JSON value: the conversion of every json_decode, tool
// result injection and state handoff.
//
//   cd test/perf && dart run conversion_perf.dart
//   dart test -p chrome conversion_perf_test.dart
import 'dart:convert';

import 'package:lua_dardo_plus/lua.dart' as dardo;
import 'package:lua_dart/lua_dart.dart' as native;

import 'conv_dardo.dart' as cd;
import 'conv_native.dart' as cn;

/// About 100 KB of JSON: 300 records of mixed fields, like an inbox listing.
final Object? sample = jsonDecode(
  jsonEncode({
    'messages': [
      for (var i = 0; i < 300; i++)
        {
          'id': 'msg-$i',
          'threadId': 't${i ~/ 3}',
          'unread': i.isEven,
          'size': 1000 + i * 37,
          'score': i / 7,
          'labels': ['INBOX', if (i % 5 == 0) 'STARRED', 'CATEGORY_$i'],
          'from': {'name': 'Sender $i', 'email': 's$i@example.com'},
          'snippet': 'Hello — this is message number $i with some text ' * 2,
        },
    ],
    'nextPageToken': 'abc',
  }),
);

double _bench(void Function() f, {int runs = 30}) {
  for (var i = 0; i < 5; i++) {
    f();
  }
  final times = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    f();
    times.add(sw.elapsedMicroseconds / 1000);
  }
  times.sort();
  return times[times.length ~/ 2];
}

Future<void> run() async {
  await native.LuaState.loadRuntime(
    moduleUri: Uri.parse('packages/lua_dart/web/lua_dart_module.mjs'),
  );
  final d = dardo.LuaState.newState()..openLibs();
  final n = native.LuaState.newState()..openLibs();
  final bytes = jsonEncode(sample).length;
  final dTo = _bench(() {
    cd.dartToLua(d, sample);
    d.pop(1);
  });
  final nTo = _bench(() {
    cn.dartToLua(n, sample);
    n.pop(1);
  });
  cd.dartToLua(d, sample);
  cn.dartToLua(n, sample);
  final dFrom = _bench(() => cd.luaToDart(d, -1));
  final nFrom = _bench(() => cn.luaToDart(n, -1));
  // Lua tables have no key order: compare sorted.
  if (_canonical(cd.luaToDart(d, -1)) != _canonical(cn.luaToDart(n, -1))) {
    throw StateError('outputs differ');
  }
  // The C library: json.decode of the text, json.encode back to text.
  final text = jsonEncode(sample);
  n.openLibs(libs: {native.LuaLib.json});
  n.getGlobal('json');
  n.getField(-1, 'decode');
  n.getField(-2, 'encode');
  final cDecode = _bench(() {
    n.pushValue(-2);
    n.pushString(text);
    n.call(1, 1);
    n.pop(1);
  });
  cn.dartToLua(n, sample);
  n.setGlobal('value');
  final cEncode = _bench(() {
    n.pushValue(-1);
    n.getGlobal('value');
    n.call(1, 1);
    n.toStr(-1);
    n.pop(1);
  });
  // The bridge path from text: jsonDecode + dartToLua, luaToDart + jsonEncode.
  final dText = _bench(() {
    cd.dartToLua(d, jsonDecode(text));
    d.pop(1);
  });
  final nText = _bench(() {
    cn.dartToLua(n, jsonDecode(text));
    n.pop(1);
  });
  cd.dartToLua(d, sample);
  cn.dartToLua(n, sample);
  final dOut = _bench(() => jsonEncode(cd.luaToDart(d, -1)));
  final nOut = _bench(() => jsonEncode(cn.luaToDart(n, -1)));
  print('conversion of $bytes bytes of JSON, median ms:');
  print(
    '  dartToLua  lua_dardo_plus ${dTo.toStringAsFixed(2)}  lua_dart ${nTo.toStringAsFixed(2)}',
  );
  print(
    '  luaToDart  lua_dardo_plus ${dFrom.toStringAsFixed(2)}  lua_dart ${nFrom.toStringAsFixed(2)}',
  );
  print(
    '  text -> table  bridge on lua_dardo_plus ${dText.toStringAsFixed(2)}'
    '  bridge on lua_dart ${nText.toStringAsFixed(2)}  json.decode ${cDecode.toStringAsFixed(2)}',
  );
  print(
    '  table -> text  bridge on lua_dardo_plus ${dOut.toStringAsFixed(2)}'
    '  bridge on lua_dart ${nOut.toStringAsFixed(2)}  json.encode ${cEncode.toStringAsFixed(2)}',
  );
  n.close();
}

Future<void> main() => run();

String _canonical(Object? v) => jsonEncode(_sort(v));

Object? _sort(Object? v) => switch (v) {
  final Map m => {
    for (final k in m.keys.map((k) => '$k').toList()..sort()) k: _sort(m[k]),
  },
  final List l => [for (final e in l) _sort(e)],
  _ => v,
};
