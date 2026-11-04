-- The Plugins view: the list on the left and the detail pane on the right, which
-- follows the plugin under the cursor. While a first start installs, the same
-- list shows each plugin's install progress, then settles into its normal rows.
-- Nothing here changes state or calls vim.pack; the window hands in what it knows.

local canvas = require('cinch.features.ui.canvas')
local state = require('cinch.state')

local fit, cells = canvas.fit, canvas.cells

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

-- Sections, in the order they are shown: what is happening now first, so it is in
-- view while it changes, then what went wrong. section_of() puts a plugin in one,
-- so a loaded plugin that is updating is "working".
M.sections = {
  { key = 'working', title = 'working', hl = 'CinchActive' },
  { key = 'failed', title = 'failed', hl = 'CinchFailed' },
  { key = 'loaded', title = 'loaded', hl = 'CinchLoaded' },
  { key = 'waiting', title = 'waiting', hl = 'CinchWaiting' },
  { key = 'disabled', title = 'disabled', hl = 'CinchMuted' },
}

---@param p cinch.Plugin
---@return string section key
function M.section_of(p)
  if p.activity or p.state == 'loading' then
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

local marks = { failed = '✗', loaded = '●', waiting = '○', disabled = '–' }

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
}

---@param name string
---@return string
local function glyph(name)
  local ui = package.loaded['cinch.features.ui']
  local own = ui and ui.opts.icons
  return own and own[name] or M.icons[name] or M.icons.trigger
end

--- The status light left of the name: lit when loaded, a spinner while working.
---@param p cinch.Plugin
---@param tick integer spinner frame
---@return string mark, string group
local function mark(p, tick)
  local sec = M.section_of(p)
  if sec == 'working' then
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
    local item = { { glyph(kind) .. ' ' .. kind, 'CinchIconTrigger' } }
    for _, v in ipairs(p.triggers[kind]) do
      local value = type(v) == 'table' and v.lhs or tostring(v)
      -- What the handler says when it fires: 'event FileType lua', 'cmd Foo', 'keys <lhs>'.
      local fired_as = ((kind == 'event' or kind == 'ft') and 'event' or kind) .. ' ' .. value
      local shown = kind == 'ft' and value:gsub('^FileType ', '') or value
      item[#item + 1] = { ' ' }
      if p.reason == fired_as and p.state ~= 'pending' then
        vim.list_extend(item, canvas.chip(shown, 'CinchTrigger', cells(shown) + 2))
      else
        item[#item + 1] = { shown, 'CinchTriggerValue' }
      end
    end
    out[#out + 1] = item
  end
  return out
end

--- How a plugin loads: an icon and its name for now and later, each trigger type
--- with its values, and for a plugin that is only a dependency the plugins that need it.
---@param p cinch.Plugin
---@param needed_by string[]
---@return cinch.ui.Item[]
local function load_items(p, needed_by)
  if p.dep_only then
    return vim.tbl_map(function(name)
      return { { glyph('dep') .. ' ' .. name, 'CinchDep' } }
    end, needed_by)
  elseif p.when == 'trigger' then
    return trigger_items(p)
  end
  return { { { glyph(p.when) .. ' ' .. p.when, p.when == 'now' and 'CinchIconNow' or 'CinchIconLater' } } }
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
    return (p.activity or 'loading') .. '…', 'CinchActive'
  elseif sec == 'disabled' then
    return p.reason == 'cond' and 'cond is false' or 'enabled = false', 'CinchMuted'
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

-- List ----------------------------------------------------------------------------

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

--- One plugin's line, each part right after the last, cut at the list's edge:
---   ● <name> (<load time>) <bar> <how it loads> <↑updates> <message>
---@param c cinch.ui.Canvas
---@param p cinch.Plugin
---@param r cinch.ui.Row
local function add_row(c, p, r)
  local items = {
    { { ' ' .. r.mark, r.mark_hl } },
    { { p.name, p.state == 'disabled' and 'CinchMuted' or 'CinchName' } },
  }
  if r.ms then
    local filled, empty = canvas.bar(r.ms, r.slowest, 6)
    items[#items + 1] = { { '(' .. canvas.ms(r.ms) .. ')', 'CinchMuted' } }
    items[#items + 1] = { { filled, 'CinchBar' }, { empty, 'CinchBarEmpty' } }
  end
  vim.list_extend(items, load_items(p, r.needed_by))
  if r.up then
    items[#items + 1] = { { '↑' .. r.up, 'CinchUpdate' } }
  end
  if r.msg then
    items[#items + 1] = { { r.msg, r.msg_hl } }
  end
  c:add(canvas.clip(join(items), c.width - 1), { plugin = p.name })
end

---@param ctx cinch.ui.Ctx
---@return cinch.Plugin[]
local function visible(ctx)
  return vim.tbl_filter(function(p)
    return not ctx.filter or p.name:lower():find(ctx.filter:lower(), 1, true) ~= nil
  end, state.list)
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
  c:add(vim.list_extend({ { ' ' } }, canvas.pill(install.done, install.total, c.width - 3)))
  c:blank()
end

-- Each install status: its mark (nil: the spinner), its color, the message.
local install_look = {
  queued = { '·', 'CinchMuted', 'queued' },
  cloning = { nil, 'CinchActive', 'cloning…' },
  installed = { '✓', 'CinchLoaded' },
  failed = { '✗', 'CinchFailed', 'could not install' },
  disabled = { '–', 'CinchMuted' },
  on_disk = { '✓', 'CinchMuted' },
}

--- The list while a first start installs: every plugin with its install status,
--- in the same rows as the Plugins view, so they settle in place.
---@param c cinch.ui.Canvas
---@param ctx cinch.ui.Ctx
local function install_rows(c, ctx)
  local needed = dependents()
  for _, p in ipairs(visible(ctx)) do
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
          })
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
    return { { glyph('dep') .. ' with the plugins that need it', 'CinchDep' } }
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
  return { { text, p.when == 'now' and 'CinchIconNow' or 'CinchIconLater' } }
end

---@param c cinch.ui.Canvas
---@param p cinch.Plugin
local function pane_header(c, p)
  local ic, ic_hl = mark(p, 0)
  local status = ic .. ' ' .. (M.section_of(p) == 'working' and (p.activity or 'loading') or p.state)
  local ms = load_ms(p)
  if ms then
    status = status .. ' · ' .. canvas.ms(ms)
  end
  local name_w = c.width - cells(status) - 3
  c:add({ { ' ' .. fit(p.name, name_w), 'CinchTitle' }, { ' ' .. status .. ' ', ic_hl } })
  c:add({ { ' ' .. ('─'):rep(c.width - 2), 'CinchRule' } })
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
    -- now and later say it all; anything else says what loaded it.
    local by = ({ now = '', later = '', manual = 'by hand  ' })[p.reason] or ((p.reason or '?') .. '  ')
    kv(c, 'load', load_line(p))
    kv(c, 'loaded', {
      { by },
      { ('%s%s'):format(p.order and ('#' .. p.order) or '', at and (' at ' .. canvas.ms(at)) or ''), 'CinchMuted' },
    })
  elseif sec == 'working' then
    kv(c, 'now', { { (p.activity or 'loading') .. '…', 'CinchActive' } })
    if p.state == 'pending' then
      kv(c, 'then', { { 'loads when this is done', 'CinchMuted' } })
    end
  elseif sec == 'disabled' then
    kv(c, 'off', { { p.reason == 'cond' and 'cond returned false' or 'enabled = false' } })
  else
    kv(c, 'load', load_line(p))
  end
  if sec ~= 'disabled' then
    pane_where(c, p, ctx)
    pane_updates(c, p)
    pane_deps(c, p)
    pane_config(c, p)
  end
  if p.origin and p.origin.file then
    local line = ctx.spec_lines[p.name]
    kv(c, 'spec', { { canvas.short_path(p.origin.file) .. (line and (':' .. line) or '') } })
  end
  return c
end

return M
