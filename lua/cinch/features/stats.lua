-- Stats: what cinch did this session and what it cost. Everything comes from the
-- bus; counts of plugins by state and by `when` are read from the registry when
-- asked, so nothing is tracked twice. One summary per session is appended to a
-- history file at exit, and read only when asked for.

local events = require('cinch.events')
local state = require('cinch.state')

local uv = vim.uv

local M = {}

---@class cinch.stats.Opts
---@field persist? boolean keep one summary per session in stdpath('state')/cinch/stats.json. Default true
---@field history? integer sessions kept. Default 50

---@type cinch.stats.Opts
M.opts = { persist = true, history = 50 }

M.file = vim.fs.joinpath(vim.fn.stdpath('state') --[[@as string]], 'cinch', 'stats.json')

-- When Neovim started. It has no API for that, so ask the OS: on macOS sysctl,
-- on Linux /proc. Elsewhere, or if that fails, fall back to the CPU time used so
-- far, which reads a few ms late. From packman's clock.lua.

---@return number ms since the epoch
local function wall_ms()
  local sec, usec = uv.gettimeofday()
  return sec * 1e3 + usec / 1e3
end

--- macOS: kinfo_proc starts with the process start time, a timeval.
---@return number? ms since the process started
local function darwin()
  local ffi = require('ffi')
  pcall(
    ffi.cdef,
    [[
    int sysctl(int *name, unsigned int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
    int getpid(void);
  ]]
  )
  local mib = ffi.new('int[4]', { 1, 14, 1, ffi.C.getpid() }) -- CTL_KERN, KERN_PROC, KERN_PROC_PID
  local size = 1024 -- sizeof(struct kinfo_proc) is 648
  local buf, len = ffi.new('uint8_t[?]', size), ffi.new('size_t[1]', size)
  if ffi.C.sysctl(mib, 4, buf, len, nil, 0) ~= 0 or len[0] < 16 then
    return
  end
  local sec = tonumber(ffi.cast('int64_t *', buf)[0])
  local usec = tonumber(ffi.cast('int32_t *', buf + 8)[0])
  return wall_ms() - (sec * 1e3 + usec / 1e3)
end

--- Linux: field 22 of /proc/self/stat is the start time in clock ticks after boot.
---@return number? ms since the process started
local function linux()
  local stat, up = io.open('/proc/self/stat'), io.open('/proc/uptime')
  local line, uptime = stat and stat:read('*l'), up and up:read('*n')
  if stat then
    stat:close()
  end
  if up then
    up:close()
  end
  -- The command name in parentheses may hold spaces; count fields after it.
  local rest = line and line:match('%) (.*)$')
  local ticks = rest and tonumber(vim.split(rest, ' ', { plain = true })[20])
  if not (ticks and uptime) then
    return
  end
  local ffi = require('ffi')
  pcall(ffi.cdef, 'long sysconf(int name);')
  local hz = tonumber(ffi.C.sysconf(2)) or 100 -- _SC_CLK_TCK
  return (uptime - ticks / hz) * 1e3
end

---@type 'os'|'cpu' where the start time came from
M.source = 'cpu'

local start ---@type integer hrtime when Neovim started
do
  local sysname = uv.os_uname().sysname
  local get = sysname == 'Darwin' and darwin or sysname == 'Linux' and linux or nil
  local ok, ms = false, nil
  if get then
    ok, ms = pcall(get)
  end
  -- Sane: a number, positive, and less than a day.
  if ok and type(ms) == 'number' and ms == ms and ms > 0 and ms < 864e5 then
    M.source = 'os'
  else
    local ru = uv.getrusage()
    ms = ru and (ru.utime.sec + ru.stime.sec) * 1e3 + (ru.utime.usec + ru.stime.usec) / 1e3 or 0
  end
  start = uv.hrtime() - ms * 1e6
end

--- Milliseconds since Neovim started.
---@return number
function M.now()
  return (uv.hrtime() - start) / 1e6
end

---@class cinch.stats.Plugin
---@field order integer
---@field reason string
---@field at number ms since start when it finished loading
---@field packadd number ms
---@field config number ms: opts, config and after
---@field build? number ms of its last build
---@field build_ok? boolean

---@type table<string, cinch.stats.Plugin>
M.plugins = {}
---@type table<string, number> startup phase -> ms
M.phases = {}
---@type table<string, number> moment -> ms since start: setup, vimenter, uienter, later
M.marks = {}
---@type { op: string, count: integer, ms: number, ok: boolean, at: number }[]
M.ops = {}
---@type table<string, integer> install, update, delete -> count
M.disk = { install = 0, update = 0, delete = 0 }

--- The kind of thing that loaded a plugin: now, later, event, ft, cmd, keys, dep, manual.
---@param reason string
---@return string
local function kind(reason)
  local k = reason:match('^(%S+)')
  if k == 'event' and reason:find('^event FileType ') then
    return 'ft'
  end
  return k == 'dep' and 'dep' or k or '?'
end

--- This session at a glance.
---@return table
function M.summary()
  local s = {
    plugins = { total = #state.list },
    by_state = {},
    by_when = { now = 0, later = 0, trigger = 0 },
    loaded_by = {},
    startup = {
      vimenter = M.marks.vimenter,
      uienter = M.marks.uienter,
      later_done = M.marks.later,
      phases = M.phases,
      cinch = 0,
    },
    load = { packadd = 0, config = 0, slowest = {} },
    disk = M.disk,
    ops = #M.ops,
  }
  for _, ms in pairs(M.phases) do
    s.startup.cinch = s.startup.cinch + ms
  end
  for _, p in ipairs(state.list) do
    s.by_state[p.state] = (s.by_state[p.state] or 0) + 1
    if p.when then
      s.by_when[p.when] = s.by_when[p.when] + 1
    end
  end
  local slowest = {}
  for name, r in pairs(M.plugins) do
    local k = kind(r.reason)
    s.loaded_by[k] = (s.loaded_by[k] or 0) + 1
    s.load.packadd = s.load.packadd + r.packadd
    s.load.config = s.load.config + r.config
    slowest[#slowest + 1] = { name = name, ms = r.packadd + r.config }
  end
  table.sort(slowest, function(a, b)
    return a.ms > b.ms
  end)
  s.load.slowest = vim.list_slice(slowest, 1, 5)
  return s
end

--- Past sessions, oldest first.
---@return table[]
function M.history()
  local f = io.open(M.file)
  if not f then
    return {}
  end
  local ok, list = pcall(vim.json.decode, f:read('*a'))
  f:close()
  return ok and type(list) == 'table' and list or {}
end

local function save()
  local s = M.summary()
  local list = M.history()
  list[#list + 1] = {
    time = os.time(),
    startup = s.startup.uienter or s.startup.vimenter,
    cinch = s.startup.cinch,
    plugins = s.plugins.total,
    loaded_at_startup = (s.loaded_by.now or 0),
  }
  while #list > M.opts.history do
    table.remove(list, 1)
  end
  vim.fn.mkdir(vim.fs.dirname(M.file), 'p')
  local f = io.open(M.file, 'w')
  if f then
    f:write(vim.json.encode(list))
    f:close()
  end
end

---@param ms? number
---@return string
local function fmt(ms)
  return ms and ('%.1fms'):format(ms) or '-'
end

--- Lines for `:Cinch stats`.
---@return string[]
function M.lines()
  local s = M.summary()
  local st = s.startup
  local lines = {
    ('plugins     %d: %s'):format(s.plugins.total, vim.inspect(s.by_state, { newline = ' ', indent = '' })),
    ('when        now %d · later %d · trigger %d'):format(s.by_when.now, s.by_when.later, s.by_when.trigger),
    ('loaded by   %s'):format(vim.inspect(s.loaded_by, { newline = ' ', indent = '' })),
    ('startup     VimEnter %s · UIEnter %s · later done %s'):format(
      fmt(st.vimenter),
      fmt(st.uienter),
      fmt(st.later_done)
    ),
    ('cinch       %s: specs %s · install %s · init %s · now %s'):format(
      fmt(st.cinch),
      fmt(M.phases.specs),
      fmt(M.phases.install),
      fmt(M.phases.init),
      fmt(M.phases.now)
    ),
    ('loading     packadd %s · config %s'):format(fmt(s.load.packadd), fmt(s.load.config)),
    ('disk        installed %d · updated %d · deleted %d · %d vim.pack calls'):format(
      s.disk.install,
      s.disk.update,
      s.disk.delete,
      s.ops
    ),
  }
  for i, p in ipairs(s.load.slowest) do
    local r = M.plugins[p.name]
    lines[#lines + 1] = ('%s %-24s %s (packadd %s · config %s) by %s'):format(
      i == 1 and 'slowest    ' or '           ',
      p.name,
      fmt(p.ms),
      fmt(r.packadd),
      fmt(r.config),
      r.reason
    )
  end
  return lines
end

-- `:Cinch stats`, found by command.lua.
M.command = {
  run = function()
    vim.api.nvim_echo({ { table.concat(M.lines(), '\n') } }, false, {})
  end,
}

---@param opts? cinch.stats.Opts
function M.setup(opts)
  M.opts = vim.tbl_extend('force', M.opts, opts or {})
  -- Features load first in setup(), so this is when cinch began.
  M.marks.setup = M.now()

  events.on('Phase', function(d)
    M.phases[d.name] = (M.phases[d.name] or 0) + d.ms
  end)
  events.on('Load', function(d)
    M.plugins[d.plugin.name] = {
      order = d.plugin.order,
      reason = d.reason,
      at = M.now(),
      packadd = d.ms.packadd,
      config = d.ms.config,
    }
  end)
  events.on('Build', function(d)
    local r = M.plugins[d.plugin.name]
    if r then
      r.build, r.build_ok = d.ms, d.ok
    end
  end)
  events.on('PackOp', function(d)
    M.ops[#M.ops + 1] = { op = d.op, count = d.names and #d.names or 0, ms = d.ms, ok = d.ok, at = M.now() }
  end)
  events.on('Pack', function(d)
    M.disk[d.kind] = (M.disk[d.kind] or 0) + 1
  end)
  events.on('Later', function()
    M.marks.later = M.now()
  end)

  local group = vim.api.nvim_create_augroup('cinch_stats', { clear = true })
  vim.api.nvim_create_autocmd('VimEnter', {
    group = group,
    once = true,
    callback = function()
      M.marks.vimenter = M.now()
    end,
  })
  vim.api.nvim_create_autocmd('UIEnter', {
    group = group,
    once = true,
    callback = function()
      M.marks.uienter = M.now()
    end,
  })
  if M.opts.persist then
    vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = save })
  end
end

return M
