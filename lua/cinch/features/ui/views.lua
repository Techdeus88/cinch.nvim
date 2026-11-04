-- What the cinch window shows. Each view turns cinch's state into lines,
-- highlights, and the plugin each line belongs to. Nothing here changes state
-- or calls vim.pack; the window hands in what it fetched.

local state = require('cinch.state')

local M = {}

---@param name string
---@return table?
local function feature(name)
  return package.loaded['cinch.features.' .. name]
end

-- Highlight groups, linked to standard ones so every colorscheme styles them.
M.highlights = {
  CinchTitle = 'Title',
  CinchSection = 'Label',
  CinchMuted = 'Comment',
  CinchKey = 'Special',
  CinchTab = 'TabLineSel',
  CinchLoaded = 'DiagnosticOk',
  CinchPending = 'DiagnosticHint',
  CinchFailed = 'DiagnosticError',
  CinchWarn = 'DiagnosticWarn',
  CinchActive = 'DiagnosticInfo',
  CinchUpdate = 'DiagnosticWarn',
}

local icons = { loaded = '●', loading = '◐', pending = '○', registered = '·', failed = '✗', disabled = '–' }
local icon_hl = {
  loaded = 'CinchLoaded',
  loading = 'CinchActive',
  pending = 'CinchPending',
  registered = 'CinchMuted',
  failed = 'CinchFailed',
  disabled = 'CinchMuted',
}

-- Canvas ------------------------------------------------------------------------

---@class cinch.ui.Canvas
---@field lines string[]
---@field hls { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] 0-based line, start col, end col, group
---@field rows table<integer, string> 1-based line -> plugin name
---@field width integer
local Canvas = {}
Canvas.__index = Canvas

---@param width integer
---@return cinch.ui.Canvas
function M.canvas(width)
  return setmetatable({ lines = {}, hls = {}, rows = {}, width = width }, Canvas)
end

--- Add one line from { text, group? } chunks; `name` makes it that plugin's line.
---@param chunks { [1]: string, [2]?: string }[]
---@param name? string
function Canvas:add(chunks, name)
  local parts, col = {}, 0
  for _, c in ipairs(chunks) do
    local text = c[1] or ''
    if c[2] and #text > 0 then
      self.hls[#self.hls + 1] = { #self.lines, col, col + #text, c[2] }
    end
    parts[#parts + 1] = text
    col = col + #text
  end
  self.lines[#self.lines + 1] = table.concat(parts)
  if name then
    self.rows[#self.lines] = name
  end
end

function Canvas:blank()
  self.lines[#self.lines + 1] = ''
end

--- Several lines of text under one indent, in one group.
---@param text string
---@param indent string
---@param hl? string
function Canvas:block(text, indent, hl)
  for _, line in ipairs(vim.split(text, '\n')) do
    self:add({ { indent .. line, hl } })
  end
end

-- Formatting --------------------------------------------------------------------

---@param s string
---@param w integer
---@return string
local function pad(s, w)
  return s .. (' '):rep(math.max(1, w - vim.fn.strdisplaywidth(s)))
end

---@param ms? number
---@return string
local function ms_text(ms)
  return ms and ('%.1fms'):format(ms) or ''
end

---@param t integer os.time()
---@return string
local function ago(t)
  local s = os.time() - t
  if s < 60 then
    return s .. 's ago'
  end
  return s < 3600 and ('%dm ago'):format(s / 60) or ('%dh ago'):format(s / 3600)
end

--- A value as Lua, with functions shown as where they are defined.
---@param v any
---@return string
local function inspect(v)
  local text = vim.inspect(v, {
    process = function(item)
      if type(item) == 'function' then
        local info = debug.getinfo(item, 'S')
        return ('<function %s:%d>'):format(vim.fs.basename(info.short_src), info.linedefined)
      end
      return item
    end,
  })
  -- Shown bare, so a function never reads as a string.
  return (text:gsub('"(<function [^"]+>)"', '%1'))
end

--- What a plugin waits on, or what loaded it.
---@param p cinch.Plugin
---@return string
local function why(p)
  if p.state == 'loaded' or p.state == 'failed' or p.state == 'disabled' then
    return p.reason and ('by ' .. p.reason) or ''
  end
  if p.when ~= 'trigger' then
    return p.when
  end
  local parts = {}
  for name, values in pairs(p.triggers or {}) do
    local shown = vim.tbl_map(function(v)
      return type(v) == 'table' and v.lhs or (tostring(v):gsub('^FileType ', ''))
    end, values)
    parts[#parts + 1] = name .. ' ' .. table.concat(shown, ', ')
  end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, ' · ') or 'with its dependents'
end

-- Header ------------------------------------------------------------------------

M.tabs = { 'plugins', 'stats', 'log' }

---@param c cinch.ui.Canvas
---@param view string
local function header(c, view)
  local counts = {}
  for _, p in ipairs(state.list) do
    counts[p.state] = (counts[p.state] or 0) + 1
  end
  local stats = feature('stats')
  local startup = stats and (stats.marks.uienter or stats.marks.vimenter)
  local chunks = { { ' cinch ', 'CinchTitle' }, { ('  %d plugins'):format(#state.list), 'CinchMuted' } }
  for _, s in ipairs({ 'loaded', 'pending', 'failed', 'disabled' }) do
    if counts[s] then
      chunks[#chunks + 1] = { ('  %s %d %s'):format(icons[s], counts[s], s), icon_hl[s] }
    end
  end
  if startup then
    chunks[#chunks + 1] = { ('  startup %s'):format(ms_text(startup)), 'CinchMuted' }
  end
  c:add(chunks)
  local tabs = { { ' ' } }
  for _, t in ipairs(M.tabs) do
    tabs[#tabs + 1] = { (' %s '):format(t), t == view and 'CinchTab' or 'CinchMuted' }
    tabs[#tabs + 1] = { ' ' }
  end
  tabs[#tabs + 1] = { '   <Tab> next view  = size  q close', 'CinchMuted' }
  c:add(tabs)
  c:blank()
end

-- Plugins -----------------------------------------------------------------------

---@class cinch.ui.Ctx
---@field expanded table<string, true> plugins showing their details
---@field info table<string, vim.pack.PlugData|string> vim.pack.get per plugin, or why it is missing

---@param c cinch.ui.Canvas
---@param p cinch.Plugin
---@param ctx cinch.ui.Ctx
local function details(c, p, ctx)
  local ind = '      '
  if p.err then
    c:add({ { ind .. 'error', 'CinchFailed' } })
    c:block(p.err, ind .. '  ', 'CinchFailed')
  end
  local updates = feature('updates')
  local u = updates and updates.results[p.name]
  if u then
    c:add({
      { ind .. 'update ', 'CinchUpdate' },
      { ('%s → %s'):format(u.rev:sub(1, 7), u.rev_to:sub(1, 7)), 'CinchMuted' },
    })
    for _, commit in ipairs(u.commits) do
      c:add({ { ind .. '  ' .. commit.hash .. ' ', 'CinchMuted' }, { commit.subject } })
    end
  end

  c:add({ { ind .. 'spec', 'CinchSection' }, { '  as cinch read it', 'CinchMuted' } })
  c:block(inspect({ src = p.src, name = p.name, version = p.version, load = p.load, data = p.data }), ind .. '  ')

  c:add({ { ind .. 'vim.pack', 'CinchSection' }, { '  what vim.pack knows', 'CinchMuted' } })
  local info = ctx.info[p.name]
  if type(info) == 'table' then
    local tags = info.tags or {}
    c:block(
      inspect({
        active = info.active,
        path = info.path,
        rev = info.rev,
        spec = info.spec,
        branches = info.branches,
        tags = #tags > 10 and vim.list_extend(vim.list_slice(tags, 1, 10), { ('… %d more'):format(#tags - 10) })
          or tags,
      }),
      ind .. '  '
    )
  else
    c:add({ { ind .. '  ' .. (info or 'reading…'), 'CinchMuted' } })
  end

  c:add({ { ind .. 'config', 'CinchSection' }, { '  what the plugin received', 'CinchMuted' } })
  if p.state ~= 'loaded' then
    c:add({ { ind .. '  not loaded yet; declared opts:', 'CinchMuted' } })
    c:block(inspect(p.data.opts), ind .. '  ')
  elseif type(p.data.config) == 'function' then
    c:add({ { ind .. '  ' .. inspect(p.data.config) .. ' called with', 'CinchMuted' } })
    c:block(inspect(p.opts_used or {}), ind .. '  ')
  elseif p.main_used then
    c:add({ { ind .. ("  require('%s').setup() called with"):format(p.main_used), 'CinchMuted' } })
    c:block(inspect(p.opts_used or {}), ind .. '  ')
  else
    c:add({ { ind .. '  nothing: no opts or config, the plugin runs as it is', 'CinchMuted' } })
  end
  c:blank()
end

---@param c cinch.ui.Canvas
---@param p cinch.Plugin
---@param ctx cinch.ui.Ctx
local function row(c, p, ctx)
  local stats = feature('stats')
  local updates = feature('updates')
  local s = stats and stats.plugins[p.name]
  local u = updates and updates.results[p.name]
  local chunks = {
    { '  ' .. icons[p.state] .. ' ', icon_hl[p.state] },
    { pad(p.name, 28), p.state == 'disabled' and 'CinchMuted' or nil },
    { pad(p.load, 12), 'CinchMuted' },
    { pad(why(p), 34) },
    { pad(s and ms_text(s.packadd + s.config) or '', 9), 'CinchMuted' },
  }
  if u then
    chunks[#chunks + 1] = { ('↑%d '):format(#u.commits), 'CinchUpdate' }
  end
  if p.activity then
    chunks[#chunks + 1] = { '⟳ ' .. p.activity, 'CinchActive' }
  end
  c:add(chunks, p.name)
  if ctx.expanded[p.name] then
    details(c, p, ctx)
  end
end

---@param c cinch.ui.Canvas
local function updates_line(c)
  local updates = feature('updates')
  if not updates then
    return
  end
  local n = vim.tbl_count(updates.results)
  local status
  if updates.checking then
    status = { '⟳ checking for updates…', 'CinchActive' }
  elseif updates.checked_at then
    status = {
      n > 0 and ('%d update%s available'):format(n, n == 1 and '' or 's') or 'up to date',
      n > 0 and 'CinchUpdate' or 'CinchMuted',
    }
  else
    status = { 'not checked yet', 'CinchMuted' }
  end
  local chunks = { { ' updates  ', 'CinchSection' }, status }
  if updates.checked_at and not updates.checking then
    chunks[#chunks + 1] = { ' · checked ' .. ago(updates.checked_at), 'CinchMuted' }
  end
  chunks[#chunks + 1] = { '    c check  u update  U update all', 'CinchMuted' }
  c:add(chunks)
  c:blank()
end

local sections = {
  { 'failed', { failed = true } },
  { 'loaded', { loaded = true, loading = true } },
  { 'not loaded', { pending = true, registered = true } },
  { 'disabled', { disabled = true } },
}

---@param c cinch.ui.Canvas
---@param ctx cinch.ui.Ctx
function M.plugins(c, ctx)
  updates_line(c)
  for _, sec in ipairs(sections) do
    local list = vim.tbl_filter(function(p)
      return sec[2][p.state]
    end, state.list)
    if sec[1] == 'loaded' then
      table.sort(list, function(a, b)
        return (a.order or 0) < (b.order or 0)
      end)
    end
    if #list > 0 then
      c:add({ { (' %s (%d)'):format(sec[1], #list), 'CinchSection' } })
      for _, p in ipairs(list) do
        row(c, p, ctx)
      end
      c:blank()
    end
  end
  c:add({ { ' <CR> details  l load  b build  u update  r refresh', 'CinchMuted' } })
end

-- Stats -------------------------------------------------------------------------

local bars = { '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█' }

---@param c cinch.ui.Canvas
function M.stats(c)
  local stats = feature('stats')
  if not stats then
    return c:add({ { ' the stats feature is not loaded', 'CinchMuted' } })
  end
  for _, line in ipairs(stats.lines()) do
    local label, rest = line:match('^(%S+)(.*)$')
    c:add({ { ' ' .. (label or ''), 'CinchSection' }, { rest or line } })
  end
  local history = stats.history()
  if #history > 0 then
    local recent = vim.list_slice(history, math.max(1, #history - 29))
    local max = 0
    for _, h in ipairs(recent) do
      max = math.max(max, h.startup or 0)
    end
    local spark = vim.tbl_map(function(h)
      return bars[math.max(1, math.ceil((h.startup or 0) / math.max(max, 1) * #bars))]
    end, recent)
    c:blank()
    c:add({ { ' history', 'CinchSection' }, { ('     last %d sessions, startup ms  '):format(#recent), 'CinchMuted' } })
    c:add({ { '             ' .. table.concat(spark), 'CinchActive' } })
    c:add({
      {
        '             ' .. table.concat(
          vim.tbl_map(function(h)
            return ('%.0f'):format(h.startup or 0)
          end, vim.list_slice(recent, math.max(1, #recent - 9))),
          ' '
        ),
        'CinchMuted',
      },
    })
  end
end

-- Log ---------------------------------------------------------------------------

local level_hl = { [vim.log.levels.ERROR] = 'CinchFailed', [vim.log.levels.WARN] = 'CinchWarn' }

---@param c cinch.ui.Canvas
function M.log(c)
  local messages = feature('messages')
  if not messages then
    return c:add({ { ' the messages feature is not loaded', 'CinchMuted' } })
  end
  if #messages.log == 0 then
    return c:add({ { ' nothing logged yet', 'CinchMuted' } })
  end
  for _, m in ipairs(messages.log) do
    local first, rest = m.msg:match('^([^\n]*)\n?(.*)$')
    c:add({
      { ' ' .. os.date('%H:%M:%S', m.time) .. ' ', 'CinchMuted' },
      { pad(m.source, 9), 'CinchKey' },
      { first, level_hl[m.level] },
    })
    if rest ~= '' then
      c:block(rest, '                    ', 'CinchMuted')
    end
  end
end

--- Render a view.
---@param view 'plugins'|'stats'|'log'
---@param width integer
---@param ctx cinch.ui.Ctx
---@return cinch.ui.Canvas
function M.render(view, width, ctx)
  local c = M.canvas(width)
  header(c, view)
  M[view](c, ctx)
  return c
end

return M
