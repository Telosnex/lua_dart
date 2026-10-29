/// Bundles the lua_dart library as a Dart code asset.
///
/// With package:kiln (kiln ADR 001), the hook downloads the library from the
/// GitHub release in native_artifacts/prebuilt.json when the package sources
/// match it (user define `native_build`: auto, download or source).
/// Otherwise it runs tool/build_native_artifact.sh, which needs CMake and the
/// target C compiler. Lua comes from the pinned release tarball in
/// native_artifacts/sources.json (fetched once into the kiln cache, or put
/// there by a packager for a build without network). Apple targets build on
/// macOS, Android targets on macOS or Linux, and Linux and Windows targets on
/// Linux (Windows with MinGW).
///
/// For a web build, the hook installs the web runtime files of
/// native_artifacts/web.json, if the package has them (kiln ADR 002).
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:kiln/kiln.dart';

const _assetName = 'lua_dart_bindings_generated.dart';

/// The NDK of the release builds. A source build uses it if it is installed.
const _androidNdkVersion = '28.2.13676358';

const _targets = {
  'android-arm',
  'android-arm64',
  'android-x64',
  'ios-arm64-iphoneos',
  'ios-arm64-iphonesimulator',
  'ios-x64-iphonesimulator',
  'linux-arm64',
  'linux-x64',
  'macos-arm64',
  'macos-x64',
  'windows-arm64',
  'windows-x64',
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return Kiln(input: input, output: output, log: _log).installWeb();
    }

    final stopwatch = Stopwatch()..start();
    final target = TargetName.of(input.config.code);
    if (!_targets.contains(target.name)) {
      throw UnsupportedError(
        'lua_dart has no native library for $target. Supported targets: '
        '${_targets.join(', ')}.',
      );
    }
    await Kiln(
      input: input,
      output: output,
      log: _log,
    ).run((source) => _buildFromSource(input, output, target, source));
    _log('Hook completed in ${_formatDuration(stopwatch.elapsed)}');
  });
}

void _log(String message) => stderr.writeln('[lua_dart] $message');

Future<void> _buildFromSource(
  BuildInput input,
  BuildOutputBuilder output,
  TargetName target,
  SourceBuild source,
) async {
  final hostProblem = _hostProblem(target);
  if (hostProblem != null) throw UnsupportedError('lua_dart: $hostProblem');

  final code = input.config.code;
  final packageRoot = input.packageRoot;
  final shared = input.outputDirectoryShared;
  final luaDirectory = await source.pinnedSource('lua');
  final tarballs = luaDirectory
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.tar.gz'))
      .toList();
  if (tarballs.length != 1) {
    throw StateError(
      'lua_dart: expected one Lua tarball in ${luaDirectory.path}.',
    );
  }
  final environment = {
    'LUADART_LUA_TARBALL': tarballs.single.path,
    'LUADART_BUILD_JOBS': '${Platform.numberOfProcessors}',
    if (target.os == OS.macOS)
      'LUADART_MACOS_VERSION': '${code.macOS.targetVersion}.0',
    if (target.os == OS.iOS)
      'LUADART_IOS_VERSION': '${code.iOS.targetVersion}.0',
    if (target.os == OS.android) ...{
      'LUADART_ANDROID_API': '${code.android.targetNdkApi}',
      'ANDROID_NDK_HOME': _androidNdk(),
    },
  };

  // Two targets can build at once, so a lock guards each build directory.
  // The build directory is isolated by target, settings, build scripts and
  // compiler. The script performs a clean build and checks the exports.
  final scripts = [
    for (final path in [
      'tool/build_native_artifact.sh',
      'tool/lua_pin.sh',
      'native_artifacts/sources.json',
    ])
      await File.fromUri(packageRoot.resolve(path)).readAsString(),
  ];
  final buildKey = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            target.name,
            environment,
            scripts,
            await _compilerVersion(target),
          ]),
        ),
      )
      .toString()
      .substring(0, 16);
  final buildRoot = shared.resolve('build/${target.name}-$buildKey/');
  final library = File.fromUri(
    input.outputDirectory.resolve(target.os.dylibFileName('lua_dart')),
  );
  await Directory.fromUri(input.outputDirectory).create(recursive: true);

  await _withLock(
    File.fromUri(shared.resolve('build/${target.name}-$buildKey.lock')),
    () => _run(
      'Building $target',
      packageRoot,
      ['tool/build_native_artifact.sh', target.name],
      {
        ...environment,
        'LUADART_BUILD_ROOT': buildRoot.toFilePath(),
        'LUADART_OUTPUT': library.path,
      },
    ),
  );

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _assetName,
      linkMode: DynamicLoadingBundled(),
      file: library.uri,
    ),
  );
}

/// Why this host cannot build [target] from source, or null if it can.
String? _hostProblem(TargetName target) {
  final (hosts, allowed) = switch (target.os) {
    OS.iOS || OS.macOS => ('macOS', Platform.isMacOS),
    OS.android => ('macOS or Linux', Platform.isMacOS || Platform.isLinux),
    OS.linux => ('Linux', Platform.isLinux),
    // MinGW cross-compiles the Windows libraries on Linux.
    OS.windows => ('Linux, with MinGW', Platform.isLinux),
    _ => ('no host', false),
  };
  if (allowed) return null;
  return 'a source build of $target runs only on $hosts, and this host is '
      '${Platform.operatingSystem}.';
}

/// The `--version` output of the compiler that tool/build_native_artifact.sh
/// uses for [target]. For Android, the NDK path is in the build key instead.
Future<String> _compilerVersion(TargetName target) async {
  final hostArm = Platform.version.contains('linux_arm64');
  final command = switch (target.name) {
    'linux-x64' => [hostArm ? 'x86_64-linux-gnu-gcc' : 'gcc'],
    'linux-arm64' => [hostArm ? 'gcc' : 'aarch64-linux-gnu-gcc'],
    'windows-x64' => ['x86_64-w64-mingw32-gcc'],
    'windows-arm64' => ['aarch64-w64-mingw32-clang'],
    _ when target.os == OS.iOS || target.os == OS.macOS => ['xcrun', 'clang'],
    _ => null,
  };
  if (command == null) return '';
  try {
    final result = await Process.run(command.first, [
      ...command.skip(1),
      '--version',
    ]);
    return '${result.stdout}';
  } on ProcessException {
    return '';
  }
}

/// The Android NDK: the release version if it is installed, else the NDK of
/// the environment, else the newest NDK of the Android SDK.
String _androidNdk() {
  final env = Platform.environment;
  final home = env['HOME'];
  final sdks = [
    ?env['ANDROID_HOME'],
    ?env['ANDROID_SDK_ROOT'],
    if (home != null) ...['$home/Library/Android/sdk', '$home/Android/Sdk'],
  ].where((sdk) => Directory('$sdk/ndk').existsSync());
  bool isNdk(String path) => File('$path/source.properties').existsSync();

  final candidates = [
    for (final sdk in sdks) '$sdk/ndk/$_androidNdkVersion',
    ?env['ANDROID_NDK_HOME'],
    ?env['ANDROID_NDK_ROOT'],
    ?env['ANDROID_NDK'],
    ?env['ANDROID_NDK_LATEST_HOME'],
    for (final sdk in sdks)
      ...(Directory('$sdk/ndk').listSync().whereType<Directory>().toList()
            ..sort((a, b) => _compareVersions(b.path, a.path)))
          .map((d) => d.path),
  ];
  for (final candidate in candidates) {
    if (isNdk(candidate)) {
      _log('Android NDK: $candidate');
      return candidate;
    }
  }
  throw StateError(
    'lua_dart: no Android NDK found. Install NDK $_androidNdkVersion with '
    'the Android SDK manager, or set ANDROID_NDK_HOME.',
  );
}

int _compareVersions(String a, String b) {
  List<int> parts(String path) => [
    for (final part in path.split(RegExp(r'[/\\]')).last.split('.'))
      int.tryParse(part) ?? 0,
  ];
  final (x, y) = (parts(a), parts(b));
  for (var i = 0; i < x.length && i < y.length; i++) {
    if (x[i] != y[i]) return x[i].compareTo(y[i]);
  }
  return x.length.compareTo(y.length);
}

Future<void> _run(
  String what,
  Uri packageRoot,
  List<String> bashArguments,
  Map<String, String> environment,
) async {
  _log(what);
  final stopwatch = Stopwatch()..start();
  // bash runs the script, so the file mode of a checkout does not matter.
  final process = await Process.start(
    bashExecutable(),
    bashArguments,
    workingDirectory: packageRoot.toFilePath(),
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw StateError(
      'lua_dart: ${bashArguments.join(' ')} failed with exit code '
      '$exitCode.',
    );
  }
  _log('$what took ${_formatDuration(stopwatch.elapsed)}');
}

Future<T> _withLock<T>(File lockFile, Future<T> Function() action) async {
  await lockFile.parent.create(recursive: true);
  final handle = await lockFile.open(mode: FileMode.append);
  try {
    await handle.lock(FileLock.blockingExclusive);
    return await action();
  } finally {
    await handle.close();
  }
}

String _formatDuration(Duration duration) {
  final millis = duration.inMilliseconds;
  if (millis < 1000) return '${millis}ms';
  final seconds = duration.inSeconds;
  if (seconds < 60) return '$seconds.${(millis % 1000) ~/ 100}s';
  return '${seconds ~/ 60}m ${seconds % 60}s';
}
