-- Message capture, on by default: cinch decides what you see.
-- Every message cinch sends (Report) comes here, and so does vim.pack's output
-- while cinch is calling it: its progress becomes cinch's own progress message,
-- updated in place, and its notices and git's warnings go to the log. Builds get
-- a progress message each. Everything is kept in M.log for the UI to show.

local events = require('cinch.events')

local api = vim.api
local levels = vim.log.levels

local M = {}

---@class cinch.messages.Opts
---@field level? integer lowest level shown; lower ones are only logged. Default INFO
---@field progress? boolean show install, update and build progress. Default true
---@field history? integer messages kept in M.log. Default 200

---@type cinch.messages.Opts
M.opts = { level = levels.INFO, progress = true, history = 200 }

---@alias cinch.MessageSource 'cinch'|'vim.pack'|'git'|'build'

---@class cinch.Message
---@field time integer os.time()
---@field level integer
---@field msg string
---@field source cinch.MessageSource

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
local function record(level, msg, source)
  msg = clean(msg)
  M.log[#M.log + 1] = { time = os.time(), level = level, msg = msg, source = source }
  if #M.log > M.opts.history then
    table.remove(M.log, 1)
  end
  if events.has('Message') then
    events.emit('Message', M.log[#M.log])
  end
end

---@param level integer
---@param msg string
local function show(level, msg)
  -- Highlighted as an error, not raised as one: an error echoed while init.lua
  -- runs gets an "Error in init.lua" header that points at the wrong place.
  if level >= M.opts.level then
    echo({ { 'cinch: ', hl[level] or 'Title' }, { clean(msg), hl[level] } }, true, {})
  end
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
  progress('pack', text, status, o.percent)
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
  record(level or levels.INFO, text, source)
  -- Notices are logged; warnings and errors are shown too.
  if (level or levels.INFO) >= levels.WARN then
    show(level or levels.INFO, text)
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

-- Setup -------------------------------------------------------------------------

---@param opts? cinch.messages.Opts
function M.setup(opts)
  M.opts = vim.tbl_extend('force', M.opts, opts or {})
  events.define('Message') -- { time, level, msg, source }: something was logged

  events.on('Report', function(d)
    record(d.level, d.msg, 'cinch')
    show(d.level, d.msg)
  end)

  events.on('PackOpPre', capture)
  -- vim.pack schedules its progress reports, the last one after the call
  -- returns; releasing on the next tick lets that one still be captured.
  events.on('PackOp', function()
    vim.schedule(release)
  end)

  events.on('Activity', function(d)
    if d.to == 'building' then
      progress(d.plugin.name, 'building ' .. d.plugin.name, 'running')
    end
  end)

  events.on('Build', function(d)
    local name, ms = d.plugin.name, math.floor(d.ms + 0.5)
    local msg = d.ok and ('built %s in %dms'):format(name, ms) or ('build of %s failed'):format(name)
    progress(name, msg, d.ok and 'success' or 'failed')
    record(
      d.ok and levels.INFO or levels.ERROR,
      d.output and d.output ~= '' and (msg .. '\n' .. d.output) or msg,
      'build'
    )
  end)
end

return M
