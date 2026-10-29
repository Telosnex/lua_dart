/// Builds the pinned Lua release and the lua_dart shim as one Emscripten ES
/// module: lua_dart_module.mjs and lua_dart_module.wasm in --out.
///
/// The kiln release workflow runs it in the pinned emscripten/emsdk image
/// (kiln ADR 002 D10). --toolchain-file gets the Emscripten version for
/// web.json. For a local build, activate the Emscripten SDK, or put it at
/// ../emsdk, then install the files with
///
///     dart run tool/kiln/build_web.dart --out /tmp/lua_dart_web
///     dart run kiln:web install-dev --from /tmp/lua_dart_web
///
/// Adapted from tool/kiln/build_web.dart of zxing_dart.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

import '../generate_exports.dart' as exports;

const _usage =
    'dart run tool/kiln/build_web.dart --out <dir> [--work <dir>] '
    '[--toolchain-file <file>]\n'
    '  --out             Directory for the two generated files. It must be '
    'empty or hold only these files.\n'
    '  --work            Build directory. Default: build/web, or '
    r'$RUNNER_TEMP/lua-dart-web-build in GitHub Actions.'
    '\n'
    '  --toolchain-file  Gets the Emscripten version.';

const _outputs = ['lua_dart_module.mjs', 'lua_dart_module.wasm'];

/// The Lua core and standard libraries: all of src/ except the lua and luac
/// programs.
const _luaFiles = [
  'lapi', 'lcode', 'lctype', 'ldebug', 'ldo', 'ldump', 'lfunc', 'lgc', //
  'llex', 'lmem', 'lobject', 'lopcodes', 'lparser', 'lstate', 'lstring',
  'ltable', 'ltm', 'lundump', 'lvm', 'lzio', 'lauxlib', 'lbaselib',
  'lcorolib', 'ldblib', 'liolib', 'lmathlib', 'loadlib', 'loslib',
  'lstrlib', 'ltablib', 'lutf8lib', 'linit',
];

Future<void> main(List<String> args) async {
  final options = _parse(args);
  final root = Directory.fromUri(
    Platform.script.resolve('../..'),
  ).absolute.path;
  final out = Directory(options['out']!).absolute;
  final runnerTemp = Platform.environment['RUNNER_TEMP'];
  final work = Directory(
    options['work'] ??
        (runnerTemp == null
            ? '$root/build/web'
            : '$runnerTemp/lua-dart-web-build'),
  ).absolute;
  final thirdParty =
      Platform.environment['LUADART_THIRD_PARTY'] ??
      (runnerTemp == null ? '$root/third_party' : '$runnerTemp/third_party');

  if (await out.exists()) {
    final others = [
      await for (final entity in out.list())
        if (!_outputs.contains(
          entity.uri.pathSegments.lastWhere((s) => s != ''),
        ))
          entity.path,
    ];
    if (others.isNotEmpty) {
      _fail('--out holds other files: ${others.join(', ')}');
    }
  }
  await out.create(recursive: true);

  final emsdkEnv = await _emsdkEnvironment(root);
  Future<String> run(List<String> command, [Map<String, String>? env]) => _run(
    command,
    workingDirectory: root,
    emsdkEnv: emsdkEnv,
    environment: env,
  );

  final tarball = (await run(
    ['bash', 'tool/fetch_lua.sh'],
    {'LUADART_THIRD_PARTY': thirdParty},
  )).trim().split('\n').last;
  if (await work.exists()) await work.delete(recursive: true);
  final lua = Directory('${work.path}/lua');
  await lua.create(recursive: true);
  await run([
    'tar',
    '-xzf',
    tarball,
    '-C',
    lua.path,
    '--strip-components',
    '1',
  ]);

  final names = exports.exportedFunctions(
    File('$root/src/lua_dart.h').readAsStringSync(),
  );
  // setjmp and longjmp of Lua errors use Wasm exceptions; JavaScript never
  // sees them, because no Lua error crosses a host function.
  const flags = ['-O3', '-DNDEBUG', '-sSUPPORT_LONGJMP=wasm'];
  await run([
    'emcc',
    '$root/src/lua_dart.c',
    '$root/src/lua_dart_json.c',
    '$root/src/third_party/dtoa.c',
    for (final name in _luaFiles) '${lua.path}/src/$name.c',
    '-I${lua.path}/src',
    '-I$root/src',
    '-std=c11',
    '-DLUA_COMPAT_5_3',
    '-DLUA_USER_H="luadart_user.h"',
    ...flags,
    '--no-entry',
    '-sMODULARIZE=1',
    '-sEXPORT_ES6=1',
    '-sENVIRONMENT=web,worker,node',
    '-sALLOW_MEMORY_GROWTH=1',
    // Host functions are added to the function table at run time.
    '-sALLOW_TABLE_GROWTH=1',
    // The parser and C calls recurse up to LUAI_MAXCCALLS (200) levels.
    '-sSTACK_SIZE=1048576',
    '-sFILESYSTEM=0',
    '-sEXPORTED_FUNCTIONS=${['_malloc', '_free', for (final n in names) '_$n'].join(',')}',
    '-sEXPORTED_RUNTIME_METHODS=HEAPU8,addFunction,UTF8ToString',
    '-o',
    '${out.path}/${_outputs.first}',
  ]);

  if (options['toolchain-file'] case final path?) {
    final version = await Process.run('bash', [
      '-c',
      emsdkEnv == null
          ? 'emcc --version'
          : 'source "\$0" > /dev/null && emcc --version',
      ?emsdkEnv,
    ]);
    final line = '${version.stdout}'
        .split('\n')
        .first
        .replaceFirst(RegExp(r'^emcc \(.*?\) '), 'Emscripten ');
    if (version.exitCode != 0 || !line.startsWith('Emscripten ')) {
      _fail('emcc --version: ${version.stdout}${version.stderr}');
    }
    await File(path).writeAsString('$line\n');
  }

  stdout.writeln('Built:');
  for (final name in _outputs) {
    final file = File('${out.path}/$name');
    if (!file.existsSync()) _fail('Expected output not found: ${file.path}');
    final bytes = await file.readAsBytes();
    stdout.writeln('  ${sha256.convert(bytes)}  ${bytes.length}  $name');
  }
}

Map<String, String> _parse(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-h' || arg == '--help') {
      stdout.writeln(_usage);
      exit(0);
    }
    final name = switch (arg) {
      '--out' => 'out',
      '--work' => 'work',
      '--toolchain-file' => 'toolchain-file',
      _ => _fail('Unknown argument: $arg\n$_usage'),
    };
    if (i + 1 == args.length) _fail('$arg needs a value.\n$_usage');
    options[name] = args[++i];
  }
  if (options['out'] == null) _fail('Pass --out.\n$_usage');
  return options;
}

/// Null if emcc is on the PATH, else the path of ../emsdk/emsdk_env.sh,
/// which each command then sources.
Future<String?> _emsdkEnvironment(String root) async {
  final probe = await Process.run('bash', ['-c', 'command -v emcc']);
  if (probe.exitCode == 0) return null;
  final env = File('$root/../emsdk/emsdk_env.sh');
  if (env.existsSync()) return env.absolute.path;
  _fail(
    'emcc not found. Activate the Emscripten SDK, or put it at '
    '${env.parent.path}.',
  );
}

Future<String> _run(
  List<String> command, {
  required String workingDirectory,
  required String? emsdkEnv,
  Map<String, String>? environment,
}) async {
  final shell = emsdkEnv == null
      ? command
      : [
          'bash',
          '-c',
          'source "\$0" > /dev/null && exec "\$@"',
          emsdkEnv,
          ...command,
        ];
  stdout.writeln('+ ${command.join(' ')}');
  final result = await Process.run(
    shell.first,
    shell.skip(1).toList(),
    workingDirectory: workingDirectory,
    environment: environment,
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    _fail('${command.first} failed with exit code ${result.exitCode}');
  }
  return '${result.stdout}';
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
