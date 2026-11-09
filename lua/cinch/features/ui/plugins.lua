-- The Plugins view: the list on the left and the detail pane on the right, which
-- follows the plugin under the cursor. While a first start installs, the same list
-- shows each plugin's install progress, then settles into its normal rows. This file
-- composes the list; rows.lua draws each row and details.lua the pane.
-- Nothing here changes state or calls vim.pack; the window hands in what it knows.

local canvas = require('cinch.features.ui.canvas')
local details = require('cinch.features.ui.details')
local rows = require('cinch.features.ui.rows')
local state = require('cinch.state')

local M = {}

---@class cinch.ui.Op an install, check, update or delete under way, or just ended
---@field kind cinch.OpKind
---@field total integer
---@field done integer
---@field current? string the plugin that last reported progress
---@field status table<string, 'queued'|'cloning'|'installed'|'failed'> each plugin's install status
---@field message? string how it ended, shown for a moment

---@class cinch.ui.Ctx
---@field folded table<string, true> sections folded shut
---@field filter? string only plugins whose name contains it
---@field tick integer spinner frame
---@field info table<string, vim.pack.PlugData|string> vim.pack.get per plugin, or why it is missing
---@field spec_lines table<string, integer> line of each plugin's spec in its file
---@field op? cinch.ui.Op set while an install, check, update or delete runs
---@field orphans? cinch.Orphan[] on disk, in no spec
---@field marked? table<string, true> plugins selected for an action
---@field profile_sort? 'time' the Profile view sorts siblings by time, not order
---@field profile_min? number the Profile view hides what took less, in ms

-- Drawn by rows.lua and details.lua, kept here under the names views and tests use.
M.sections = rows.sections
M.section_of = rows.section_of
M.icons = rows.icons
M.glyph = rows.glyph
M.kind_chip = rows.kind_chip
M.pane = details.pane

local mark, message = rows.mark, rows.message
local add_row, load_ms, pending, dependents = rows.add_row, rows.load_ms, rows.pending, rows.dependents

---@param ctx cinch.ui.Ctx
---@return cinch.Plugin[]
local function visible(ctx)
  return vim.tbl_filter(function(p)
    return not ctx.filter or p.name:lower():find(ctx.filter:lower(), 1, true) ~= nil
  end, state.yours())
end

--- Plugins with pending updates, taken from the section they would be in, with cinch
--- itself, which has a row only here. One that is working, failed or off stays there.
---@param plugins cinch.Plugin[]
---@param ctx cinch.ui.Ctx
---@return cinch.Plugin[]
local function with_updates(plugins, ctx)
  local out = {}
  for _, p in ipairs(state.list) do
    local key = M.section_of(p)
    local shown = p.self and (not ctx.filter or p.name:lower():find(ctx.filter:lower(), 1, true))
      or vim.list_contains(plugins, p)
    if shown and pending(p) and (key == 'loaded' or key == 'waiting') then
      out[#out + 1] = p
    end
  end
  return out
end

--- The Updates section, drawn only when it has something: plugins with pending updates,
--- then what is on disk in no spec.
---@param c cinch.ui.Canvas
---@param list cinch.Plugin[]
---@param orphans cinch.Orphan[]
---@param ctx cinch.ui.Ctx
local function updates_section(c, list, orphans, ctx)
  local count = #list + #orphans
  if count == 0 then
    return
  end
  local open = not ctx.folded.updates
  c:add({
    { (open and ' ▾ ' or ' ▸ ') .. 'Updates', 'CinchSection' },
    { (' (%d)'):format(count), 'CinchMuted' },
  }, { section = 'updates' })
  if not open then
    return
  end
  for _, p in ipairs(list) do
    rows.add_update_row(c, p, ctx.tick, ctx.marked and ctx.marked[p.name])
  end
  for _, o in ipairs(orphans) do
    c:add(
      { { ' · ' .. o.name .. ' ', 'CinchMuted' }, { 'not in specs', 'CinchWarn' } },
      { plugin = o.name, line_hl = ctx.marked and ctx.marked[o.name] and 'CinchMarked' or nil }
    )
  end
end

local graph_min = 6

-- What the progress line says for each operation; a delete only shows its ending.
local doing = { install = 'Installing plugins', check = 'Checking plugins', update = 'Updating plugins' }

--- Progress on one line: `Installing plugins (18/48) - yanky.nvim 37% ━━━━`, or how it ended.
---@param c cinch.ui.Canvas
---@param op cinch.ui.Op
local function op_header(c, op)
  if op.message or not doing[op.kind] then
    c:add({ { ' ' .. (op.message or ''), 'CinchTitle' } })
    return
  end
  local current = op.current and (' - ' .. op.current) or ''
  local left = (' %s (%d/%d)%s '):format(doing[op.kind], op.done, op.total, current)
  local percent = ('%d%% '):format(op.total > 0 and math.floor(op.done / op.total * 100) or 0)
  -- A long name gives way first, so the percent and the graph stay in view.
  local room = c.width - 1 - canvas.cells(percent) - graph_min
  if canvas.cells(left) > room then
    left = canvas.fit(left, room - 1) .. ' '
  end
  local graph = c.width - 1 - canvas.cells(left) - canvas.cells(percent)
  local line = { { left, 'CinchTitle' }, { percent, 'CinchMuted' } }
  c:add(vim.list_extend(line, canvas.pill(op.done, op.total, graph)))
end

-- Each install status: its mark (nil: the spinner), its color, the message.
local install_look = {
  queued = { '·', 'CinchMuted', 'queued' },
  cloning = { nil, 'CinchActive', 'cloning…' },
  installed = { '✓', 'CinchLoaded' },
  failed = { '✗', 'CinchFailed', 'could not install' },
  disabled = { '✕', 'CinchMuted' },
  on_disk = { '✓', 'CinchMuted' },
}

--- The list while a first start installs: every plugin with its install status,
--- in the same rows as the Plugins view, so they settle in place.
---@param c cinch.ui.Canvas
---@param ctx cinch.ui.Ctx
local function install_rows(c, ctx)
  local needed = dependents()
  local list = visible(ctx)
  -- Under a header like every other group of rows, and folds the same way.
  local open = not ctx.folded.installing
  c:add({
    { (open and ' ▾ ' or ' ▸ ') .. 'installing', 'CinchSection' },
    { ' ' .. #list, 'CinchMuted' },
  }, { section = 'installing' })
  for _, p in ipairs(open and list or {}) do
    local look = install_look[ctx.op.status[p.name] or (p.state == 'disabled' and 'disabled' or 'on_disk')]
    add_row(c, p, {
      mark = look[1] or canvas.spinner[ctx.tick % #canvas.spinner + 1],
      mark_hl = look[2],
      slowest = 0,
      needed_by = needed[p.name] or {},
      msg = look[3],
      msg_hl = look[2],
    })
  end
end

--- The list, `width` cells wide.
---@param width integer
---@param ctx cinch.ui.Ctx
---@return cinch.ui.Canvas
function M.list(width, ctx)
  local c = canvas.new(width)
  local plugins = visible(ctx)
  if ctx.op and ctx.op.kind == 'install' then
    op_header(c, ctx.op)
    install_rows(c, ctx)
    return c
  end
  if ctx.op then
    op_header(c, ctx.op)
  end
  local slowest = 0
  for _, p in ipairs(plugins) do
    slowest = math.max(slowest, load_ms(p) or 0)
  end
  local needed = dependents()
  local updating = with_updates(plugins, ctx)
  local by = {}
  for _, p in ipairs(plugins) do
    if not vim.list_contains(updating, p) then
      local key = M.section_of(p)
      by[key] = by[key] or {}
      table.insert(by[key], p)
    end
  end
  table.sort(by.loaded or {}, function(a, b)
    return (a.order or 0) < (b.order or 0)
  end)
  if ctx.filter then
    c:add({ { ' / ' .. ctx.filter, 'CinchKey' }, { ('  %d of %d'):format(#plugins, #state.yours()), 'CinchMuted' } })
  end
  local orphans = vim.tbl_filter(function(o)
    return not ctx.filter or o.name:lower():find(ctx.filter:lower(), 1, true) ~= nil
  end, ctx.orphans or {})
  updates_section(c, updating, orphans, ctx)
  for _, s in ipairs(M.sections) do
    local list = by[s.key]
    if list then
      local open = not ctx.folded[s.key]
      c:add({
        { (open and ' ▾ ' or ' ▸ ') .. s.title, 'CinchSection' },
        { ' ' .. #list, 'CinchMuted' },
      }, { section = s.key })
      if open then
        for _, p in ipairs(list) do
          local m, m_hl = mark(p, ctx.tick)
          local msg, msg_hl = message(p)
          add_row(c, p, {
            mark = m,
            mark_hl = m_hl,
            ms = load_ms(p),
            slowest = slowest,
            needed_by = needed[p.name] or {},
            up = pending(p),
            msg = msg,
            msg_hl = msg_hl,
            marked = ctx.marked and ctx.marked[p.name],
          })
        end
      end
    end
  end
  if #plugins + #orphans + #updating == 0 then
    c:add({ { ' no plugins match', 'CinchMuted' } })
  end
  return c
end

return M
