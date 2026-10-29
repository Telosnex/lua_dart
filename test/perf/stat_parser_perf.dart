// ignore_for_file: avoid_print
//
// lua_dardo_plus vs lua_dart: Compile of the stat parser benchmark corpus.
// The Lua sources are those of the lua_dardo_plus benchmark of the same name.
//
// Run:
//   cd test/perf && dart run stat_parser_perf.dart

import 'vms.dart';

/// Mod-style UI code: heavy on `function` + `local function` definitions,
/// nested `if/elseif/else`, table literals, and string concatenation.
const _modStyle = r'''
local M = {}

local function is_blank(s)
  if s == nil then return true end
  return tostring(s):gsub("%s", "") == ""
end

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local c = {}
  for k, val in pairs(v) do c[k] = deep_copy(val) end
  return c
end

function M.init()
  return {
    items = {},
    next_id = 1,
    screen = "home",
    editor = nil,
  }
end

function M.on_event(state, name, args)
  args = args or {}
  if name == "add_item" then
    local t = {
      id = tostring(state.next_id),
      name = args.name or "",
      done = false,
    }
    table.insert(state.items, t)
    state.next_id = state.next_id + 1
  elseif name == "toggle_item" then
    for _, item in ipairs(state.items) do
      if item.id == args.id then
        item.done = not item.done
        break
      end
    end
  elseif name == "delete_item" then
    for i = #state.items, 1, -1 do
      if state.items[i].id == args.id then
        table.remove(state.items, i)
        break
      end
    end
  elseif name == "open_editor" then
    state.screen = "editor"
    state.editor = { id = args.id, draft = "" }
  elseif name == "update_draft" then
    if state.editor then
      state.editor.draft = args.value or ""
    end
  elseif name == "save_editor" then
    if state.editor then
      for _, item in ipairs(state.items) do
        if item.id == state.editor.id then
          item.name = state.editor.draft
          break
        end
      end
      state.editor = nil
      state.screen = "home"
    end
  elseif name == "cancel_editor" then
    state.editor = nil
    state.screen = "home"
  end
  return state
end

function M.render(state)
  local children = {}
  if state.screen == "home" then
    for _, item in ipairs(state.items or {}) do
      table.insert(children, {
        type = "ListTile",
        title = item.name,
        subtitle = item.done and "done" or "pending",
        event = { name = "toggle_item", arguments = { id = item.id } },
      })
    end
  else
    table.insert(children, {
      type = "TextInput",
      value = state.editor and state.editor.draft or "",
      event = { name = "update_draft" },
    })
    table.insert(children, {
      type = "Button",
      content = "Save",
      event = { name = "save_editor" },
    })
  end
  return { type = "Column", children = children }
end

return M
''';

/// Numeric tight loops, for-num + for-in, arithmetic operators.
const _numeric = r'''
local function sum_to(n)
  local s = 0
  for i = 1, n do s = s + i end
  return s
end

local function fib(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)
end

local function product(xs)
  local p = 1
  for _, v in ipairs(xs) do
    if v == 0 then return 0 end
    p = p * v
  end
  return p
end

local a, b, c, d, e = 1, 2, 3, 4, 5
local nums = { a, b, c, d, e, a + b, b * c, c - d, d / e, e % a }
local acc = 0
for i, n in ipairs(nums) do
  if i % 2 == 0 then
    acc = acc + n
  elseif i % 3 == 0 then
    acc = acc - n
  else
    acc = acc * 2 + n
  end
end
return acc
''';

/// Many `local name` declarations without initializers — exercises the
/// const-empty-list fallback.
const _localDecls = r'''
local a, b, c
local d, e
local f
local g, h, i, j, k
local x
local y
local z
local p, q, r
local u, v, w
local aa, bb, cc, dd, ee, ff, gg, hh, ii, jj
a = 1 b = 2 c = 3 d = 4 e = 5 f = 6 g = 7 h = 8 i = 9 j = 10
k = a + b + c
x = d * e
y = f - g
z = h / i
p = j % k
q = p + x
r = y * z
u = q - r
v = u + 1
w = v * 2
aa, bb, cc = 1, 2, 3
dd, ee, ff = 4, 5, 6
gg, hh, ii, jj = 7, 8, 9, 10
return aa + bb + cc + dd + ee + ff + gg + hh + ii + jj
''';

/// Heavy `function name.path:method()` syntax — the Map-vs-Record
/// optimisation specifically targets this case.
const _funcNames = r'''
local M = {}
M.utils = {}
M.utils.string = {}
M.utils.tbl = {}
M.net = {}
M.net.http = {}

function M.utils.string:trim()  return self:gsub("^%s+", ""):gsub("%s+$", "") end
function M.utils.string.upper(s)  return s:upper() end
function M.utils.string.lower(s)  return s:lower() end
function M.utils.string:starts_with(p)  return self:sub(1, #p) == p end
function M.utils.string:ends_with(p)  return self:sub(-#p) == p end
function M.utils.tbl.size(t)  local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
function M.utils.tbl.keys(t)  local ks = {}; for k in pairs(t) do ks[#ks+1] = k end; return ks end
function M.utils.tbl.values(t)  local vs = {}; for _, v in pairs(t) do vs[#vs+1] = v end; return vs end
function M.utils.tbl:each(fn)  for k, v in pairs(self) do fn(k, v) end end
function M.utils.tbl:map(fn)  local o = {}; for k, v in pairs(self) do o[k] = fn(v) end; return o end
function M.net.http.get(url, opts)  return { url = url, opts = opts or {} } end
function M.net.http.post(url, body)  return { url = url, body = body } end
function M.net:configure(cfg)  self.cfg = cfg; return self end
function M:boot()  self.booted = true; return self end
function M:shutdown()  self.booted = false; return self end
return M
''';

/// Goto + label statements — rare but exercises those code paths.
/// Lua 5.3 requires `return` to be last in a block, so we use a result
/// variable instead of multiple returns.
const _gotoStyle = r'''
local function find(xs, target)
  local i = 1
  local result = nil
  ::loop::
  if i > #xs then goto done end
  if xs[i] == target then
    result = i
    goto done
  end
  i = i + 1
  goto loop
  ::done::
  return result
end

local x = find({ 1, 2, 3, 4, 5 }, 3)
return x
''';

Future<void> main() => compareCompile(
  'stat parser',
  {
    'modStyle': _modStyle,
    'numeric': _numeric,
    'localDecls': _localDecls,
    'funcNames': _funcNames,
    'gotoStyle': _gotoStyle,
  },
  warmupRuns: 20,
  benchmarkRuns: 80,
);
