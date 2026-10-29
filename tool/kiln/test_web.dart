/// The browser tests of the web runtime files in lib/web/ (kiln ADR 002 D10,
/// D13). The kiln release workflow runs it after `kiln:web install-dev` of
/// the files that tool/kiln/build_web.dart built. The hook builds the host
/// library from source for the test runner: the release for this source key
/// does not exist yet.
///
/// Locally, after `dart run kiln:web install-dev`:
///
///     dart run tool/kiln/test_web.dart
library;

import 'dart:io';

Future<void> main() async {
  final root = Directory.fromUri(Platform.script.resolve('../..')).path;
  for (final args in [
    ['-p', 'chrome', '--compiler', 'dart2js'],
    ['-p', 'chrome', '--compiler', 'dart2wasm', '-j', '1'],
  ]) {
    stdout.writeln('+ dart test ${args.join(' ')}');
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['test', ...args, '-r', 'expanded'],
      workingDirectory: root,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await process.exitCode;
    if (code != 0) exit(code);
  }
}
