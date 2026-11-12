-- One plugin's row in the Plugins view: its status light, name, load time and bar,
-- how it loads as chips, pending updates, and a message, cut to the list's width.
-- Also what those are drawn from: the sections a plugin can be in, and its icons.
-- Draws into a canvas and reads state; changes nothing.

local canvas = require('cinch.features.ui.canvas')
local state = require('cinch.state')

local M = {}

---@param name string
---@return table?
local function feature(name)
  return package.loaded['cinch.features.' .. name]
end

-- Sections, in the order they are shown: what is happening now first, so it is in
-- view while it changes, then what went wrong. section_of() puts a plugin in one,
-- so a loaded plugin that is updating is "working". Only `titled` ones get a title in the
-- list: the header counts the rest.
M.sections = {
  { key = 'working', title = 'working', hl = 'CinchActive', titled = true },
  { key = 'failed', title = 'failed', hl = 'CinchFailed' },
  { key = 'loaded', title = 'loaded', hl = 'CinchLoaded' },
  { key = 'waiting', title = 'waiting', hl = 'CinchWaiting' },
  { key = 'disabled', title = 'disabled', hl = 'CinchMuted' },
}

-- Disk work that moves a plugin into `working`. A check, an update or a delete leaves
-- it where it is, saying so on its row, so the list does not reshuffle.
local works = { installing = true, building = true }

---@param p cinch.Plugin
---@return string section key
function M.section_of(p)
  if works[p.activity] or p.state == 'loading' then
    return 'working'
  elseif p.state == 'failed' then
    return 'failed'
  elseif p.state == 'loaded' then
    return 'loaded'
  elseif p.state == 'disabled' then
    return 'disabled'
  end
  return 'waiting'
end

local marks = { failed = '✗', loaded = '●', waiting = '○', disabled = '✕' }
M.marks = marks

--- Nerd Font icons for how a plugin loads. `ui.icons` in setup() replaces any of
--- them; `trigger` is for a trigger of your own.
M.icons = {
  now = '\u{f135}',
  later = '\u{f017}',
  event = '\u{f0e7}',
  ft = '\u{f15b}',
  cmd = '\u{f120}',
  keys = '\u{f11c}',
  dep = '\u{f487}',
  trigger = '\u{f013}',
  off = '\u{f011}',
}

--- Why a plugin is off, as its spec says it: `cond = false`, or `cond() returned false`
--- when the field is a function. A dependency off with its parents has no spec to quote.
---@param p cinch.Plugin
---@return string?
function M.off_reason(p)
  if p.reason == 'unneeded' then
    return nil
  end
  local k = p.reason == 'cond' and 'cond' or 'enabled'
  return type(p.data[k]) == 'function' and k .. '() returned false' or k .. ' = false'
end

---@param name string
---@return string
local function glyph(name)
  local ui = package.loaded['cinch.features.ui']
  local own = ui and ui.opts.icons
  return own and own[name] or M.icons[name] or M.icons.trigger
end
M.glyph = glyph

--- The status light left of the name: lit when loaded, a spinner while working.
---@param p cinch.Plugin
---@param tick integer spinner frame
---@return string mark, string group
local function mark(p, tick)
  local sec = M.section_of(p)
  if sec == 'working' or p.activity then
    return canvas.spinner[tick % #canvas.spinner + 1], 'CinchActive'
  end
  for _, s in ipairs(M.sections) do
    if s.key == sec then
      return marks[sec], s.hl
    end
  end
  return '·', 'CinchMuted'
end

---@alias cinch.ui.Item { [1]: string, [2]?: string }[] chunks that stay together

--- A chip in the kind's own color: its icon and its name on a square shade, one
--- space of padding each side, ` cmd `.
---@param kind string now, later, event, ft, cmd, keys, dep, off, or your own
---@return cinch.ui.Item
function M.kind_chip(kind)
  return { { glyph(kind) .. ' ' .. kind, select(2, canvas.kind_hl(kind)) } }
end

-- Triggers in this order, then any of your own by name.
local trigger_order = { event = 1, ft = 2, cmd = 3, keys = 4 }

--- A trigger plugin's triggers, one item per type: its icon and type, then its
--- values. The value that loaded it sits on a chip.
---@param p cinch.Plugin
---@return cinch.ui.Item[]
local function trigger_items(p)
  local kinds = vim.tbl_keys(p.triggers or {})
  table.sort(kinds, function(a, b)
    local x, y = trigger_order[a] or 9, trigger_order[b] or 9
    return x ~= y and x < y or a < b
  end)
  local out = {}
  for _, kind in ipairs(kinds) do
    local item = M.kind_chip(kind)
    for _, v in ipairs(p.triggers[kind]) do
      local value = type(v) == 'table' and v.lhs or tostring(v)
      -- What the handler says when it fires: 'event FileType lua', 'cmd Foo', 'keys <lhs>'.
      local fired_as = ((kind == 'event' or kind == 'ft') and 'event' or kind) .. ' ' .. value
      local shown = kind == 'ft' and value:gsub('^FileType ', '') or value
      local fired = p.reason == fired_as and p.state ~= 'pending'
      item[#item + 1] = { ' ' }
      item[#item + 1] = { shown, fired and 'CinchFired' or 'CinchTriggerValue' }
    end
    out[#out + 1] = item
  end
  return out
end

--- How a plugin loads: a chip for now and later, a chip per trigger type with its
--- values after it, and for a plugin that is only a dependency a dep chip and the
--- plugins that need it. A plugin of its own that others also need says how many.
---@param p cinch.Plugin
---@param needed_by string[]
---@return cinch.ui.Item[]
local function load_items(p, needed_by)
  if p.dep_only then
    local item = M.kind_chip('dep')
    item[#item + 1] = { ' ' .. table.concat(needed_by, ', '), 'CinchMuted' }
    return { item }
  end
  local items = p.when == 'trigger' and trigger_items(p) or { M.kind_chip(p.when) }
  if #needed_by > 0 then
    local _, text = canvas.kind_hl('dep')
    items[#items + 1] = { { glyph('dep') .. ' ' .. #needed_by, text } }
  end
  return items
end

--- Who needs each plugin: name -> the plugins that list it in deps.
---@return table<string, string[]>
local function dependents()
  local out = {}
  for _, p in ipairs(state.list) do
    for _, d in ipairs(p.deps) do
      out[d] = out[d] or {}
      table.insert(out[d], p.name)
    end
  end
  return out
end

--- The row's message: only when there is something to say.
---@param p cinch.Plugin
---@return string? text, string? group
local function message(p)
  local sec = M.section_of(p)
  if sec == 'failed' then
    return vim.split(p.err or 'failed', '\n')[1], 'CinchFailed'
  elseif sec == 'working' then
    -- A build shows what it is printing now.
    local log = p.activity == 'building' and p.build_log or {}
    if #log > 0 then
      return log[#log], 'CinchMuted'
    end
    return (p.activity or 'loading') .. '…', 'CinchActive'
  elseif p.activity then
    return p.activity .. '…', 'CinchActive'
  elseif sec == 'disabled' then
    return M.off_reason(p), 'CinchMuted'
  elseif p.deleted then
    return 'deleted', 'CinchWarn'
  end
end

---@param p cinch.Plugin
---@return number? ms packadd plus config
local function load_ms(p)
  local stats = feature('stats')
  local s = stats and stats.plugins[p.name]
  return s and (s.packadd + s.config)
end

---@param p cinch.Plugin
---@return integer? pending commits
local function pending(p)
  local updates = feature('updates')
  local u = updates and updates.results[p.name]
  return u and #u.commits
end

---@param items cinch.ui.Item[]
---@return { [1]: string, [2]?: string }[]
local function join(items)
  local out = {}
  for i, item in ipairs(items) do
    if i > 1 then
      out[#out + 1] = { ' ' }
    end
    vim.list_extend(out, item)
  end
  return out
end

---@class cinch.ui.Row
---@field mark string
---@field mark_hl string
---@field ms? number load time, for the time and the bar
---@field slowest number the bar's full length
---@field needed_by string[]
---@field up? integer pending commits
---@field msg? string
---@field msg_hl? string
---@field marked? boolean selected for an action: the row gets a shade

--- One plugin's line, each part right after the last, cut at the list's edge:
---   ● <name> (<load time>) <bar> <how it loads> <↑updates> <message>
---@param c cinch.ui.Canvas
---@param p cinch.Plugin
---@param r cinch.ui.Row
local function add_row(c, p, r)
  local off = p.state == 'disabled'
  local items = {
    { { ' ' .. r.mark, r.mark_hl } },
    { { p.name, off and 'CinchOffName' or p.dep_only and 'CinchDepName' or 'CinchName' } },
  }
  if r.ms then
    items[#items + 1] = { { '(' .. canvas.ms(r.ms) .. ')', 'CinchMuted' } }
    items[#items + 1] = canvas.pill(r.ms, r.slowest, 6)
  end
  -- Off: its own chip in place of how it loads, which it never arms. A dependency off
  -- with its parents keeps its dep chip, which names them.
  local off_chip = off and p.reason ~= 'unneeded'
  vim.list_extend(items, off_chip and { M.kind_chip('off') } or load_items(p, r.needed_by))
  if r.up then
    items[#items + 1] = { { '↑' .. r.up, 'CinchUpdate' } }
  end
  if r.msg then
    items[#items + 1] = { { r.msg, r.msg_hl } }
  end
  c:add(canvas.clip(join(items), c.width - 1), { plugin = p.name, line_hl = r.marked and 'CinchMarked' or nil })
end

--- A row that asks about its plugin: `● Delete <name> Yes (y) or No (n)`.
---@param c cinch.ui.Canvas
---@param name string
---@param verb string
---@param m string its mark
---@param m_hl? string
local function add_ask_row(c, name, verb, m, m_hl)
  local items = {
    { { ' ' .. m, m_hl } },
    { { verb .. ' ' .. name, 'CinchWarn' } },
    { { 'Yes (y) or No (n)', 'CinchKey' } },
  }
  c:add(canvas.clip(join(items), c.width - 1), { plugin = name })
end

--- A row in the Updates section: `● <name> 2 commits`.
---@param c cinch.ui.Canvas
---@param p cinch.Plugin
---@param tick integer spinner frame
---@param marked? boolean
local function add_update_row(c, p, tick, marked)
  local m, m_hl = mark(p, tick)
  local n = pending(p) or 0
  local status = p.activity and { p.activity .. '…', 'CinchActive' }
    or { ('%d commit%s'):format(n, n == 1 and '' or 's'), 'CinchUpdate' }
  local items = {
    { { ' ' .. m, m_hl } },
    { { p.name, 'CinchName' } },
    { status },
  }
  c:add(canvas.clip(join(items), c.width - 1), { plugin = p.name, line_hl = marked and 'CinchMarked' or nil })
end

M.feature = feature
M.mark = mark
M.message = message
M.trigger_items = trigger_items
M.join = join
M.load_ms = load_ms
M.pending = pending
M.dependents = dependents
M.add_row = add_row
M.load_items = load_items
M.add_update_row = add_update_row
M.add_ask_row = add_ask_row

return M
