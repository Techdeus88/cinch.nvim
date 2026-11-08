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

---@class cinch.ui.Install
---@field total integer
---@field done integer
---@field started integer hrtime
---@field status table<string, 'queued'|'cloning'|'installed'|'failed'>
---@field message? string what is happening now, when not one plugin

---@class cinch.ui.Ctx
---@field folded table<string, true> sections folded shut
---@field filter? string only plugins whose name contains it
---@field tick integer spinner frame
---@field info table<string, vim.pack.PlugData|string> vim.pack.get per plugin, or why it is missing
---@field spec_lines table<string, integer> line of each plugin's spec in its file
---@field install? cinch.ui.Install set while a first start installs
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

local feature, mark, message = rows.feature, rows.mark, rows.message
local add_row, load_ms, pending, dependents = rows.add_row, rows.load_ms, rows.pending, rows.dependents

---@param ctx cinch.ui.Ctx
---@return cinch.Plugin[]
local function visible(ctx)
  return vim.tbl_filter(function(p)
    return not ctx.filter or p.name:lower():find(ctx.filter:lower(), 1, true) ~= nil
  end, state.yours())
end

--- cinch itself has no row; a pending update of it gets one line above the rest,
--- which selects it like a plugin, so the pane lists its commits and `u` applies it.
---@param c cinch.ui.Canvas
local function own_update(c)
  local updates = feature('updates')
  for _, p in ipairs(state.list) do
    local u = p.self and updates and updates.results[p.name]
    if u then
      c:add({
        { ' ↑ ', 'CinchUpdate' },
        { 'cinch', 'CinchName' },
        { (' has %d new commit%s · u updates it'):format(#u.commits, #u.commits == 1 and '' or 's'), 'CinchMuted' },
      }, { plugin = p.name })
      c:blank()
    end
  end
end

--- Install progress for a first start: one line of status and a thin bar across the list.
---@param c cinch.ui.Canvas
---@param install cinch.ui.Install
local function install_header(c, install)
  local secs = (vim.uv.hrtime() - install.started) / 1e9
  local msg = install.message
    or ('Setting up %d plugin%s · %d of %d · %.1fs'):format(
      install.total,
      install.total == 1 and '' or 's',
      install.done,
      install.total,
      secs
    )
  c:add({ { ' ' .. msg, 'CinchTitle' } })
  c:add(vim.list_extend({ { ' ' } }, canvas.pill(install.done, install.total, c.width - 3)))
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
    local look = install_look[ctx.install.status[p.name] or (p.state == 'disabled' and 'disabled' or 'on_disk')]
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
  if ctx.install then
    install_header(c, ctx.install)
    install_rows(c, ctx)
    return c
  end
  local slowest = 0
  for _, p in ipairs(plugins) do
    slowest = math.max(slowest, load_ms(p) or 0)
  end
  local needed = dependents()
  local by = {}
  for _, p in ipairs(plugins) do
    local key = M.section_of(p)
    by[key] = by[key] or {}
    table.insert(by[key], p)
  end
  table.sort(by.loaded or {}, function(a, b)
    return (a.order or 0) < (b.order or 0)
  end)
  own_update(c)
  if ctx.filter then
    c:add({ { ' / ' .. ctx.filter, 'CinchKey' }, { ('  %d of %d'):format(#plugins, #state.yours()), 'CinchMuted' } })
  end
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
  local orphans = vim.tbl_filter(function(o)
    return not ctx.filter or o.name:lower():find(ctx.filter:lower(), 1, true) ~= nil
  end, ctx.orphans or {})
  if #orphans > 0 then
    local open = not ctx.folded.orphans
    c:add({
      { (open and ' ▾ ' or ' ▸ ') .. 'not in your specs', 'CinchSection' },
      { ' ' .. #orphans, 'CinchMuted' },
    }, { section = 'orphans' })
    for _, o in ipairs(open and orphans or {}) do
      c:add(
        { { ' · ' .. o.name .. ' ', 'CinchMuted' }, { 'on disk · d deletes it', 'CinchWarn' } },
        { plugin = o.name, line_hl = ctx.marked and ctx.marked[o.name] and 'CinchMarked' or nil }
      )
    end
  end
  if #plugins + #orphans == 0 then
    c:add({ { ' no plugins match', 'CinchMuted' } })
  end
  return c
end

return M
