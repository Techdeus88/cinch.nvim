-- The Stats and Log views. Stats is a dashboard of this session: a startup
-- timeline, counts, the slowest plugins and past sessions. Log is everything the
-- message feature kept, oldest first. Both read features through package.loaded,
-- so a view whose feature is off says so instead of failing.

local canvas = require('cinch.features.ui.canvas')
local state = require('cinch.state')

local fit, right, cells = canvas.fit, canvas.right, canvas.cells

local M = {}

---@param name string
---@return table?
local function feature(name)
  return package.loaded['cinch.features.' .. name]
end

---@param c cinch.ui.Canvas
---@param title string
---@param note? string
local function heading(c, title, note)
  c:add({ { ' ' .. title, 'CinchSection' }, { note and ('  ' .. note) or '', 'CinchMuted' } })
end

-- Stats -------------------------------------------------------------------------

-- Startup, split into what each part cost. Times are ms since Neovim started.
---@param stats table
---@return { [1]: string, [2]: number, [3]: string }[] label, ms, group
local function timeline(stats)
  local m, ph = stats.marks, stats.phases
  local cinch = 0
  for _, k in ipairs({ 'specs', 'install', 'init', 'now' }) do
    cinch = cinch + (ph[k] or 0)
  end
  local enter = m.uienter or m.vimenter
  local parts = {}
  local function part(label, ms, hl)
    if ms and ms > 0.05 then
      parts[#parts + 1] = { label, ms, hl }
    end
  end
  part('neovim', m.setup, 'CinchMuted')
  part('specs', ph.specs, 'CinchKey')
  part('install', ph.install, 'CinchWarn')
  part('init', ph.init, 'CinchKey')
  part('now', ph.now, 'CinchLoaded')
  if enter and m.setup then
    part('rest of startup', enter - m.setup - cinch, 'CinchMuted')
  end
  if m.later and enter then
    part('later', m.later - enter, 'CinchActive')
  end
  return parts
end

---@param c cinch.ui.Canvas
---@param stats table
local function draw_timeline(c, stats)
  local parts = timeline(stats)
  local enter = stats.marks.uienter or stats.marks.vimenter
  local total = 0
  for _, p in ipairs(parts) do
    total = total + p[2]
  end
  heading(
    c,
    'startup',
    enter and (canvas.ms(enter) .. ' to ' .. (stats.marks.uienter and 'UIEnter' or 'VimEnter')) or nil
  )
  if total == 0 then
    return c:add({ { '   not measured yet', 'CinchMuted' } })
  end
  local w = c.width - 4
  local bar, labels = { { '   ' } }, {}
  local used = 0
  for i, p in ipairs(parts) do
    -- At least one cell each, so a short phase still shows.
    local n = i == #parts and (w - used) or math.max(1, math.floor(p[2] / total * w + 0.5))
    n = math.max(0, math.min(n, w - used))
    used = used + n
    bar[#bar + 1] = { ('█'):rep(n), p[3] }
    labels[#labels + 1] = { ('%s %s'):format(p[1], canvas.ms(p[2])), p[3] }
  end
  c:add(bar)
  -- Labels wrap onto more lines rather than run past the edge.
  local line, len = { { '   ' } }, 3
  for _, l in ipairs(labels) do
    local sep = #line > 1 and '  ·  ' or ''
    if #line > 1 and len + cells(sep .. l[1]) > c.width - 1 then
      c:add(line)
      line, len, sep = { { '   ' } }, 3, ''
    end
    line[#line + 1] = { sep .. l[1], l[2] }
    len = len + cells(sep .. l[1])
  end
  c:add(line)
end

---@param c cinch.ui.Canvas
local function draw_counts(c)
  local by = {}
  for _, p in ipairs(state.list) do
    by[p.state] = (by[p.state] or 0) + 1
  end
  local updates = feature('updates')
  local chips = {
    { #state.list, 'plugins', 'CinchName' },
    { by.loaded or 0, 'loaded', 'CinchLoaded' },
    { (by.pending or 0) + (by.registered or 0), 'waiting', 'CinchWaiting' },
    { by.failed or 0, 'failed', 'CinchFailed' },
    { by.disabled or 0, 'disabled', 'CinchMuted' },
  }
  if updates then
    chips[#chips + 1] = { vim.tbl_count(updates.results), 'updates', 'CinchUpdate' }
  end
  local line = { { '  ' } }
  for _, chip in ipairs(chips) do
    line[#line + 1] = { (' %d '):format(chip[1]), chip[3] }
    line[#line + 1] = { chip[2] .. '   ', 'CinchMuted' }
  end
  c:add(line)
end

---@param c cinch.ui.Canvas
---@param stats table
local function draw_loaded_by(c, stats)
  local s = stats.summary()
  local kinds = vim.tbl_keys(s.loaded_by)
  if #kinds == 0 then
    return
  end
  table.sort(kinds, function(a, b)
    return s.loaded_by[a] > s.loaded_by[b] or (s.loaded_by[a] == s.loaded_by[b] and a < b)
  end)
  local line = { { '   ' } }
  for i, k in ipairs(kinds) do
    line[#line + 1] = { (i > 1 and '  ·  ' or '') .. k .. ' ', 'CinchKey' }
    line[#line + 1] = { tostring(s.loaded_by[k]) }
  end
  heading(c, 'loaded by')
  c:add(line)
end

---@param c cinch.ui.Canvas
---@param stats table
local function draw_slowest(c, stats)
  local list = {}
  for name, r in pairs(stats.plugins) do
    list[#list + 1] =
      { name = name, ms = r.packadd + r.config, packadd = r.packadd, config = r.config, reason = r.reason }
  end
  if #list == 0 then
    return
  end
  table.sort(list, function(a, b)
    return a.ms > b.ms
  end)
  local total = 0
  for _, r in ipairs(list) do
    total = total + r.ms
  end
  heading(c, 'slowest', ('%d loaded · %s in all'):format(#list, canvas.ms(total)))
  local name_w = 4
  for i = 1, math.min(8, #list) do
    name_w = math.max(name_w, cells(list[i].name))
  end
  name_w = math.min(name_w, 24)
  -- Bars take half the free width; what loaded the plugin takes the rest.
  local free = c.width - name_w - 16
  local bar_w = math.max(6, math.floor(free / 2))
  local why_w = math.max(8, free - bar_w)
  for i = 1, math.min(8, #list) do
    local r = list[i]
    local filled, empty = canvas.bar(r.ms, list[1].ms, bar_w)
    c:add({
      { '   ' .. fit(r.name, name_w) .. ' ', 'CinchName' },
      { filled, 'CinchBar' },
      { empty, 'CinchBarEmpty' },
      { right(canvas.ms(r.ms), 9) .. '  ', 'CinchMuted' },
      { fit(('%s · config %s'):format(r.reason, canvas.ms(r.config)), why_w), 'CinchMuted' },
    })
  end
end

---@param c cinch.ui.Canvas
---@param stats table
local function draw_history(c, stats)
  local history = stats.history()
  local now = stats.marks.uienter or stats.marks.vimenter
  if #history == 0 then
    heading(c, 'history', 'starts after this session ends')
    return
  end
  local recent = vim.list_slice(history, math.max(1, #history - math.min(c.width - 8, 60) + 1))
  local values = vim.tbl_map(function(h)
    return h.startup or 0
  end, recent)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  heading(c, 'history', ('last %d session%s'):format(#recent, #recent == 1 and '' or 's'))
  c:add({ { '   ' .. canvas.spark(values), 'CinchActive' } })
  c:add({
    {
      ('   median %s · best %s · worst %s%s'):format(
        canvas.ms(sorted[math.ceil(#sorted / 2)]),
        canvas.ms(sorted[1]),
        canvas.ms(sorted[#sorted]),
        now and (' · this session ' .. canvas.ms(now)) or ''
      ),
      'CinchMuted',
    },
  })
end

---@param c cinch.ui.Canvas
---@param stats table
local function draw_disk(c, stats)
  local d = stats.disk
  heading(c, 'this session')
  c:add({
    {
      ('   installed %d · updated %d · deleted %d · %d vim.pack call%s'):format(
        d.install,
        d.update,
        d.delete,
        #stats.ops,
        #stats.ops == 1 and '' or 's'
      ),
      'CinchMuted',
    },
  })
end

--- The Stats view, `width` cells wide.
---@param width integer
---@return cinch.ui.Canvas
function M.stats(width)
  local c = canvas.new(width)
  local stats = feature('stats')
  if not stats then
    c:add({ { ' the stats feature is off', 'CinchMuted' } })
    return c
  end
  draw_timeline(c, stats)
  c:blank()
  draw_counts(c)
  c:blank()
  draw_loaded_by(c, stats)
  c:blank()
  draw_slowest(c, stats)
  c:blank()
  draw_history(c, stats)
  c:blank()
  draw_disk(c, stats)
  return c
end

-- Log ---------------------------------------------------------------------------

local levels = vim.log.levels
local level_look = {
  [levels.ERROR] = { '✗', 'CinchFailed' },
  [levels.WARN] = { '!', 'CinchWarn' },
}

--- The Log view, `width` cells wide: oldest first, so the newest is at the bottom.
---@param width integer
---@param ctx { filter?: string }
---@return cinch.ui.Canvas
function M.log(width, ctx)
  local c = canvas.new(width)
  local messages = feature('messages')
  if not messages then
    c:add({ { ' the messages feature is off', 'CinchMuted' } })
    return c
  end
  local shown = vim.tbl_filter(function(m)
    return not ctx.filter or m.msg:lower():find(ctx.filter:lower(), 1, true) ~= nil
  end, messages.log)
  if ctx.filter then
    c:add({ { ' / ' .. ctx.filter, 'CinchKey' }, { ('  %d of %d'):format(#shown, #messages.log), 'CinchMuted' } })
  end
  if #shown == 0 then
    c:add({ { ' nothing logged yet', 'CinchMuted' } })
    return c
  end
  local text_w = width - 22
  for _, m in ipairs(shown) do
    local look = level_look[m.level] or { '·', 'CinchMuted' }
    local lines = {}
    for _, line in ipairs(vim.split(m.msg, '\n', { trimempty = true })) do
      vim.list_extend(lines, canvas.wrap(line, text_w))
    end
    c:add({
      { ' ' .. os.date('%H:%M:%S', m.time) .. ' ', 'CinchMuted' },
      { look[1] .. ' ', look[2] },
      { fit(m.source, 9), 'CinchKey' },
      { lines[1] or '', look[2] ~= 'CinchMuted' and look[2] or nil },
    })
    for i = 2, #lines do
      c:add({ { (' '):rep(21) .. lines[i], 'CinchMuted' } })
    end
  end
  return c
end

return M
