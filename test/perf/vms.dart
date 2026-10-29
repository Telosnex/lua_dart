// The two Lua VMs of the comparison benchmarks: lua_dardo_plus (Lua 5.3 in
// Dart, with its default tuning flags, which are its fastest settings) and
// lua_dart (Lua 5.4.9 in C over FFI).
//
// Each run makes a new state and opens the standard libraries, as the
// lua_dardo_plus benchmarks did, so state setup is in the time of both VMs.

import 'package:lua_dardo_plus/lua.dart' as dardo;
import 'package:lua_dart/lua_dart.dart' as native;

import 'perf_tester.dart';

/// A clock and a random generator in Lua, so both VMs give the same output.
/// The VMs have different random generators, and os.time is the wall clock.
const deterministicPrelude = r'''
do
  local tick = 1767350096
  os.time = function() tick = tick + 1 return tick end
  local s = 1
  math.randomseed = function(n) s = math.floor(n) % 2147483648 end
  math.random = function(lo, hi)
    s = (s * 1103515245 + 12345) % 2147483648
    if lo == nil then return s / 2147483648 end
    if hi == nil then lo, hi = 1, lo end
    return lo + s % (hi - lo + 1)
  end
end
''';

String runDardo(String script, {String prelude = ''}) {
  final ls = dardo.LuaState.newState();
  ls.openLibs();
  if (prelude.isNotEmpty) {
    ls.loadString(prelude);
    ls.pCall(0, 0, 0);
  }
  ls.loadString(script);
  ls.pCall(0, 1, 0);
  return ls.toStr(-1) ?? 'nil';
}

String runLuaDart(String script, {String prelude = ''}) {
  final ls = native.LuaState.newState();
  try {
    ls.openLibs();
    if (prelude.isNotEmpty && !ls.doString(prelude)) {
      return 'error: ${ls.toStr(-1)}';
    }
    if (ls.loadString(script) != native.ThreadStatus.luaOk ||
        ls.pCall(0, 1, 0) != native.ThreadStatus.luaOk) {
      return 'error: ${ls.toStr(-1)}';
    }
    return ls.toStr(-1) ?? 'nil';
  } finally {
    ls.close();
  }
}

/// The web runtime, for a browser run (`dart test -p chrome web_perf_test.dart`).
Future<void> _load() => native.LuaState.loadRuntime(
  moduleUri: Uri.parse('packages/lua_dart/web/lua_dart_module.mjs'),
);

/// Runs one [PerfTester] per workload, so each workload gets its own numbers.
Future<void> compareVms(
  String suite,
  Map<String, String> workloads, {
  String prelude = '',
  required int warmupRuns,
  required int benchmarkRuns,
}) async {
  await _load();
  for (final MapEntry(key: name, value: script) in workloads.entries) {
    await PerfTester<String, String>(
      testName: '$suite: $name',
      testCases: [script],
      implementation1: (s) => runDardo(s, prelude: prelude),
      implementation2: (s) => runLuaDart(s, prelude: prelude),
      impl1Name: 'lua_dardo_plus',
      impl2Name: 'lua_dart',
    ).run(warmupRuns: warmupRuns, benchmarkRuns: benchmarkRuns);
  }
}

/// Compiles each chunk without running it: lexer, parser and code
/// generator. The lua_dardo_plus lexer and parser benchmarks measured this
/// work. One state per VM is reused, so only the compile is timed.
Future<void> compareCompile(
  String suite,
  Map<String, String> chunks, {
  required int warmupRuns,
  required int benchmarkRuns,
}) async {
  await _load();
  final d = dardo.LuaState.newState()..openLibs();
  final n = native.LuaState.newState()..openLibs();
  try {
    for (final MapEntry(key: name, value: chunk) in chunks.entries) {
      await PerfTester<String, String>(
        testName: '$suite: $name (compile only)',
        testCases: [chunk],
        implementation1: (s) {
          final status = d.loadString(s);
          final result = status == dardo.ThreadStatus.luaOk
              ? 'ok'
              : 'error: ${d.toStr(-1)}';
          d.pop(1);
          return result;
        },
        implementation2: (s) {
          final status = n.loadString(s, chunkName: '=perf');
          final result = status == native.ThreadStatus.luaOk
              ? 'ok'
              : 'error: ${n.toStr(-1)}';
          n.pop(1);
          return result;
        },
        impl1Name: 'lua_dardo_plus',
        impl2Name: 'lua_dart',
      ).run(warmupRuns: warmupRuns, benchmarkRuns: benchmarkRuns);
    }
  } finally {
    n.close();
  }
}
