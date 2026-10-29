/// Runs after each native build of the kiln release workflow:
///
/// - Linux: the ABI smoke test of native_test/smoke_test.c against the built
///   library, and its newest glibc requirement, which must be 2.31 or older.
///   The build script already checks the architecture, the exports and the
///   dependencies of every target.
/// - macos-arm64: the Dart API tests, with a source build.
///
/// The workflow runs a copy of this file outside the package, so it imports
/// only dart: libraries.
library;

import 'dart:io';

const _glibcBaseline = [2, 31];

Future<void> main() async {
  final env = Platform.environment;
  final target = env['TARGET']!;
  final root = env['GITHUB_WORKSPACE']!;
  final dir = '${env['OUT']}/out/$target';

  if (target.startsWith('linux-')) {
    final smoke = '${env['RUNNER_TEMP']}/luadart_smoke_test';
    await _run('gcc', [
      '-std=c11',
      '-O2',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-I$root/src',
      '$root/native_test/smoke_test.c',
      '-L$dir',
      '-llua_dart',
      '-pthread',
      '-Wl,-rpath,$dir',
      '-o',
      smoke,
    ]);
    await _run(smoke, []);

    final symbols = await _run('objdump', ['-T', '$dir/liblua_dart.so']);
    final versions = {
      for (final m in RegExp(r'GLIBC_([0-9.]+)').allMatches(symbols))
        [for (final part in m[1]!.split('.')) int.parse(part)],
    }.toList()..sort(_compare);
    final newest = versions.last;
    stdout.writeln('Newest glibc requirement: ${newest.join('.')}');
    if (_compare(newest, _glibcBaseline) > 0) {
      stderr.writeln(
        'liblua_dart.so needs glibc ${newest.join('.')}, newer than '
        '${_glibcBaseline.join('.')}.',
      );
      exit(1);
    }
  } else if (target == 'macos-arm64') {
    await _run('dart', ['test', '-r', 'expanded'], workingDirectory: root);
  }
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

Future<String> _run(
  String executable,
  List<String> args, {
  String? workingDirectory,
}) async {
  stdout.writeln('+ $executable ${args.join(' ')}');
  final process = await Process.start(
    executable,
    args,
    workingDirectory: workingDirectory,
  );
  final out = StringBuffer();
  await Future.wait([
    process.stdout.forEach((bytes) {
      final text = String.fromCharCodes(bytes);
      out.write(text);
      stdout.write(text);
    }),
    process.stderr.forEach(stderr.add),
  ]);
  final code = await process.exitCode;
  if (code != 0) {
    stderr.writeln('$executable: exit $code');
    exit(code);
  }
  return '$out';
}
