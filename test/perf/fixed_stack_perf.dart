// ignore_for_file: avoid_print
//
// lua_dardo_plus vs lua_dart: VM workloads of the stack benchmark: loops, tables and calls.
// The Lua sources are those of the lua_dardo_plus benchmark of the same name.
//
// Run:
//   cd test/perf && dart run fixed_stack_perf.dart

import 'vms.dart';

/// Tight numeric for-loop.
/// Hot stack ops: push/pop for FORLOOP counter, ADD temporaries.
const _tightLoop = '''
local sum = 0
for i = 1, 500000 do
  sum = sum + i
end
return sum
''';

/// Table creation and indexed access.
/// Hot stack ops: setTop (nRegs) on each table-library call; many pushN/popN
/// from function call setup and return.
const _tableOps = '''
local t = {}
for i = 1, 50000 do
  t[i] = i * 2
end
local sum = 0
for i = 1, 50000 do
  sum = sum + t[i]
end
return sum
''';

/// Many small function calls — each call goes through pushN/popN/setTop.
/// This is the workload most sensitive to stack allocation overhead.
const _functionCalls = '''
local function add(a, b) return a + b end
local sum = 0
for i = 1, 100000 do
  sum = add(sum, i)
end
return sum
''';

/// Recursive Fibonacci — deep call stack with many frame create/destroy
/// cycles.  Each frame does: popN (args), pushN (args into new frame),
/// setTop (nRegs), then popN (results) on return.
const _fibonacci = '''
local function fib(n)
  if n < 2 then return n end
  return fib(n-1) + fib(n-2)
end
return fib(25)
''';

Future<void> main() => compareVms(
  'fixed stack',
  {
    'tightLoop': _tightLoop,
    'tableOps': _tableOps,
    'functionCalls': _functionCalls,
    'fibonacci': _fibonacci,
  },
  warmupRuns: 3,
  benchmarkRuns: 20,
);
