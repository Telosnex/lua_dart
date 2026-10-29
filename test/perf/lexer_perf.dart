// ignore_for_file: avoid_print
//
// lua_dardo_plus vs lua_dart: Compile of the lexer benchmark corpus.
// The Lua sources are those of the lua_dardo_plus benchmark of the same name.
//
// Run:
//   cd test/perf && dart run lexer_perf.dart

import 'vms.dart';

const _bigMod = r'''
local M = {}
local state
local counters = { renders = 0, events = 0 }

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local c = {}
  for k, val in pairs(v) do c[k] = deep_copy(val) end
  return c
end

local function is_blank(s)
  if s == nil then return true end
  return tostring(s):gsub("%s", "") == ""
end

function M.init()
  state = {
    items = {},
    next_id = 1,
    screen = "home",
    editor = nil,
    settings = { theme = "light", font_size = 14, notifications = true },
  }
  return state
end

local handlers = {}

function handlers.add_item(s, args)
  local t = {
    id = tostring(s.next_id),
    name = args.name or "",
    tags = deep_copy(args.tags or {}),
    done = false,
    created_at = os.time(),
  }
  table.insert(s.items, t)
  s.next_id = s.next_id + 1
end

function handlers.toggle_item(s, args)
  for _, item in ipairs(s.items) do
    if item.id == args.id then
      item.done = not item.done
      break
    end
  end
end

function handlers.delete_item(s, args)
  for i = #s.items, 1, -1 do
    if s.items[i].id == args.id then
      table.remove(s.items, i)
      break
    end
  end
end

function handlers.rename_item(s, args)
  for _, item in ipairs(s.items) do
    if item.id == args.id then
      item.name = args.value or item.name
      break
    end
  end
end

function handlers.open_editor(s, args)
  s.screen = "editor"
  s.editor = { id = args.id, draft = "", pristine = true }
end

function handlers.update_draft(s, args)
  if s.editor then
    s.editor.draft = args.value or ""
    s.editor.pristine = false
  end
end

function handlers.save_editor(s, args)
  if s.editor and not s.editor.pristine then
    for _, item in ipairs(s.items) do
      if item.id == s.editor.id then
        item.name = s.editor.draft
        break
      end
    end
  end
  s.editor = nil
  s.screen = "home"
end

function handlers.cancel_editor(s, args)
  s.editor = nil
  s.screen = "home"
end

function M.on_event(s, name, args)
  counters.events = counters.events + 1
  args = args or {}
  local h = handlers[name]
  if h then h(s, args) end
  return s
end

local function render_item(item)
  return {
    type = "ListTile",
    title = item.name,
    subtitle = item.done and "done" or "pending",
    event = { name = "toggle_item", arguments = { id = item.id } },
    menuItems = {
      { content = "Rename",  icon = "edit",   event = { name = "open_editor",  arguments = { id = item.id } } },
      { content = "Delete",  icon = "delete", event = { name = "delete_item",  arguments = { id = item.id } } },
    },
  }
end

local function render_home(s)
  local children = {}
  for _, item in ipairs(s.items or {}) do
    table.insert(children, render_item(item))
  end
  if #children == 0 then
    table.insert(children, { type = "Text", content = "No items yet." })
  end
  return { type = "Column", children = children }
end

local function render_editor(s)
  local e = s.editor or {}
  return {
    type = "Column",
    children = {
      { type = "Text", content = "Editing " .. (e.id or "?"), style = "headlineSmall" },
      { type = "TextInput", value = e.draft or "", event = { name = "update_draft" } },
      { type = "Row", children = {
        { type = "Button", content = "Save",   event = { name = "save_editor"   } },
        { type = "Button", content = "Cancel", event = { name = "cancel_editor" } },
      }},
    },
  }
end

function M.render(s)
  counters.renders = counters.renders + 1
  if s.screen == "editor" then
    return render_editor(s)
  end
  return render_home(s)
end

return M
''';

/// Heavy string literal content + comments — exercises the long-tail
/// lexer paths (readString, comment skip).
const _stringsAndComments = r'''
-- This is a long module-level comment describing the file.
-- It spans multiple short-comment lines so skipComment is hit lots.
-- Any performance work on the lexer should keep this cheap.

--[[
  And here is a block comment with some prose inside.
  The long-string open-bracket ambiguity is resolved via _skip_sep.
]]

local msgs = {
  greeting = "Hello, \"world\"!",
  farewell = 'So long, and thanks for all the fish.',
  path     = "/users/%s/docs/file.txt",
  tmpl     = "line1\nline2\tcol2\n",
  escaped  = "\\backslash and \\t tab and \\\" quote",
  raw      = [[
    This is a raw long string.
    No escapes are interpreted here.
  ]],
  unicode  = "\u{1F600} grinning face",
}

local function format_greeting(name)
  return msgs.greeting:gsub('world', name)
end

local function banner(title)
  local sep = string.rep("-", #title + 4)
  return sep .. "\n| " .. title .. " |\n" .. sep
end

return {
  format_greeting = format_greeting,
  banner = banner,
  msgs = msgs,
}
''';

/// Numeric literal heavy: integers, floats, hex, exponents — exercises
/// `readNumeral` through the main switch.
const _numericLiterals = r'''
local ints   = { 0, 1, 42, 1000, 1000000, 9223372036854775807 }
local floats = { 0.0, 1.0, 3.14, 2.71828, 1e10, 1.5e-3, 0.5E6 }
local hexes  = { 0x0, 0xFF, 0xDEADBEEF, 0x1p4, 0x1.8p1 }

local function sum_all(xs)
  local s = 0
  for _, x in ipairs(xs) do s = s + x end
  return s
end

local function weighted_avg(xs, ws)
  local total = 0
  local weight_sum = 0
  for i, x in ipairs(xs) do
    total = total + x * ws[i]
    weight_sum = weight_sum + ws[i]
  end
  return total / weight_sum
end

return sum_all(ints) + sum_all(floats) + sum_all(hexes)
       + weighted_avg({ 1, 2, 3, 4, 5 }, { 0.1, 0.2, 0.3, 0.2, 0.2 })
''';

Future<void> main() => compareCompile(
  'lexer',
  {
    'bigMod': _bigMod,
    'stringsAndComments': _stringsAndComments,
    'numericLiterals': _numericLiterals,
  },
  warmupRuns: 20,
  benchmarkRuns: 80,
);
