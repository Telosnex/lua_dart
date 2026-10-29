/// Runs before each native build of the kiln release workflow. The Linux and
/// Windows targets build in pinned Debian containers (see
/// .github/workflows/kiln_release.yml). This installs their toolchain with
/// tool/install_build_toolchain.sh and describes it in KILN_TOOLCHAIN.
///
/// The workflow runs a copy of this file outside the package, so it imports
/// only dart: libraries.
library;

import 'dart:io';

Future<void> main() async {
  final env = Platform.environment;
  final target = env['TARGET']!;
  if (!target.startsWith('linux-') && !target.startsWith('windows-')) return;

  final root = env['GITHUB_WORKSPACE']!;
  final script = '$root/tool/install_build_toolchain.sh';
  await _run('bash', [script, target]);

  final String compiler;
  final extra = <String>[];
  switch (target) {
    case 'windows-arm64':
      // GCC has no Windows arm64 target: llvm-mingw, at /opt/llvm-mingw.
      _append(env['GITHUB_PATH']!, '/opt/llvm-mingw/bin');
      final release = RegExp(
        r'^\s*release=(\S+)',
        multiLine: true,
      ).firstMatch(File(script).readAsStringSync())![1]!;
      extra.add('llvm-mingw $release');
      compiler = '/opt/llvm-mingw/bin/aarch64-w64-mingw32-clang';
    case 'windows-x64':
      compiler = 'x86_64-w64-mingw32-gcc';
    default:
      compiler = 'gcc';
  }
  final debian = File('/etc/debian_version').readAsStringSync().trim();
  final version = await _run(compiler, ['--version']);
  final toolchain = [
    'Debian $debian',
    ...extra,
    version.split('\n').first.trim(),
  ].join(', ');
  stdout.writeln('Toolchain: $toolchain');
  _append(env['GITHUB_ENV']!, 'KILN_TOOLCHAIN=$toolchain');
}

void _append(String file, String line) =>
    File(file).writeAsStringSync('$line\n', mode: FileMode.append);

Future<String> _run(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    stderr.writeln('$executable ${args.join(' ')}: exit ${result.exitCode}');
    exit(result.exitCode);
  }
  return '${result.stdout}';
}
