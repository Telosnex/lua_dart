// ignore_for_file: avoid_print
//
// lua_dardo_plus vs lua_dart: string.format workloads.
// The Lua sources are those of the lua_dardo_plus benchmark of the same name.
//
// Run:
//   cd test/perf && dart run string_format_perf.dart

import 'vms.dart';

/// The user's real-world countdown timer pattern: 4 × %d / %2d per call.
const _countdown = '''
local result
for i = 1, 50000 do
  result = string.format("%dd %dh %dm %2ds", i, i % 24, i % 60, i % 60)
end
return result
''';

/// Pure %d (simplest fast path).
const _pureIntFormat = '''
local result
for i = 1, 50000 do
  result = string.format("%d %d %d", i, i * 2, i * 3)
end
return result
''';

/// Mixed: %s and %d together.
const _mixedFormat = '''
local result
for i = 1, 50000 do
  result = string.format("name=%s id=%d", "hello", i)
end
return result
''';

/// Zero-padded and width specifiers: %02d, %05d.
const _paddedFormat = '''
local result
for i = 1, 50000 do
  result = string.format("%02d:%02d:%02d", i % 24, i % 60, i % 60)
end
return result
''';

/// Complex: %f, %e, %x — these still go through sprintf even in fast mode,
/// but the parse cache and StringBuffer still help.
const _complexFormat = '''
local result
for i = 1, 20000 do
  result = string.format("0x%x %.2f %e", i, i * 1.5, i * 0.001)
end
return result
''';

Future<void> main() => compareVms(
  'string format',
  {
    'countdown': _countdown,
    'pureIntFormat': _pureIntFormat,
    'mixedFormat': _mixedFormat,
    'paddedFormat': _paddedFormat,
    'complexFormat': _complexFormat,
  },
  warmupRuns: 3,
  benchmarkRuns: 20,
);
