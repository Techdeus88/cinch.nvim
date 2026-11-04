-- The Plugins view: the list on the left and the detail pane on the right, which
-- follows the plugin under the cursor. While a first start installs, the same
-- list shows each plugin's install progress, then settles into its normal rows.
-- Nothing here changes state or calls vim.pack; the window hands in what it knows.

local canvas = require('cinch.features.ui.canvas')
local state = require('cinch.state')

local fit, right, cells = canvas.fit, canvas.right, canvas.cells

local M = {}

---@param name string
---@return table?
local function feature(name)
  return package.loaded['cinch.features.' .. name]
end

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

-- Sections, in the order they are shown. A plugin goes in the first one whose
-- test it passes, in `priority` order, so a loaded plugin that is updating is "working".
M.sections = {
  { key = 'failed', title = 'failed', hl = 'CinchFailed' },
  { key = 'loaded', title = 'loaded', hl = 'CinchLoaded' },
  { key = 'working', title = 'working', hl = 'CinchActive' },
  { key = 'waiting', title = 'waiting', hl = 'CinchWaiting' },
  { key = 'disabled', title = 'disabled', hl = 'CinchMuted' },
}

---@param p cinch.Plugin
---@return string section key
function M.section_of(p)
  if p.state == 'failed' then
    return 'failed'
  elseif p.activity or p.state == 'loading' then
    return 'working'
  elseif p.state == 'loaded' then
    return 'loaded'
  elseif p.state == 'disabled' then
    return 'disabled'
  end
  return 'waiting'
end

local icons = { failed = '✗', loaded = '●', waiting = '○', disabled = '–' }
local chip_hl = { now = 'CinchNow', later = 'CinchLater', trigger = 'CinchTrigger', now_if_args = 'CinchNow' }
local chip_text = { now = 'now', later = 'later', trigger = 'trigger', now_if_args = 'if args' }

---@param p cinch.Plugin
---@param tick integer spinner frame
---@return string icon, string group
local function icon(p, tick)
  local sec = M.section_of(p)
  if sec == 'working' then
    return canvas.spinner[tick % #canvas.spinner + 1], 'CinchActive'
  end
  for _, s in ipairs(M.sections) do
    if s.key == sec then
      return icons[sec], s.hl
    end
  end
  return '·', 'CinchMuted'
end

--- What a waiting plugin waits on: "cmd Trouble · keys <leader>x".
---@param p cinch.Plugin
---@return string
local function waits_on(p)
  if p.when ~= 'trigger' then
    return p.when == 'later' and 'after startup' or 'at startup'
  end
  local parts = {}
  for name, values in pairs(p.triggers or {}) do
    local shown = vim.tbl_map(function(v)
      return type(v) == 'table' and v.lhs or (tostring(v):gsub('^FileType ', ''))
    end, values)
    parts[#parts + 1] = (name == 'event' and '' or (name .. ' ')) .. table.concat(shown, ', ')
  end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, ' · ') or 'loads with its dependents'
end

--- One short phrase per plugin for the list.
---@param p cinch.Plugin
---@return string text, string group
local function why(p)
  local sec = M.section_of(p)
  if sec == 'failed' then
    return vim.split(p.err or 'failed', '\n')[1], 'CinchFailed'
  elseif sec == 'working' then
    return (p.activity or 'loading') .. '…', 'CinchActive'
  elseif sec == 'disabled' then
    return p.reason == 'cond' and 'cond is false' or 'enabled = false', 'CinchMuted'
  elseif sec == 'loaded' then
    local r = p.reason or ''
    if r == 'now' or r == 'later' or r == 'manual' then
      return 'by ' .. r, 'CinchMuted'
    end
    return (r:gsub('^event ', '')), 'CinchMuted'
  end
  return waits_on(p), 'CinchMuted'
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

-- List ----------------------------------------------------------------------------

--- Column widths for a list `width` cells wide. Narrow windows drop the bar first.
---@param width integer
---@param plugins cinch.Plugin[]
local function columns(width, plugins)
  local longest = 12
  for _, p in ipairs(plugins) do
    longest = math.max(longest, cells(p.name))
  end
  local c = { name = math.min(longest, 26), chip = 10, bar = 7, time = 8, up = 4 }
  local fixed = 3 + c.name + 1 + c.chip + 1 + c.bar + c.time + c.up
  c.why = width - fixed
  if c.why < 14 then
    c.why, c.bar = c.why + c.bar, 0
  end
  c.why = math.max(c.why, 6)
  return c
end

---@param ctx cinch.ui.Ctx
---@return cinch.Plugin[]
local function visible(ctx)
  return vim.tbl_filter(function(p)
    return not ctx.filter or p.name:lower():find(ctx.filter:lower(), 1, true) ~= nil
  end, state.list)
end

---@param c cinch.ui.Canvas
---@param p cinch.Plugin
---@param col table
---@param slowest number
---@param ctx cinch.ui.Ctx
local function row(c, p, col, slowest, ctx)
  local ic, ic_hl = icon(p, ctx.tick)
  local text, text_hl = why(p)
  local ms, up = load_ms(p), pending(p)
  local chunks = {
    { ' ' .. ic .. ' ', ic_hl },
    { fit(p.name, col.name), p.state == 'disabled' and 'CinchMuted' or 'CinchName' },
    { ' ' },
    { fit(' ' .. chip_text[p.load] .. ' ', col.chip - 1), chip_hl[p.load] },
    { '  ' },
    { fit(text, col.why - 1) .. ' ', text_hl },
  }
  if col.bar > 0 then
    local filled, empty = canvas.bar(ms or 0, slowest, col.bar - 1)
    chunks[#chunks + 1] = { ms and filled or (' '):rep(col.bar - 1), 'CinchBar' }
    chunks[#chunks + 1] = { ms and empty or '', 'CinchBarEmpty' }
    chunks[#chunks + 1] = { ' ' }
  end
  chunks[#chunks + 1] = { right(canvas.ms(ms), col.time - 1) .. ' ', 'CinchMuted' }
  chunks[#chunks + 1] = { up and ('↑' .. up) or '', 'CinchUpdate' }
  c:add(chunks, { plugin = p.name })
end

--- Install progress for a first start: one line of status and a bar across the list.
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
  local filled, empty = canvas.bar(install.done, install.total, c.width - 2)
  c:add({ { ' ' .. filled, 'CinchBar' }, { empty, 'CinchBarEmpty' } })
  c:blank()
end

local install_look = {
  queued = { '·', 'CinchMuted', 'queued' },
  cloning = { nil, 'CinchActive', 'cloning…' },
  installed = { '✓', 'CinchLoaded', 'installed' },
  failed = { '✗', 'CinchFailed', 'could not install' },
}

--- The list while a first start installs: every plugin with its install status.
---@param c cinch.ui.Canvas
---@param ctx cinch.ui.Ctx
---@param col table
local function install_rows(c, ctx, col)
  for _, p in ipairs(visible(ctx)) do
    local status = ctx.install.status[p.name]
    local look = install_look[status]
      or (p.state == 'disabled' and { '–', 'CinchMuted', 'disabled' } or { '✓', 'CinchMuted', 'on disk' })
    local ic = look[1] or canvas.spinner[ctx.tick % #canvas.spinner + 1]
    c:add({
      { ' ' .. ic .. ' ', look[2] },
      { fit(p.name, col.name), 'CinchName' },
      { ' ' },
      { fit(' ' .. chip_text[p.load] .. ' ', col.chip - 1), chip_hl[p.load] },
      { '  ' },
      { look[3], look[2] },
    }, { plugin = p.name })
  end
end

--- The list, `width` cells wide.
---@param width integer
---@param ctx cinch.ui.Ctx
---@return cinch.ui.Canvas
function M.list(width, ctx)
  local c = canvas.new(width)
  local plugins = visible(ctx)
  local col = columns(width, plugins)
  if ctx.install then
    install_header(c, ctx.install)
    install_rows(c, ctx, col)
    return c
  end
  local slowest = 0
  for _, p in ipairs(plugins) do
    slowest = math.max(slowest, load_ms(p) or 0)
  end
  local by = {}
  for _, p in ipairs(plugins) do
    local key = M.section_of(p)
    by[key] = by[key] or {}
    table.insert(by[key], p)
  end
  table.sort(by.loaded or {}, function(a, b)
    return (a.order or 0) < (b.order or 0)
  end)
  if ctx.filter then
    c:add({ { ' / ' .. ctx.filter, 'CinchKey' }, { ('  %d of %d'):format(#plugins, #state.list), 'CinchMuted' } })
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
          row(c, p, col, slowest, ctx)
        end
      end
    end
  end
  if #plugins == 0 then
    c:add({ { ' no plugins match', 'CinchMuted' } })
  end
  return c
end

-- Pane ----------------------------------------------------------------------------

local key_w = 10

---@param c cinch.ui.Canvas
---@param key string
---@param chunks { [1]: string, [2]?: string }[]
local function kv(c, key, chunks)
  local w = c.width - key_w - 2
  local out = { { ' ' .. fit(key, key_w), 'CinchMuted' } }
  for _, ch in ipairs(chunks) do
    local text = fit(ch[1], math.min(w, cells(ch[1])))
    w = w - cells(text)
    out[#out + 1] = { text, ch[2] }
  end
  c:add(out)
end

---@param c cinch.ui.Canvas
---@param p cinch.Plugin
local function pane_header(c, p)
  local ic, ic_hl = icon(p, 0)
  local status = ic .. ' ' .. (M.section_of(p) == 'working' and (p.activity or 'loading') or p.state)
  local ms = load_ms(p)
  if ms then
    status = status .. ' · ' .. canvas.ms(ms)
  end
  local name_w = c.width - cells(status) - 3
  c:add({ { ' ' .. fit(p.name, name_w), 'CinchTitle' }, { ' ' .. status .. ' ', ic_hl } })
  c:add({ { ' ' .. ('─'):rep(c.width - 2), 'CinchRule' } })
end

---@param c cinch.ui.Canvas
---@param p cinch.Plugin
local function pane_version(c, p)
  local version = p.version and canvas.value(p.version) or 'default branch'
  local rev = p.rev and p.rev:sub(1, 7)
  kv(c, 'version', { { version }, { rev and (' → ' .. rev) or '', 'CinchMuted' } })
  local updates = feature('updates')
  local u = updates and updates.results[p.name]
  if u then
    kv(c, 'update', { { ('↑ %d commit%s'):format(#u.commits, #u.commits == 1 and '' or 's'), 'CinchUpdate' } })
    for i, commit in ipairs(u.commits) do
      if i > 8 then
        kv(c, '', { { ('… %d more'):format(#u.commits - 8), 'CinchMuted' } })
        break
      end
      kv(c, '', { { commit.hash .. ' ', 'CinchMuted' }, { commit.subject } })
    end
  end
end

---@param c cinch.ui.Canvas
---@param p cinch.Plugin
local function pane_deps(c, p)
  if #p.deps == 0 then
    return
  end
  local chunks = {}
  for i, name in ipairs(p.deps) do
    local d = state.plugins[name]
    local ic, hl = icon(d, 0)
    chunks[#chunks + 1] = { (i > 1 and ', ' or '') .. name .. ' ' }
    chunks[#chunks + 1] = { ic, hl }
  end
  kv(c, 'deps', chunks)
end

---@param c cinch.ui.Canvas
---@param p cinch.Plugin
local function pane_config(c, p)
  local d = p.data
  local opts = p.state == 'loaded' and p.opts_used or d.opts
  if type(d.config) == 'function' then
    kv(c, 'config', { { canvas.value(d.config) } })
  elseif p.main_used then
    kv(c, 'config', { { ("require('%s').setup(opts)"):format(p.main_used) } })
  elseif d.config == true or d.opts ~= nil then
    kv(c, 'config', { { ("require('%s').setup(opts)"):format(d.main or '…'), 'CinchMuted' } })
  end
  if type(opts) == 'function' then
    kv(c, 'opts', { { canvas.value(opts), 'CinchMuted' }, { '  runs when it loads', 'CinchMuted' } })
  elseif type(opts) == 'table' and next(opts) == nil then
    kv(c, 'opts', { { '{}', 'CinchMuted' } })
  elseif type(opts) == 'table' then
    local flat = canvas.flatten(opts)
    local kw = 0
    for _, pair in ipairs(flat) do
      kw = math.max(kw, cells(pair[1]))
    end
    -- Keys keep their width; values give way first.
    kw = math.min(kw, c.width - key_w - 14)
    for i, pair in ipairs(flat) do
      kv(c, i == 1 and 'opts' or '', { { fit(pair[1], kw) .. ' = ', 'CinchKey' }, { pair[2] } })
    end
  end
  for _, hook in ipairs({ 'init', 'build', 'after' }) do
    if d[hook] ~= nil then
      kv(c, hook, { { type(d[hook]) == 'string' and d[hook] or canvas.value(d[hook]), 'CinchMuted' } })
    end
  end
end

---@param c cinch.ui.Canvas
---@param p cinch.Plugin
---@param ctx cinch.ui.Ctx
local function pane_disk(c, p, ctx)
  local info = ctx.info[p.name]
  if type(info) == 'table' then
    local tags = #(info.tags or {})
    local branches = table.concat(info.branches or {}, ', ')
    kv(c, 'remote', {
      { branches ~= '' and branches or 'no branches' },
      { (' · %d tag%s'):format(tags, tags == 1 and '' or 's'), 'CinchMuted' },
    })
  elseif type(info) == 'string' then
    kv(c, 'remote', { { info, 'CinchMuted' } })
  end
end

--- The detail pane for one plugin, `width` cells wide.
---@param name? string
---@param width integer
---@param ctx cinch.ui.Ctx
---@return cinch.ui.Canvas
function M.pane(name, width, ctx)
  local c = canvas.new(width)
  local p = name and state.plugins[name]
  if not p then
    c:add({ { ' move to a plugin to see it here', 'CinchMuted' } })
    return c
  end
  pane_header(c, p)
  local sec = M.section_of(p)
  if sec == 'failed' then
    -- Wrapped, not cut: an error is the one thing to read in full.
    local n = 0
    for _, line in ipairs(vim.split(p.err or '', '\n', { trimempty = true })) do
      for _, part in ipairs(canvas.wrap(line, c.width - key_w - 2)) do
        n = n + 1
        kv(c, n == 1 and 'error' or '', { { part, 'CinchFailed' } })
      end
    end
    if (p.err or ''):find('set `main`') then
      kv(c, 'fix', { { "set main = '<module>' in the spec" } })
    end
    kv(c, 'failed in', { { p.failed_in or '?' } })
  elseif sec == 'loaded' then
    local stats = feature('stats')
    local at = stats and stats.plugins[p.name] and stats.plugins[p.name].at
    kv(c, 'load', { { p.load }, { p.when == 'trigger' and ('  ' .. waits_on(p)) or '', 'CinchMuted' } })
    kv(c, 'loaded', {
      { why(p) },
      { ('  %s%s'):format(p.order and ('#' .. p.order) or '', at and (' at ' .. canvas.ms(at)) or ''), 'CinchMuted' },
    })
  elseif sec == 'working' then
    kv(c, 'now', { { (p.activity or 'loading') .. '…', 'CinchActive' } })
    if p.state == 'pending' then
      kv(c, 'then', { { 'loads when this is done', 'CinchMuted' } })
    end
  elseif sec == 'disabled' then
    kv(c, 'off', { { p.reason == 'cond' and 'cond returned false' or 'enabled = false' } })
  else
    kv(c, 'waits on', { { waits_on(p) } })
  end
  if sec ~= 'disabled' then
    pane_version(c, p)
    pane_deps(c, p)
    pane_config(c, p)
    pane_disk(c, p, ctx)
  end
  if p.origin and p.origin.file then
    local line = ctx.spec_lines[p.name]
    kv(
      c,
      'spec',
      { { canvas.short_path(p.origin.file) .. (line and (':' .. line) or '') }, { '  gf opens it', 'CinchMuted' } }
    )
  end
  return c
end

return M
