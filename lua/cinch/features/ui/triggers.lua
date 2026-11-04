-- The Triggers view: what makes each plugin load. The list has one row per trigger,
-- grouped by kind (events, filetypes, commands, keys, your own), then the schedule:
-- the now and later queues and the plugins that load only with what needs them.
-- Each row shows whether it still waits to fire, a dot per plugin behind it, and
-- what happened. The pane follows the cursor and says in plain words when that
-- trigger fires, which plugins it loads, how long they took, and what else would
-- load them. Built from the plugin records alone, so a trigger whose handler is
-- gone still shows.

local canvas = require('cinch.features.ui.canvas')
local plugins_view = require('cinch.features.ui.plugins')
local state = require('cinch.state')

local glyph, cells, fit = plugins_view.glyph, canvas.cells, canvas.fit

local M = {}

---@class cinch.ui.Trigger
---@field id string what the list row and the pane know it by
---@field kind string event, ft, cmd, keys, your own, or queue
---@field value string the event, filetype, command or key, as shown
---@field raw string as the spec has it: 'FileType lua', a key's lhs, or the queue
---@field modes? string[] a key's modes
---@field fired_as? string the reason a plugin gets when it fires
---@field plugins cinch.Plugin[] in declaration order

-- Kinds in this order, then your own by name, each with its section's name.
local kinds = {
  { 'event', 'events' },
  { 'ft', 'filetypes' },
  { 'cmd', 'commands' },
  { 'keys', 'keys' },
}

-- When common events fire, in words. Any other event says Neovim fires it.
local event_words = {
  BufAdd = 'a buffer is added to the buffer list',
  BufEnter = 'you enter a buffer, every time',
  BufNewFile = 'you start editing a file that does not exist yet',
  BufRead = 'a file has been read into a buffer',
  BufReadPost = 'a file has been read into a buffer',
  BufReadPre = 'a file starts loading into a buffer, before its text is read',
  BufWinEnter = 'a buffer is shown in a window',
  BufWritePost = 'a buffer has been written to its file',
  BufWritePre = 'a buffer is about to be written to its file',
  CmdlineEnter = 'you start typing on the command line: a command, a search',
  CmdUndefined = 'you run a user command that does not exist yet',
  ColorScheme = 'a colorscheme has loaded',
  CursorHold = "the cursor rests for 'updatetime' in Normal mode",
  CursorMoved = 'the cursor moves in Normal mode',
  DiagnosticChanged = 'the diagnostics of a buffer change',
  DirChanged = 'the working directory changes',
  FileType = 'a buffer gets its filetype',
  FocusGained = 'Neovim gets the focus of your terminal or GUI',
  InsertEnter = 'you enter Insert mode',
  InsertLeave = 'you leave Insert mode',
  LspAttach = 'a language server attaches to a buffer',
  ModeChanged = 'the mode changes',
  QuickFixCmdPost = 'a quickfix command such as :make or :grep has run',
  TermOpen = 'a terminal starts in a buffer',
  TextChanged = 'you change text in Normal mode',
  TextChangedI = 'you change text in Insert mode',
  TextYankPost = 'you yank text',
  UIEnter = 'the UI attaches: the editor is on screen',
  VimEnter = 'startup is done: your config and its plugins have run',
  VimLeavePre = 'Neovim is about to exit',
  WinEnter = 'you enter a window',
}

local mode_words = {
  n = 'Normal',
  i = 'Insert',
  x = 'Visual',
  v = 'Visual and Select',
  s = 'Select',
  o = 'Operator-pending',
  c = 'Command-line',
  t = 'Terminal',
}

---@param p cinch.Plugin
---@return table? its stats record: at, packadd, config
local function record(p)
  local stats = package.loaded['cinch.features.stats']
  return stats and stats.plugins[p.name]
end

---@param p cinch.Plugin
---@return number? ms since Neovim started, when it loaded
local function loaded_at(p)
  local r = record(p)
  return r and r.at
end

---@param p cinch.Plugin
---@return number? packadd and config
local function load_ms(p)
  local r = record(p)
  return r and (r.packadd + r.config)
end

---@param p cinch.Plugin
---@return boolean
local function waits(p)
  return p.state == 'pending' or p.state == 'registered'
end

---@param kind string
---@param raw string
---@return string
local function value_of(kind, raw)
  return kind == 'ft' and (raw:gsub('^FileType ', '')) or raw
end

--- Every trigger of your plugins, each once, then the schedule.
---@return cinch.ui.Trigger[]
local function collect()
  local by, list = {}, {}
  for _, p in ipairs(state.yours()) do
    if p.when == 'trigger' and p.state ~= 'disabled' then
      for kind, values in pairs(p.triggers or {}) do
        for _, v in ipairs(values) do
          local raw = type(v) == 'table' and v.lhs or tostring(v)
          local id = kind .. ' ' .. raw
          local t = by[id]
          if not t then
            t = {
              id = id,
              kind = kind,
              raw = raw,
              value = value_of(kind, raw),
              modes = type(v) == 'table' and v.modes or nil,
              -- What the handler names as the reason when it fires: 'event FileType lua'.
              fired_as = ((kind == 'event' or kind == 'ft') and 'event' or kind) .. ' ' .. raw,
              plugins = {},
            }
            by[id], list[#list + 1] = t, t
          end
          table.insert(t.plugins, p)
        end
      end
    end
  end
  ---@param raw string
  ---@param value string
  ---@param keep fun(p: cinch.Plugin): boolean
  local function queue(raw, value, keep)
    local ps = vim.tbl_filter(function(p)
      return p.state ~= 'disabled' and keep(p)
    end, state.yours())
    if #ps > 0 then
      list[#list + 1] = { id = 'queue ' .. raw, kind = 'queue', value = value, raw = raw, plugins = ps }
    end
  end
  queue('now', 'now', function(p)
    return p.when == 'now'
  end)
  queue('later', 'later', function(p)
    return p.when == 'later'
  end)
  queue('dep', 'dependencies', function(p)
    return p.dep_only == true
  end)
  return list
end

---@param t cinch.ui.Trigger
---@return number? when it first fired; math.huge when it did but stats cannot say when
local function fired(t)
  if not t.fired_as then
    return
  end
  local first
  for _, p in ipairs(t.plugins) do
    if p.reason == t.fired_as and not waits(p) then
      first = math.min(first or math.huge, loaded_at(p) or math.huge)
    end
  end
  return first
end

---@alias cinch.ui.TriggerStatus 'waiting'|'fired'|'never'|'queue'

---@param t cinch.ui.Trigger
---@return cinch.ui.TriggerStatus
local function status(t)
  if t.kind == 'queue' then
    return 'queue'
  elseif vim.iter(t.plugins):any(waits) then
    return 'waiting'
  end
  return fired(t) and 'fired' or 'never'
end

---@param t cinch.ui.Trigger
---@return string text, string group
local function status_text(t)
  local s = status(t)
  local n = #vim.tbl_filter(waits, t.plugins)
  if s == 'fired' then
    local at = fired(t) --[[@as number]]
    return 'fired' .. (at < math.huge and (' at ' .. canvas.ms(at)) or ''), 'CinchLoaded'
  elseif s == 'never' then
    return 'never fired', 'CinchMuted'
  elseif n > 0 then
    return ('%d waiting'):format(n), 'CinchWaiting'
  end
  return 'all loaded', 'CinchLoaded'
end

-- A trigger's light on the list, by its status.
local lights = {
  waiting = { '○', 'CinchWaiting' },
  fired = { '●', 'CinchLoaded' },
  never = { '◌', 'CinchMuted' },
}

-- A plugin's dot, by its state.
local dots =
  { loaded = { '●', 'CinchLoaded' }, failed = { '✗', 'CinchFailed' }, loading = { '●', 'CinchActive' } }

---@param p cinch.Plugin
---@return { [1]: string, [2]: string }
local function dot(p)
  return dots[p.state] or { '○', 'CinchWaiting' }
end

---@param t cinch.ui.Trigger
---@return string
local function shown(t)
  return t.kind == 'cmd' and (':' .. t.value) or t.value
end

-- List ----------------------------------------------------------------------------

---@param c cinch.ui.Canvas
---@param t cinch.ui.Trigger
local function row(c, t)
  local s = status(t)
  local light = s == 'queue' and { glyph(t.raw), t.raw == 'now' and 'CinchIconNow' or 'CinchIconLater' } or lights[s]
  local chunks = {
    { '   ' .. light[1] .. ' ', light[2] },
    { shown(t), s == 'never' and 'CinchMuted' or 'CinchName' },
  }
  if t.modes and not (#t.modes == 1 and t.modes[1] == 'n') then
    chunks[#chunks + 1] = { ' ' .. table.concat(t.modes, ' '), 'CinchMuted' }
  end
  chunks[#chunks + 1] = { ' ' }
  for i, p in ipairs(t.plugins) do
    if i > 8 then
      chunks[#chunks + 1] = { '+' .. (#t.plugins - 8), 'CinchMuted' }
      break
    end
    chunks[#chunks + 1] = dot(p)
  end
  local text, hl = status_text(t)
  chunks[#chunks + 1] = { ' ' .. text, hl }
  c:add(canvas.clip(chunks, c.width - 1), { plugin = t.id })
end

-- Waiting first, by name; then the fired ones in the order they fired; then the rest.
local rank = { queue = 0, waiting = 1, fired = 2, never = 3 }

---@param a cinch.ui.Trigger
---@param b cinch.ui.Trigger
---@return boolean
local function before(a, b)
  local x, y = rank[status(a)], rank[status(b)]
  if x ~= y then
    return x < y
  end
  if x == rank.fired and fired(a) ~= fired(b) then
    return (fired(a) or 0) < (fired(b) or 0)
  end
  return a.value < b.value
end

---@param c cinch.ui.Canvas
---@param ctx cinch.ui.Ctx
---@param key string
---@param icon string
---@param title string
---@param list cinch.ui.Trigger[]
local function section(c, ctx, key, icon, title, list)
  if #list == 0 then
    return
  end
  if #c.lines > 0 then
    c:blank()
  end
  local open = not ctx.folded[key]
  local waiting = #vim.tbl_filter(function(t)
    return status(t) == 'waiting'
  end, list)
  c:add({
    { (open and ' ▾ ' or ' ▸ ') .. icon .. ' ' .. title, 'CinchSection' },
    { ' ' .. #list, 'CinchMuted' },
    { waiting > 0 and ('  %d waiting to fire'):format(waiting) or '', 'CinchWaiting' },
  }, { section = key })
  if open then
    for _, t in ipairs(list) do
      row(c, t)
    end
  end
end

--- The list, `width` cells wide. Each trigger's row maps to its id in c.rows.
---@param width integer
---@param ctx cinch.ui.Ctx
---@return cinch.ui.Canvas
function M.list(width, ctx)
  local c = canvas.new(width)
  local by = {}
  for _, t in ipairs(collect()) do
    by[t.kind] = by[t.kind] or {}
    table.insert(by[t.kind], t)
  end
  local order, titles = {}, {}
  for _, k in ipairs(kinds) do
    order[#order + 1], titles[k[1]] = k[1], k[2]
  end
  local own = vim.tbl_filter(function(k)
    return not titles[k] and k ~= 'queue'
  end, vim.tbl_keys(by))
  table.sort(own)
  for _, kind in ipairs(vim.list_extend(order, own)) do
    local list = by[kind] or {}
    table.sort(list, before)
    section(c, ctx, 'triggers:' .. kind, glyph(kind), titles[kind] or kind, list)
  end
  if #c.lines == 0 then
    c:add({ { ' none of your plugins waits for a trigger', 'CinchMuted' } })
  end
  section(c, ctx, 'triggers:queue', glyph('now'), 'schedule', by.queue or {})
  return c
end

--- The trigger a row stands for.
---@param id? string
---@return cinch.ui.Trigger?
function M.find(id)
  for _, t in ipairs(id and collect() or {}) do
    if t.id == id then
      return t
    end
  end
end

--- The plugins still waiting on a trigger, for `l` to load.
---@param id? string
---@return string[]
function M.waiting(id)
  local t = M.find(id)
  return vim.tbl_map(
    function(p)
      return p.name
    end,
    vim.tbl_filter(function(p)
      return p.state == 'pending'
    end, t and t.plugins or {})
  )
end

-- Pane ----------------------------------------------------------------------------

local key_w = 10

---@param c cinch.ui.Canvas
---@param key string
---@param text string
---@param hl? string
local function kv(c, key, text, hl)
  for i, part in ipairs(canvas.wrap(text, c.width - key_w - 2)) do
    c:add({ { ' ' .. fit(i == 1 and key or '', key_w), 'CinchMuted' }, { part, hl } })
  end
end

--- When the trigger fires, in words, and where :help says more.
---@param t cinch.ui.Trigger
---@return string runs, string? help
local function explain(t)
  if t.kind == 'event' then
    local event, pattern = t.raw:match('^(%S+)%s*(.*)$')
    if event == 'User' then
      return ('When a plugin or your config runs :doautocmd User %s.'):format(pattern), ':h User'
    end
    local words = event_words[event] or 'Neovim fires this event'
    return ('When %s%s.'):format(words, pattern ~= '' and (', for ' .. pattern) or ''), ':h ' .. event
  elseif t.kind == 'ft' then
    return ('When a buffer gets filetype %s, as you open a %s file.'):format(t.value, t.value), ':h filetype'
  elseif t.kind == 'cmd' then
    local text = 'When you run :%s. A stand-in command waits under its name, then runs it again with what you typed.'
    return text:format(t.value), ':h user-commands'
  elseif t.kind == 'keys' then
    local modes = vim.tbl_map(function(m)
      return mode_words[m] or m
    end, t.modes or { 'n' })
    local text = 'When you press %s in %s mode. A stand-in mapping waits on it, then presses it again for you.'
    return text:format(t.value, table.concat(modes, ' or ')), ':h key-notation'
  elseif t.raw == 'now' then
    return 'During startup, before the first screen draws, in the order you declared them. '
      .. 'Each one adds to your startup time.'
  elseif t.raw == 'later' then
    return 'Once the UI is up, a few milliseconds of loading per tick, so startup never waits for them.'
  elseif t.kind == 'queue' then
    return 'Right before the first plugin that needs them, so none loads for nothing.'
  end
  return ('When your own `%s` trigger fires.'):format(t.kind)
end

--- The other triggers that would load `p`, besides `t`.
---@param p cinch.Plugin
---@param t cinch.ui.Trigger
---@return string?
local function also(p, t)
  local parts = {}
  for kind, values in pairs(p.triggers or {}) do
    for _, v in ipairs(values) do
      local raw = type(v) == 'table' and v.lhs or tostring(v)
      if kind .. ' ' .. raw ~= t.id then
        local value = value_of(kind, raw)
        parts[#parts + 1] = glyph(kind) .. ' ' .. (kind == 'cmd' and (':' .. value) or value)
      end
    end
  end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, '  ') or nil
end

--- What happened to one plugin, in words.
---@param p cinch.Plugin
---@param t cinch.ui.Trigger
---@return string text, string group
local function outcome(p, t)
  if waits(p) then
    return p.activity and (p.activity .. '…') or 'waiting', p.activity and 'CinchActive' or 'CinchWaiting'
  elseif p.state == 'failed' then
    return 'failed: ' .. vim.split(p.err or '?', '\n')[1], 'CinchFailed'
  end
  local at = loaded_at(p)
  local when = at and (' at ' .. canvas.ms(at)) or ''
  if p.reason == t.fired_as or (t.kind == 'queue' and (p.reason == 'now' or p.reason == 'later')) then
    return 'loaded' .. when, 'CinchLoaded'
  end
  local by = ({ manual = 'by hand' })[p.reason] or p.reason or '?'
  return ('loaded %s%s'):format(by, when), 'CinchMuted'
end

---@param c cinch.ui.Canvas
---@param t cinch.ui.Trigger
local function plugin_rows(c, t)
  for _, p in ipairs(t.plugins) do
    local d = dot(p)
    local ms = load_ms(p)
    local text, hl = outcome(p, t)
    c:add(
      canvas.clip({
        { ' ' .. d[1] .. ' ', d[2] },
        { p.name, 'CinchName' },
        { p.load == 'now_if_args' and ' now_if_args' or '', 'CinchIconNow' },
        { ms and (' (' .. canvas.ms(ms) .. ')') or '', 'CinchMuted' },
        { '  ' .. text, hl },
      }, c.width - 1),
      { plugin = p.name }
    )
    local other = t.kind ~= 'queue' and also(p, t)
    if other then
      c:add(canvas.clip({ { '     also ', 'CinchMuted' }, { other, 'CinchIconTrigger' } }, c.width - 1))
    end
  end
end

-- The header chip's color, by status.
local chip_hl = { waiting = 'CinchTrigger', fired = 'CinchNow', never = 'CinchLater' }

--- The details of one trigger, `width` cells wide.
---@param id? string
---@param width integer
---@return cinch.ui.Canvas
function M.pane(id, width)
  local c = canvas.new(width)
  local t = M.find(id)
  if not t then
    c:add({ { ' move to a trigger to see what it loads', 'CinchMuted' } })
    return c
  end

  -- What it is, and a chip saying how it stands.
  local s = status(t)
  local word = status_text(t)
  local hl = chip_hl[s] or (word == 'all loaded' and 'CinchNow' or 'CinchTrigger')
  local chip_w = canvas.chip_width(cells(word) + 2)
  local is_queue = t.kind == 'queue'
  local head = {
    { ' ' .. glyph(is_queue and t.raw or t.kind) .. ' ', is_queue and 'CinchIconNow' or 'CinchIconTrigger' },
    { fit(is_queue and t.value or (t.kind .. ' ' .. shown(t)), math.max(1, c.width - chip_w - 5)), 'CinchTitle' },
  }
  c:add(vim.list_extend(head, canvas.chip(word, hl, cells(word) + 2)))
  c:add({ { ' ' .. ('─'):rep(c.width - 2), 'CinchRule' } })

  local runs, help = explain(t)
  kv(c, 'runs', runs)
  if help then
    kv(c, 'help', help, 'CinchKey')
  end
  local n_wait = #vim.tbl_filter(waits, t.plugins)
  local n_loaded = #vim.tbl_filter(function(p)
    return p.state == 'loaded'
  end, t.plugins)
  local counts = ('%d%s%s'):format(
    #t.plugins,
    n_wait > 0 and (' · %d waiting'):format(n_wait) or '',
    n_loaded > 0 and (' · %d loaded'):format(n_loaded) or ''
  )
  kv(c, 'plugins', counts)
  local total = 0
  for _, p in ipairs(t.plugins) do
    total = total + (load_ms(p) or 0)
  end
  if total > 0 then
    kv(c, 'took', canvas.ms(total) .. (t.raw == 'now' and ' of your startup' or ' to load'), 'CinchMuted')
  end
  if s == 'never' then
    kv(c, 'note', 'It never fired: its plugins loaded another way first, so it did nothing this session.', 'CinchWarn')
  elseif n_wait > 0 then
    kv(c, 'try', 'l loads them now', 'CinchMuted')
  end
  c:blank()
  plugin_rows(c, t)
  return c
end

return M
