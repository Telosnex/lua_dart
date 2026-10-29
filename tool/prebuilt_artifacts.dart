import 'dart:io';

import 'package:kiln/kiln.dart';

/// Downloads the released libraries of the given targets (default: all) into
/// `build/native_artifacts/<target>/`, after a check of their SHA-256. The
/// tool/test_*_artifact*.sh scripts test the files there.
///
/// tool/build_native_artifact.sh writes a local build to the same place.
/// This command replaces such a file with the released one.
Future<void> main(List<String> targets) async {
  final root = File.fromUri(Platform.script).parent.parent.uri;
  final manifest = await PrebuiltManifest.load(root);
  if (manifest == null) {
    stderr.writeln('error: $manifestPath is missing. Run the native release.');
    exitCode = 1;
    return;
  }
  final local = await computeSourceKey(root);
  if (local.key != manifest.sourceKey) {
    stderr.writeln(
      'warning: the sources differ from the release (local source key '
      '${local.short}, release ${manifest.sourceKey.substring(0, 16)}). '
      'These are the released files.',
    );
  }
  final selected = targets.isEmpty ? manifest.targets.keys.toList() : targets;
  final cache = defaultCacheRoot();
  for (final name in selected) {
    final target = manifest.targets[name];
    if (target == null) {
      stderr.writeln('error: the release has no files for $name.');
      exitCode = 1;
      return;
    }
    for (final file in target.files) {
      final destination = File.fromUri(
        root.resolve('build/native_artifacts/$name/${file.name}'),
      );
      await destination.parent.create(recursive: true);
      await fetchVerified(file.fetchSpec, destination, archiveCache: cache);
      stdout.writeln('$name: ${destination.path} (${file.sha256})');
    }
  }
}
