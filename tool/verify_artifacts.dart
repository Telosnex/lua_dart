/// Checks that the pins and generated files of the native build agree:
///
/// - native_artifacts/sources.json and tool/lua_pin.sh pin the same Lua
///   release file;
/// - src/exports_* list exactly the functions of src/lua_dart.h;
/// - the ABI version of src/lua_dart.h is the one that
///   tool/build_native_artifact.sh and the tests check.
///
/// Run it with `dart tool/verify_artifacts.dart`: `dart run` would run the
/// build hook first.
library;

import 'dart:convert';
import 'dart:io';

import 'generate_exports.dart' as exports;

void main() {
  final problems = <String>[];
  String read(String path) => File(path).readAsStringSync();

  final pin = {
    for (final m in RegExp(
      r'^(LUA_[A-Z0-9]+)=(.*)$',
      multiLine: true,
    ).allMatches(read('tool/lua_pin.sh')))
      m[1]!: m[2]!.replaceAll('"', ''),
  };
  final version = pin['LUA_VERSION'];
  final url = pin['LUA_URL']?.replaceAll(r'$LUA_VERSION', version ?? '');
  final sources = jsonDecode(read('native_artifacts/sources.json'));
  final lua = switch (sources) {
    {'schema': 1, 'sources': [final Map<String, Object?> only]} => only,
    _ => null,
  };
  if (lua == null || lua['name'] != 'lua') {
    problems.add('sources.json must pin exactly one source, "lua".');
  } else {
    if (lua['url'] != url) {
      problems.add('sources.json url ${lua['url']} is not $url.');
    }
    if (lua['sha256'] != pin['LUA_SHA256']) {
      problems.add('sources.json sha256 is not LUA_SHA256 of lua_pin.sh.');
    }
  }

  final header = read('src/lua_dart.h');
  final names = exports.exportedFunctions(header);
  exports.exportFiles(names).forEach((path, contents) {
    if (read(path) != contents) {
      problems.add('$path is stale: run dart tool/generate_exports.dart.');
    }
  });

  final abi = RegExp(
    r'#define LUADART_ABI_VERSION (\d+)',
  ).firstMatch(header)?[1];
  if (!read('tool/build_native_artifact.sh').contains('lua_dart ABI $abi;')) {
    problems.add('tool/build_native_artifact.sh does not check ABI $abi.');
  }
  if (!read('test/lua_state_test.dart').contains('lua_dart ABI $abi;')) {
    problems.add('test/lua_state_test.dart does not check ABI $abi.');
  }

  if (problems.isNotEmpty) {
    problems.forEach(stderr.writeln);
    exit(1);
  }
  stdout.writeln('OK: Lua $version, ABI $abi, ${names.length} exports');
}
