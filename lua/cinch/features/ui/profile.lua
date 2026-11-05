-- The Profile view: where this session's time went, as a tree. cinch's phases hold the
-- plugins they loaded, a plugin holds its dependencies and the files it sourced, and
-- the plugin/ files Neovim sourced at startup sit under their owner. Siblings run in
-- the order they began, or by time with <C-s>; <C-f> hides what took less than a
-- threshold, and / keeps what matches the filter.

local canvas = require('cinch.features.ui.canvas')
local rows = require('cinch.features.ui.rows')

local fit, right, cells = canvas.fit, canvas.right, canvas.cells

local M = {}

local look = {
  group = 'CinchSection',
  owner = 'CinchName',
  phase = 'CinchKey',
  plugin = 'CinchName',
  file = 'CinchMuted',
}

--- The kind of thing that loaded a plugin, for its icon: now, later, event, ft, cmd, keys, dep.
---@param reason? string
---@return string
local function kind(reason)
  local k = (reason or ''):match('^(%S+)') or 'trigger'
  if k == 'event' and reason:find('^event FileType ') then
    return 'ft'
  end
  return k
end

--- Whether the node, or anything under it, matches the filter.
---@param n cinch.stats.Node
---@param text string lower case
---@return boolean
local function matches(n, text)
  if n.label:lower():find(text, 1, true) or n.name:lower():find(text, 1, true) then
    return true
  end
  for _, c in ipairs(n.children) do
    if matches(c, text) then
      return true
    end
  end
  return false
end

---@param list cinch.stats.Node[]
---@param by_time boolean
---@return cinch.stats.Node[]
local function sorted(list, by_time)
  if not by_time then
    return list
  end
  list = vim.list_slice(list)
  table.sort(list, function(a, b)
    return a.ms > b.ms
  end)
  return list
end

--- What follows a plugin's name: what loaded it and its own packadd and config time.
---@param n cinch.stats.Node
---@param stats table
---@return string
local function plugin_note(n, stats)
  local r = stats.plugins[n.name]
  local parts = { n.reason }
  if r then
    parts[#parts + 1] = ('packadd %s · config %s'):format(canvas.ms(r.packadd), canvas.ms(r.config))
  end
  if n.failed then
    parts[#parts + 1] = 'failed'
  end
  return '  ' .. table.concat(parts, ' · ')
end

---@class cinch.ui.ProfileDraw
---@field c cinch.ui.Canvas
---@field ctx cinch.ui.Ctx
---@field stats table
---@field max number the largest top-level time, for the bars
---@field min number hide what took less, in ms
---@field filter? string lower case
---@field by_time boolean
---@field label_w integer
---@field bar_w integer

---@param d cinch.ui.ProfileDraw
---@param n cinch.stats.Node
---@param depth integer
---@param parent string the parent's fold key
local function draw(d, n, depth, parent)
  if n.ms < d.min and n.kind ~= 'group' then
    return
  end
  if d.filter and not matches(n, d.filter) then
    return
  end
  local key = ('profile:%s/%s@%.3f'):format(parent, n.name, n.start)
  local folded = d.ctx.folded[key]
  local has = #n.children > 0
  local marker = has and (folded and '▸ ' or '▾ ') or '  '
  local line = { { (' '):rep(1 + depth * 2) .. marker, 'CinchMuted' } }
  local used = cells(line[1][1])
  if n.kind == 'plugin' then
    local k = kind(n.reason)
    local _, text = canvas.kind_hl(k)
    line[#line + 1] = { rows.glyph(k) .. ' ', text }
    used = used + cells(line[#line][1])
  end
  local label = n.label
  local note = n.kind == 'plugin' and plugin_note(n, d.stats) or ''
  local w = math.max(4, d.label_w - used)
  local hl = n.failed and 'CinchFailed' or look[n.kind]
  if cells(label) >= w then
    line[#line + 1] = { fit(label, w), hl }
  else
    line[#line + 1] = { label, hl }
    line[#line + 1] = { fit(note, w - cells(label)), 'CinchMuted' }
  end
  line[#line + 1] = { right(canvas.ms(n.ms), 9), depth == 0 and 'CinchName' or 'CinchMuted' }
  if d.bar_w > 0 then
    line[#line + 1] = { '  ' }
    vim.list_extend(line, canvas.pill(n.ms, d.max, d.bar_w))
  end
  d.c:add(line, has and { section = key } or nil)
  if has and not folded then
    for _, child in ipairs(sorted(n.children, d.by_time)) do
      draw(d, child, depth + 1, key)
    end
  end
end

--- The moments of startup in the order they happened, each with the time since Neovim
--- started and since the one before.
---@param c cinch.ui.Canvas
---@param m table the stats marks
local function draw_marks(c, m)
  local list = {}
  for _, mark in ipairs({
    { 'VimEnter', m.vimenter },
    { 'UIEnter', m.uienter },
    { 'CinchStart', m.setup },
    { 'CinchDone', m.done },
    { 'later done', m.later },
  }) do
    if mark[2] then
      list[#list + 1] = mark
    end
  end
  if #list == 0 then
    return
  end
  table.sort(list, function(a, b)
    return a[2] < b[2]
  end)
  local prev
  for _, mark in ipairs(list) do
    c:add({
      { '   ' .. fit(mark[1], 12), 'CinchMuted' },
      { canvas.ms(mark[2]), 'CinchName' },
      { prev and (' (+' .. canvas.ms(mark[2] - prev) .. ')') or '', 'CinchMuted' },
    })
    prev = mark[2]
  end
  c:blank()
end

--- The Profile view, `width` cells wide.
---@param width integer
---@param ctx cinch.ui.Ctx
---@return cinch.ui.Canvas
function M.list(width, ctx)
  local c = canvas.new(width)
  local stats = rows.feature('stats')
  if not stats then
    c:add({ { ' the stats feature is off', 'CinchMuted' } })
    return c
  end
  if not stats.opts.profile then
    c:add({ { ' profiling is off: stats = { profile = true } turns it on', 'CinchMuted' } })
    return c
  end
  local tree = stats.profile()
  local by_time = ctx.profile_sort == 'time'
  local min = ctx.profile_min or 0
  local notes = { by_time and 'by time' or 'in order' }
  if min > 0 then
    notes[#notes + 1] = 'over ' .. canvas.ms(min)
  end
  c:add({ { ' profile', 'CinchSection' }, { '  ' .. table.concat(notes, ' · '), 'CinchMuted' } })
  if ctx.filter then
    c:add({ { ' / ' .. ctx.filter, 'CinchKey' } })
  end
  c:blank()
  draw_marks(c, stats.marks)
  if #tree == 0 then
    c:add({ { '   nothing timed yet', 'CinchMuted' } })
    return c
  end
  local max = 0
  for _, n in ipairs(tree) do
    max = math.max(max, n.ms)
  end
  -- Bars only when there is room for them beside the names.
  local bar_w = width >= 70 and math.min(20, math.floor(width / 6)) or 0
  local d = {
    c = c,
    ctx = ctx,
    stats = stats,
    max = max,
    min = min,
    filter = ctx.filter and ctx.filter:lower(),
    by_time = by_time,
    label_w = width - 1 - 9 - (bar_w > 0 and bar_w + 2 or 0),
    bar_w = bar_w,
  }
  for _, n in ipairs(sorted(tree, by_time)) do
    local before = #c.lines
    draw(d, n, 0, '')
    if #c.lines > before then
      c:blank()
    end
  end
  return c
end

return M
