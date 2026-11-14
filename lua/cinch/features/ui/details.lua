-- The detail pane of the Plugins view: what the plugin under the cursor is, how it
-- loads, where it lives, its updates, dependencies and config. The window draws what
-- this returns; nothing here changes state.

local canvas = require('cinch.features.ui.canvas')
local rows = require('cinch.features.ui.rows')
local state = require('cinch.state')

local fit, cells = canvas.fit, canvas.cells
local feature, glyph, join, mark, trigger_items = rows.feature, rows.glyph, rows.join, rows.mark, rows.trigger_items
local dependents, load_ms, section_of = rows.dependents, rows.load_ms, rows.section_of

local M = {}

local key_w = 10

---@param c cinch.ui.Canvas
---@param key string
---@param chunks { [1]: string, [2]?: string }[]
local function kv(c, key, chunks)
  local w = c.width - key_w - 2
  -- One value that does not fit wraps under itself instead of being cut.
  if #chunks == 1 and cells(chunks[1][1]) > w then
    for i, part in ipairs(canvas.wrap(chunks[1][1], w)) do
      c:add({ { ' ' .. fit(i == 1 and key or '', key_w), 'CinchMuted' }, { part, chunks[1][2] } })
    end
    return
  end
  local out = { { ' ' .. fit(key, key_w), 'CinchMuted' } }
  for _, ch in ipairs(chunks) do
    local text = fit(ch[1], math.min(w, cells(ch[1])))
    w = w - cells(text)
    out[#out + 1] = { text, ch[2] }
  end
  c:add(out)
end

--- How it loads, in words next to the icons.
---@param p cinch.Plugin
---@return { [1]: string, [2]?: string }[]
local function load_line(p)
  if p.dep_only then
    return { { glyph('dep') .. ' before dependents', select(2, canvas.kind_hl('dep')) } }
  elseif p.when == 'trigger' then
    return join(trigger_items(p))
  end
  local words = p.when == 'now' and 'at startup' or 'after startup'
  local text = glyph(p.when)
    .. ' '
    .. p.load
    .. (p.load == 'now_if_args' and (', so ' .. p.when) or '')
    .. ' · '
    .. words
  return { { text, select(2, canvas.kind_hl(p.when)) } }
end

---@param c cinch.ui.Canvas
---@param p cinch.Plugin
local function pane_header(c, p)
  local ic, ic_hl = mark(p, 0)
  local status = ic .. ' ' .. (section_of(p) == 'working' and (p.activity or 'loading') or p.state)
  local ms = load_ms(p)
  if ms then
    status = status .. ' · ' .. canvas.ms(ms)
  end
  local name_w = c.width - cells(status) - 3
  c:add({ { ' ' .. fit(p.name, name_w), 'CinchTitle' }, { ' ' .. status .. ' ', ic_hl } })
  c:add({ { ' ' .. ('─'):rep(c.width - 2), 'CinchRule' } })
end

--- The last lines of its build's output: live while it builds, else the last build's.
---@param c cinch.ui.Canvas
---@param p cinch.Plugin
local function pane_output(c, p)
  local log = p.build_log or {}
  local first = math.max(1, #log - 11)
  for i = first, #log do
    kv(c, i == first and 'output' or '', { { log[i], 'CinchMuted' } })
  end
end

--- Where the plugin lives and what it is at: its folder, its url, the branch it
--- follows, the version you asked for when that is not a branch, the commit on
--- disk, and its readme. Branches come from vim.pack.get, read a moment after the
--- plugin is selected.
---@param c cinch.ui.Canvas
---@param p cinch.Plugin
---@param ctx cinch.ui.Ctx
local function pane_where(c, p, ctx)
  local path = p.path or vim.fs.joinpath(require('cinch.pack').dir, p.name)
  local on_disk = vim.uv.fs_stat(path) ~= nil
  if on_disk then
    kv(c, 'dir', { { vim.fn.fnamemodify(path, ':~'), 'CinchLink' } })
  end
  kv(c, 'url', { { p.src, 'CinchLink' } })
  local info = ctx.info[p.name]
  local branches = type(info) == 'table' and info.branches or {}
  local version = p.version
  -- The branch it follows: the one you named, or the default when you named none.
  local branch = type(version) == 'string' and vim.list_contains(branches, version) and version
    or version == nil and branches[1]
  if branch then
    local tags = #(info.tags or {})
    kv(c, 'branch', { { branch }, { (' · %d tag%s'):format(tags, tags == 1 and '' or 's'), 'CinchMuted' } })
  elseif type(info) == 'string' then
    kv(c, 'branch', { { info, 'CinchMuted' } })
  end
  if version ~= nil and not branch then
    kv(c, 'version', { { canvas.value(version) } })
  end
  if p.rev then
    kv(c, 'commit', { { p.rev:sub(1, 7), 'CinchCommit' } })
  end
  local readme = on_disk and vim.fn.glob(path .. '/[Rr][Ee][Aa][Dd][Mm][Ee]*', false, true)[1]
  if readme then
    kv(c, 'readme', { { vim.fs.basename(readme) } })
  end
end

---@param c cinch.ui.Canvas
---@param p cinch.Plugin
local function pane_updates(c, p)
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
  if #p.deps > 0 then
    local chunks = {}
    for i, name in ipairs(p.deps) do
      local ic, hl = mark(state.plugins[name], 0)
      chunks[#chunks + 1] = { (i > 1 and ', ' or '') .. name .. ' ' }
      chunks[#chunks + 1] = { ic, hl }
    end
    kv(c, 'deps', chunks)
  end
  local needed = dependents()[p.name]
  if needed then
    kv(c, 'needed by', { { table.concat(needed, ', '), 'CinchDep' } })
  end
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

--- The detail pane for one plugin, `width` cells wide.
---@param name? string
---@param width integer
---@param ctx cinch.ui.Ctx
---@return cinch.ui.Canvas
function M.pane(name, width, ctx)
  local c = canvas.new(width)
  local p = name and state.plugins[name]
  local orphan = not p
    and name
    and vim.iter(ctx.orphans or {}):find(function(o) ---@param o cinch.Orphan
      return o.name == name
    end)
  if orphan then
    c:add({ { ' ' .. fit(orphan.name, c.width - 20), 'CinchTitle' }, { ' not in specs ', 'CinchWarn' } })
    c:add({ { ' ' .. ('─'):rep(c.width - 2), 'CinchRule' } })
    kv(c, 'dir', { { vim.fn.fnamemodify(orphan.path, ':~'), 'CinchLink' } })
    kv(c, 'url', { { orphan.src, 'CinchLink' } })
    if orphan.rev then
      kv(c, 'commit', { { orphan.rev:sub(1, 7), 'CinchCommit' } })
    end
    kv(c, 'delete', { { 'd deletes it from disk; no spec will install it again', 'CinchMuted' } })
    return c
  elseif not p then
    c:add({ { ' move to a plugin to see it here', 'CinchMuted' } })
    return c
  end
  pane_header(c, p)
  local sec = section_of(p)
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
    kv(c, 'load', load_line(p))
    kv(c, 'loaded', {
      { ('%s%s'):format(p.order and ('#' .. p.order) or '', at and (' at ' .. canvas.ms(at)) or ''), 'CinchMuted' },
    })
  elseif sec == 'working' then
    kv(c, 'now', { { (p.activity or 'loading') .. '…', 'CinchActive' } })
    if p.state == 'pending' then
      kv(c, 'then', { { 'loads when this is done', 'CinchMuted' } })
    end
    if p.activity == 'building' then
      pane_output(c, p)
    end
  elseif sec == 'disabled' then
    local why = rows.off_reason(p)
    kv(c, 'off', why and { { why } } or join(rows.load_items(p, rows.dependents()[p.name] or {})))
  else
    kv(c, 'load', load_line(p))
  end
  if p.deleted then
    kv(c, 'disk', { { 'deleted; installs again on the next start', 'CinchWarn' } })
  end
  if sec ~= 'disabled' then
    pane_where(c, p, ctx)
    pane_updates(c, p)
    pane_deps(c, p)
    pane_config(c, p)
    if p.activity ~= 'building' then
      pane_output(c, p)
    end
  end
  if p.origin and p.origin.file then
    local line = ctx.spec_lines[p.name]
    kv(c, 'spec', { { canvas.short_path(p.origin.file) .. (line and (':' .. line) or '') } })
  end
  return c
end

return M
