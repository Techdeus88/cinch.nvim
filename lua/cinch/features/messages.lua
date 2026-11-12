-- Message capture, on by default: cinch decides what you see.
-- Every message cinch sends (Report) comes here, and so does vim.pack's output
-- while cinch is calling it: its progress becomes cinch's own progress message,
-- updated in place, and its notices and git's warnings go to the log. Builds get
-- a progress message each. Everything is kept in M.log for the UI to show.
-- A Report or a Progress that a subscriber shows itself, like the ui feature's
-- window, sets `handled` and is only logged here.

local events = require('cinch.events')

local api = vim.api
local levels = vim.log.levels

local M = {}

local ms ---@type fun(n: number): string defined with the steps below

---@class cinch.messages.Opts
---@field level? integer lowest level shown; lower ones are only logged. Default INFO
---@field progress? boolean show install, update and build progress. Default true
---@field history? integer messages kept in M.log. Default 1000

---@type cinch.messages.Opts
M.opts = { level = levels.INFO, progress = true, history = 1000 }

--- Who logged it: cinch's own messages, vim.pack and git output, or a step:
--- install, update, delete, build, now, later, trigger, dep, manual, state, startup.
---@alias cinch.MessageSource string

---@class cinch.Message
---@field time integer os.time()
---@field level integer
---@field msg string
---@field source cinch.MessageSource
---@field plugin? string the plugin it is about

---@type cinch.Message[]
M.log = {}

local hl = { [levels.ERROR] = 'ErrorMsg', [levels.WARN] = 'WarningMsg' }

-- The functions cinch shows messages with: the ones in place before capture began.
local echo, notify = api.nvim_echo, vim.notify

--- Drop what only matters to a debugger: Lua `file.lua:12:` prefixes and vim.pack's
--- bare `vim.pack:` header line.
---@param msg string
---@return string
local function clean(msg)
  local out = {}
  for _, line in ipairs(vim.split(msg, '\n')) do
    line = line:gsub('%S+%.lua:%d+: ', '')
    if line ~= '' and line ~= 'vim.pack:' then
      out[#out + 1] = line
    end
  end
  return table.concat(out, '\n')
end

---@param level integer
---@param msg string
---@param source cinch.MessageSource
---@param plugin? string
local function record(level, msg, source, plugin)
  msg = clean(msg)
  M.log[#M.log + 1] = { time = os.time(), level = level, msg = msg, source = source, plugin = plugin }
  if #M.log > M.opts.history then
    table.remove(M.log, 1)
  end
  if events.has('Message') then
    events.emit('Message', M.log[#M.log])
  end
end

-- While Neovim starts, the screen is not drawn yet and every message waits for it;
-- more than one line waiting means a "Press ENTER" prompt. So until VimEnter,
-- warnings and errors are held to show as one message, and the rest only go to
-- the log. These hold what waits.
---@type { [1]: integer, [2]: string }[]
local held = {}
---@type table<string, { [1]: string, [2]: string, [3]?: integer }> running progress by key
local held_progress = {}

---@return boolean
local function starting()
  return vim.v.vim_did_enter == 0
end

---@param level integer
---@param msg string
local function show(level, msg)
  if level < M.opts.level then
    return
  end
  if starting() then
    if level >= levels.WARN then
      held[#held + 1] = { level, clean(msg) }
    end
    return
  end
  -- Highlighted as an error, not raised as one: an error echoed while init.lua
  -- runs gets an "Error in init.lua" header that points at the wrong place.
  echo({ { 'cinch: ', hl[level] or 'Title' }, { clean(msg), hl[level] } }, true, {})
end

---@type table<string, integer> progress message id by key: 'pack', or a plugin name for its build
local ids = {}

--- Show or update a progress message. A status other than 'running' ends it.
---@param key string
---@param msg string
---@param status 'running'|'success'|'failed'
---@param percent? integer
local function progress(key, msg, status, percent)
  if not M.opts.progress then
    return
  end
  if starting() then
    -- Only what is still running once startup ends is shown, then.
    held_progress[key] = status == 'running' and { msg, status, percent } or nil
    return
  end
  local done = status ~= 'running'
  ids[key] = echo({ { msg } }, done, {
    kind = 'progress',
    source = 'cinch',
    title = 'cinch',
    status = status,
    percent = percent,
    id = ids[key],
  })
  if done then
    ids[key] = nil
  end
end

-- Capture ---------------------------------------------------------------------

-- Git's stderr, which vim.pack passes on as an unprefixed warning.
local git_prefixes = { 'warning: ', 'hint: ', 'error: ', 'fatal: ' }

---@param msg string
---@return 'vim.pack'|'git'|nil
local function from_pack(msg)
  if msg:find('^vim%.pack: ') then
    return 'vim.pack'
  end
  for _, p in ipairs(git_prefixes) do
    if vim.startswith(msg, p) then
      return 'git'
    end
  end
end

local depth = 0
local echo_wrap, notify_wrap ---@type function, function

---@param chunks [string, any][]
---@param history boolean
---@param o? vim.api.keyset.echo_opts
local function on_echo(chunks, history, o)
  if type(o) ~= 'table' or o.source ~= 'vim.pack' then
    return echo(chunks, history, o)
  end
  local text = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, chunks))
  local status = o.status == 'running' and 'running' or 'success'
  -- "Installing plugins (3/9) - telescope.nvim": the only live per-plugin signal,
  -- since PackChanged fires for the whole batch at its end.
  local title, done, total, name = text:match('^(.-) %((%d+)/(%d+)%)%s*%-?%s*(.*)$')
  local ev = events.has('Progress')
      and events.emit('Progress', {
        title = title or text,
        done = tonumber(done),
        total = tonumber(total),
        name = name ~= '' and name or nil,
        status = status,
        percent = o.percent,
      })
    or {}
  -- A subscriber that shows it, like the open window, sets `handled`.
  if not ev.handled then
    progress('pack', text, status, o.percent)
  end
  if status ~= 'running' then
    record(levels.INFO, text, 'vim.pack')
  end
  return ids.pack or 0
end

---@param msg any
---@param level? integer
---@param o? table
local function on_notify(msg, level, o)
  local source = type(msg) == 'string' and from_pack(msg)
  if not source then
    return notify(msg, level, o)
  end
  local text = msg:gsub('^vim%.pack: ', '')
  level = level or levels.INFO
  -- Notices are logged; warnings and errors are reported, to be shown too.
  if level >= levels.WARN then
    events.emit('Report', { msg = text, level = level, source = source })
  else
    record(level, text, source)
  end
end

--- Route vim.pack's output here while cinch calls it. Calls can nest.
local function capture()
  if depth == 0 then
    echo, notify = api.nvim_echo, vim.notify
    echo_wrap, notify_wrap = on_echo, on_notify
    api.nvim_echo, vim.notify = echo_wrap, notify_wrap
  end
  depth = depth + 1
end

local function release()
  depth = depth - 1
  if depth == 0 then
    -- Leave a replacement made meanwhile alone, such as a notifier plugin's setup.
    if api.nvim_echo == echo_wrap then
      api.nvim_echo = echo
    end
    if vim.notify == notify_wrap then
      vim.notify = notify
    end
  end
end

-- Steps -----------------------------------------------------------------------

---@param n number
---@return string
ms = function(n)
  return n >= 1000 and ('%.2fs'):format(n / 1000) or ('%.1fms'):format(n)
end

--- What loaded a plugin, as a log source: now, later, dep, manual, build, or trigger.
---@param reason string
---@return string
local function kind(reason)
  local k = reason:match('^(%S+)')
  if k == 'now' or k == 'later' or k == 'dep' or k == 'manual' or k == 'build' then
    return k
  end
  return 'trigger'
end

--- What a plugin waits for, read from its spec: "cmd Trouble, keys <leader>xx".
---@param p cinch.Plugin
---@return string
local function waits_for(p)
  if p.when ~= 'trigger' then
    return p.when == 'later' and 'later, after startup' or 'now'
  end
  local parts = {}
  for _, field in ipairs({ 'event', 'ft', 'cmd', 'keys' }) do
    local v = p.data[field]
    for _, x in ipairs(type(v) == 'table' and v or { v }) do
      parts[#parts + 1] = field .. ' ' .. tostring(type(x) == 'table' and x[1] or x)
    end
  end
  return #parts > 0 and table.concat(parts, ', ') or 'a plugin that depends on it'
end

local doing = { install = 'installing', update = 'updating', delete = 'deleting' }
local done = { install = 'installed', update = 'updated', delete = 'deleted' }

--- Every step cinch takes, logged at DEBUG: never on screen, always in the log.
local function log_steps()
  local debug = levels.DEBUG
  local function step(source, msg, plugin)
    record(debug, msg, source, plugin)
  end
  local later_count = 0

  events.on('Phase', function(d)
    step('startup', ('%s took %s'):format(d.name, ms(d.ms)))
  end)
  events.on('State', function(d)
    local p = d.plugin
    if d.to == 'pending' and d.from == 'registered' then
      step('state', ('%s waits for %s'):format(p.name, waits_for(p)), p.name)
    elseif d.to == 'disabled' then
      if d.reason ~= 'unneeded' then
        step(
          'state',
          ('%s is off: %s'):format(p.name, d.reason == 'cond' and 'cond is false' or 'enabled = false'),
          p.name
        )
      end
    end
  end)
  events.on('LoadWait', function(d)
    local whose = d.build == d.plugin and 'its build' or ('the build of ' .. d.build.name)
    step(kind(d.reason), ('%s: %s waits for %s'):format(d.reason, d.plugin.name, whose), d.plugin.name)
  end)
  events.on('LoadPre', function(d)
    if kind(d.reason) == 'trigger' then
      step('trigger', ('%s fired: loading %s'):format(d.reason, d.plugin.name), d.plugin.name)
    end
  end)
  events.on('Load', function(d)
    local k = kind(d.reason)
    if k == 'later' then
      later_count = later_count + 1
    end
    step(
      k,
      ('loaded %s by %s · packadd %s · config %s'):format(d.plugin.name, d.reason, ms(d.ms.packadd), ms(d.ms.config)),
      d.plugin.name
    )
  end)
  events.on('Run', function(d)
    if d.ok then
      step(d.when, ('ran your function at %s · %s'):format(d.where, ms(d.ms)))
    end
  end)
  events.on('Later', function()
    step('later', ('later: %d plugin%s loaded'):format(later_count, later_count == 1 and '' or 's'))
  end)
  events.on('PackPre', function(d)
    step(d.kind, ('%s %s…'):format(doing[d.kind] or d.kind, d.name), d.name)
  end)
  events.on('Pack', function(d)
    step(d.kind, ('%s %s'):format(done[d.kind] or d.kind, d.name), d.name)
  end)
  events.on('PackOp', function(d)
    local what = d.names and (#d.names == 1 and d.names[1] or (#d.names .. ' plugins')) or 'all plugins'
    step('vim.pack', ('vim.pack.%s %s · %s%s'):format(d.op, what, ms(d.ms), d.ok and '' or ' · failed'))
  end)
  events.on('Activity', function(d)
    if d.to == 'building' then
      step('build', ('building %s…'):format(d.plugin.name), d.plugin.name)
    end
  end)
end

-- Setup -------------------------------------------------------------------------

--- Startup is over: show what was held, warnings and errors as one message, then
--- the progress still running.
local function release_held()
  if #held > 0 then
    local chunks = {}
    for i, h in ipairs(held) do
      chunks[#chunks + 1] = { (i > 1 and '\n' or '') .. 'cinch: ', hl[h[1]] }
      chunks[#chunks + 1] = { h[2], hl[h[1]] }
    end
    held = {}
    echo(chunks, true, {})
  end
  local running = held_progress
  held_progress = {}
  for key, pr in pairs(running) do
    progress(key, pr[1], pr[2] --[[@as 'running']], pr[3])
  end
end

---@param opts? cinch.messages.Opts
function M.setup(opts)
  M.opts = vim.tbl_extend('force', M.opts, opts or {})
  if starting() then
    vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = vim.schedule_wrap(release_held) })
  end
  events.define('Message') -- { time, level, msg, source, plugin? }: something was logged
  -- { title, done?, total?, name?, status, percent?, build? }: vim.pack's or a build's progress
  events.define('Progress')

  events.on('Report', function(d)
    record(d.level, d.msg, d.source or 'cinch', d.plugin)
    if not d.handled then
      show(d.level, d.msg)
    end
  end)

  events.on('PackOpPre', capture)
  -- vim.pack schedules its progress reports, the last one after the call
  -- returns; releasing on the next tick lets that one still be captured.
  events.on('PackOp', function()
    vim.schedule(release)
  end)

  --- A build's progress, unless a Progress subscriber shows builds itself.
  ---@param name string
  ---@param msg string
  ---@param status 'running'|'success'|'failed'
  local function build_progress(name, msg, status)
    local ev = events.emit('Progress', { title = msg, name = name, status = status, build = true })
    if not ev.handled then
      progress(name, msg, status)
    end
  end

  events.on('Activity', function(d)
    if d.to == 'building' then
      build_progress(d.plugin.name, 'building ' .. d.plugin.name, 'running')
    end
  end)

  events.on('Build', function(d)
    local name = d.plugin.name
    local msg = d.ok and ('built %s in %s'):format(name, ms(d.ms)) or ('build of %s failed'):format(name)
    build_progress(name, msg, d.ok and 'success' or 'failed')
    record(
      d.ok and levels.INFO or levels.ERROR,
      d.output and d.output ~= '' and (msg .. '\n' .. d.output) or msg,
      'build',
      name
    )
  end)

  log_steps()
end

return M
