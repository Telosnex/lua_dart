/// Writes the export lists src/exports_apple.txt, src/exports_elf.map and
/// src/exports_windows.def from the functions of src/lua_dart.h.
///
/// Run it after a change to the functions of the header. With `--check`, it
/// fails if a file differs instead of writing it.
library;

import 'dart:io';

final _function = RegExp(r'\b(luadart_[a-z_0-9]+)\(');

List<String> exportedFunctions(String header) =>
    {for (final m in _function.allMatches(header)) m[1]!}.toList()..sort();

Map<String, String> exportFiles(List<String> names) => {
  'src/exports_apple.txt': [for (final n in names) '_$n\n'].join(),
  'src/exports_elf.map': [
    'LUA_DART_1 {\n',
    '  global:\n',
    for (final n in names) '    $n;\n',
    '  local:\n',
    '    *;\n',
    '};\n',
  ].join(),
  'src/exports_windows.def': [
    'LIBRARY lua_dart\n',
    'EXPORTS\n',
    for (final n in names) '  $n\n',
  ].join(),
};

void main(List<String> args) {
  final check = args.contains('--check');
  final names = exportedFunctions(File('src/lua_dart.h').readAsStringSync());
  var stale = false;
  for (final MapEntry(key: path, value: contents) in exportFiles(
    names,
  ).entries) {
    final file = File(path);
    if (file.existsSync() && file.readAsStringSync() == contents) continue;
    if (check) {
      stderr.writeln('$path is stale: run dart run tool/generate_exports.dart');
      stale = true;
    } else {
      file.writeAsStringSync(contents);
      stdout.writeln('Wrote $path');
    }
  }
  if (stale) exit(1);
  stdout.writeln('${names.length} exports');
}
