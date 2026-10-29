// ignore_for_file: avoid_print
//
// lua_dardo_plus vs lua_dart: The countdown widget lifecycle, 10000 refresh + render cycles.
// The Lua sources are those of the lua_dardo_plus benchmark of the same name.
//
// Run:
//   cd test/perf && dart run countdown_widget_perf.dart

import 'vms.dart';

const _countdownWidget = r'''
-- Jan 1 2026 00:00:00 UTC as a Unix timestamp
local EPOCH = 1767225600
function init()
  local now = os.time()
  local elapsed = now - EPOCH
  if elapsed < 0 then elapsed = 0 end
  local days = math.floor(elapsed / 86400)
  local hours = math.floor((elapsed % 86400) / 3600)
  local minutes = math.floor((elapsed % 3600) / 60)
  local seconds = elapsed % 60
  return { days = days, hours = hours, minutes = minutes, seconds = seconds }
end
function render(state)
  local now = os.time()
  local elapsed = now - EPOCH
  if elapsed < 0 then elapsed = 0 end
  local d = string.format("%d", math.floor(elapsed / 86400))
  local h = string.format("%02d", math.floor((elapsed % 86400) / 3600))
  local m = string.format("%02d", math.floor((elapsed % 3600) / 60))
  local s = string.format("%02d", elapsed % 60)
  return {
    type = "Column",
    mainAxis = "start",
    title = "Time since Jan 1, 2026",
    autoRefreshSeconds = 1,
    children = {
      { type = "Text", content = string.format("%sd %sh %sm %ss", d, h, m, s), style = "monospaceLarge" },
    }
  }
end
function on_event(state, name, args)
  local now = os.time()
  local elapsed = now - EPOCH
  if elapsed < 0 then elapsed = 0 end
  state.days = math.floor(elapsed / 86400)
  state.hours = math.floor((elapsed % 86400) / 3600)
  state.minutes = math.floor((elapsed % 3600) / 60)
  state.seconds = elapsed % 60
  return state
end

-- Exercise the complete widget lifecycle enough times for stable timings.
local state = init()
local tree
for i = 1, 10000 do
  state = on_event(state, "refresh", nil)
  tree = render(state)
end
return string.format("%d:%02d:%02d:%02d|%s|%s",
  state.days, state.hours, state.minutes, state.seconds,
  tree.type, tree.children[1].content)
''';

Future<void> main() => compareVms(
  'countdown widget',
  {'countdownWidget': _countdownWidget},
  prelude: deterministicPrelude,
  warmupRuns: 3,
  benchmarkRuns: 12,
);
