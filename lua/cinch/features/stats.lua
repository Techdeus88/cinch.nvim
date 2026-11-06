-- Stats: what cinch did this session and what it cost. Everything comes from the
-- bus; counts of plugins by state and by `when` are read from the registry when
-- asked, so nothing is tracked twice. One summary per session is appended to a
-- history file at exit, and read only when asked for. For the Profile view it also
-- times every phase, plugin load and sourced file, and nests them by time.

local events = require('cinch.events')
local state = require('cinch.state')

local uv = vim.uv

local M = {}

---@class cinch.stats.Opts
---@field persist? boolean keep one summary per session in stdpath('state')/cinch/stats.json. Default true
---@field history? integer sessions kept. Default 50
---@field profile? boolean|'functions' time every phase, plugin load, step and sourced file for the Profile
--- view. 'functions' also times every Lua function that runs during startup and plugin loads,
--- which makes those slower. Default true

---@type cinch.stats.Opts
M.opts = { persist = true, history = 50, profile = true }

M.file = vim.fs.joinpath(vim.fn.stdpath('state') --[[@as string]], 'cinch', 'stats.json')

-- When Neovim started. It has no API for that, so ask the OS: on macOS sysctl,
-- on Linux /proc, on Windows GetProcessTimes. Elsewhere, or if that fails, fall back
-- to the CPU time used so far, which reads a few ms late. From packman's clock.lua.

---@return number ms since the epoch
local function wall_ms()
  local sec, usec = uv.gettimeofday()
  return sec * 1e3 + usec / 1e3
end

-- sizeof(struct kinfo_proc) on macOS: 648 bytes, checked on macOS 27 with a C probe
-- (sizeof, offsetof and sysctl agree). Its first field is p_starttime, a timeval.
local KINFO_PROC_SIZE = 648

--- macOS: sysctl KERN_PROC_PID fills in one kinfo_proc. The offsets are read only when
--- the kernel wrote exactly the size they were checked against; any other size is a
--- layout this code does not know, so it falls back. (A length query with no buffer
--- is only an estimate for process lists, so the size is checked on the real reply.)
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
  local buf, len = ffi.new('uint8_t[?]', KINFO_PROC_SIZE), ffi.new('size_t[1]', KINFO_PROC_SIZE)
  if ffi.C.sysctl(mib, 4, buf, len, nil, 0) ~= 0 or len[0] ~= KINFO_PROC_SIZE then
    return
  end
  local sec = tonumber(ffi.cast('int64_t *', buf)[0])
  local usec = tonumber(ffi.cast('int32_t *', buf + 8)[0])
  return wall_ms() - (sec * 1e3 + usec / 1e3)
end

--- Windows: GetProcessTimes gives the creation time of this process as a FILETIME,
--- 100 ns ticks since 1601-01-01 UTC. Converted to the Unix epoch, as wall_ms is.
---@return number? ms since the process started
local function windows()
  local ffi = require('ffi')
  pcall(
    ffi.cdef,
    [[
    typedef struct { uint32_t dwLowDateTime; uint32_t dwHighDateTime; } FILETIME;
    void *__stdcall GetCurrentProcess(void);
    int __stdcall GetProcessTimes(void *proc, FILETIME *created, FILETIME *exited, FILETIME *kernel, FILETIME *user);
  ]]
  )
  local k32 = ffi.load('kernel32')
  local created, exited = ffi.new('FILETIME'), ffi.new('FILETIME')
  local kernel, user = ffi.new('FILETIME'), ffi.new('FILETIME')
  if k32.GetProcessTimes(k32.GetCurrentProcess(), created, exited, kernel, user) == 0 then
    return
  end
  local ms_since_1601 = (tonumber(created.dwHighDateTime) * 4294967296 + tonumber(created.dwLowDateTime)) / 1e4
  -- 1601-01-01 to 1970-01-01 is 11644473600 seconds.
  return wall_ms() - (ms_since_1601 - 11644473600000)
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
  local get = sysname == 'Darwin' and darwin
    or sysname == 'Linux' and linux
    or sysname == 'Windows_NT' and windows
    or nil
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

---@class cinch.stats.Span
---@field kind 'phase'|'plugin'|'file'|'step'|'run'|'build'|'op'
---@field name string the phase, plugin, step, file's full path, function's place or op
---@field start number ms since start
---@field stop? number ms since start; nil while it runs
---@field reason? string what loaded the plugin; for a step, its plugin; for a run, now or later
---@field failed? boolean it failed
---@field async? boolean a build or vim.pack op: runs beside everything else, so it holds nothing

---@class cinch.stats.Timed
---@field first number ms since start of its first call
---@field calls integer
---@field ms number all its calls together
---@field max number its slowest call
---@field failed integer calls that raised

--- Functions wrapped with cinch.time(), by name: totals, not one span a call, so one
--- that runs on every keystroke cannot crowd out the rest.
---@type table<string, cinch.stats.Timed>
M.timed = {}

--- Everything the Profile view shows, in the order it began.
---@type cinch.stats.Span[]
M.spans = {}
-- Enough for any startup; past it, nothing more is kept.
local MAX_SPANS = 5000

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
    plugins = { total = #state.yours() },
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
  for _, p in ipairs(state.yours()) do
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

-- Profile ------------------------------------------------------------------------

---@class cinch.stats.Node
---@field kind 'group'|'owner'|'phase'|'plugin'|'file'|'step'|'run'|'build'|'op'|'func'|'timed'
---@field name string what it is: a phase, plugin, owner or group name, or a file's path
---@field label string how it reads: a file relative to its owner
---@field start number ms since start
---@field ms number
---@field reason? string what loaded the plugin
---@field failed? boolean
---@field calls? integer for a function: how many times it ran
---@field total? number for a function: ms with what it called; `ms` is its own time
---@field max? number for a timed function: its slowest call; `ms` is all of them
---@field stop? number ms since start, only while the tree is built
---@field children cinch.stats.Node[]

--- Where a sourced file comes from, for grouping: a plugin by name, `runtime`, `config`,
--- or the directory it sits in. Returns that owner and the file's path inside it.
---@return fun(path: string): string, string
local function owners()
  local roots = {}
  local function root(dir, name)
    if dir and dir ~= '' then
      roots[#roots + 1] = { dir = vim.fs.normalize(dir) .. '/', name = name }
      local real = uv.fs_realpath(dir)
      if real and real ~= dir then
        roots[#roots + 1] = { dir = real .. '/', name = name }
      end
    end
  end
  for _, p in ipairs(state.list) do
    root(p.path, p.name)
  end
  root(vim.env.VIMRUNTIME, 'runtime')
  root(vim.fn.stdpath('config') --[[@as string]], 'config')
  -- Longest first, so a plugin inside another root wins.
  table.sort(roots, function(a, b)
    return #a.dir > #b.dir
  end)
  return function(path)
    for _, r in ipairs(roots) do
      if vim.startswith(path, r.dir) then
        return r.name, path:sub(#r.dir + 1)
      end
    end
    -- Some other directory on the runtimepath: named after the one above plugin/ or lua/.
    for _, pat in ipairs({ '^(.*)/(after/plugin/.*)$', '^(.*)/(plugin/.*)$', '^(.*)/(lua/.*)$' }) do
      local dir, rest = path:match(pat)
      if dir then
        return vim.fs.basename(dir), rest
      end
    end
    return vim.fs.dirname(path), vim.fs.basename(path)
  end
end

--- A node with `children` and no ms of its own: it costs what they cost.
---@param of 'group'|'owner'
---@param name string
---@param children cinch.stats.Node[]
---@return cinch.stats.Node
local function bundle(of, name, children)
  local ms = 0
  for _, c in ipairs(children) do
    ms = ms + c.ms
  end
  return { kind = of, name = name, label = name, start = children[1].start, ms = ms, children = children }
end

--- Sourced files with no parent, grouped by owner in the order each owner first appears.
---@param files cinch.stats.Node[]
---@param owner_of fun(path: string): string, string
---@return cinch.stats.Node[]
local function by_owner(files, owner_of)
  local order, of = {}, {}
  for _, f in ipairs(files) do
    local owner = owner_of(f.name)
    if not of[owner] then
      of[owner] = {}
      order[#order + 1] = owner
    end
    table.insert(of[owner], f)
  end
  return vim.tbl_map(function(owner)
    return bundle('owner', owner, of[owner])
  end, order)
end

-- Functions ----------------------------------------------------------------------

---@class cinch.stats.Func
---@field source string the file, or what load() was given
---@field line integer where it is defined
---@field name? string what its first caller called it
---@field first number ms since start it first ran
---@field calls integer
---@field self integer ns in it, less what it called
---@field total integer ns in it, with what it called; recursion counted once

--- Every Lua function that ran while the profiler was on, by function. false: not
--- timed (a C function).
---@type table<function, cinch.stats.Func|false>
M.funcs = {}
-- Shown per owner, the slowest first; the rest are summed into one entry.
local FUNCS_SHOWN = 40

local hrtime, getinfo = uv.hrtime, debug.getinfo

---@class cinch.stats.Frame
---@field f function
---@field r cinch.stats.Func
---@field t integer hrtime it began
---@field child integer ns spent in what it called

local frames = {} ---@type cinch.stats.Frame[]
local depth = {} ---@type table<function, integer> times on the stack, for recursion

--- Pop the frames above `i`, and `i`, as ended at `t`.
---@param i integer
---@param t integer
local function close(i, t)
  for j = #frames, i, -1 do
    local fr = frames[j]
    frames[j] = nil
    local dt = t - fr.t
    fr.r.self = fr.r.self + dt - fr.child
    local d = depth[fr.f] - 1
    depth[fr.f] = d
    if d == 0 then
      fr.r.total = fr.r.total + dt
    end
    local parent = frames[j - 1]
    if parent then
      parent.child = parent.child + dt
    end
  end
end

--- The call and return hook. LuaJIT fires `call` but no `return` for a tail call, so a
--- call whose caller is a timed function lower on the stack first ends what sits above it.
---@param e 'call'|'return'
local function on_call(e)
  local t = hrtime()
  local info = getinfo(2, 'f')
  local f = info and info.func
  if not f then
    return
  end
  local r = M.funcs[f]
  if e ~= 'call' then
    if r then
      for i = #frames, 1, -1 do
        if frames[i].f == f then
          return close(i, t)
        end
      end
    end
    return
  end
  if r == false then
    return
  end
  if not r then
    local i = getinfo(2, 'nS')
    if i.what == 'C' then
      M.funcs[f] = false
      return
    end
    r = {
      source = i.source,
      line = i.linedefined,
      name = i.name,
      first = (t - start) / 1e6,
      calls = 0,
      self = 0,
      total = 0,
    }
    M.funcs[f] = r
  end
  local up = getinfo(3, 'f')
  local caller = up and up.func
  local top = frames[#frames]
  if top and caller and top.f ~= caller and M.funcs[caller] then
    for i = #frames - 1, 1, -1 do
      if frames[i].f == caller then
        close(i + 1, t)
        break
      end
    end
  end
  r.calls = r.calls + 1
  depth[f] = (depth[f] or 0) + 1
  -- After the hook's own work, so that is not counted as the function's.
  frames[#frames + 1] = { f = f, r = r, t = hrtime(), child = 0 }
end

local hooked = false
local window ---@type fun() turns the function hook on or off for what is happening now

---@param on boolean
local function hook(on)
  if on == hooked then
    return
  end
  hooked = on
  if on then
    debug.sethook(on_call, 'cr')
  else
    debug.sethook()
    close(1, hrtime())
  end
end

--- The functions as owner nodes, each holding its slowest functions by their own time.
---@param owner_of fun(path: string): string, string
---@return cinch.stats.Node[]
local function functions(owner_of)
  local of, order = {}, {}
  local at = {} ---@type table<string, cinch.stats.Node> closures made at one place are one entry
  for _, r in pairs(M.funcs) do
    local key = r and ('%s:%d'):format(r.source, r.line) or ''
    local same = at[key]
    if not r then
      -- A C function: never timed.
    elseif same then
      same.ms, same.total, same.calls = same.ms + r.self / 1e6, same.total + r.total / 1e6, same.calls + r.calls
      same.start = math.min(same.start, r.first)
    elseif r.calls > 0 then
      local path = r.source:match('^@(.*)') or r.source
      local owner, rel = 'other', r.source
      if path:find('^/') or path:find('^%a:[/\\]') then
        owner, rel = owner_of(vim.fs.normalize(path))
      elseif path:find('^vim[/.]') then
        -- Neovim's own modules, built into the binary: vim/_core/shared and the like.
        owner, rel = 'runtime', path
      end
      if not of[owner] then
        of[owner] = {}
        order[#order + 1] = owner
      end
      at[key] = {
        kind = 'func',
        name = key,
        label = ('%s  %s:%d'):format(r.line == 0 and 'main chunk' or r.name or '?', rel, r.line),
        start = r.first,
        ms = r.self / 1e6,
        total = r.total / 1e6,
        calls = r.calls,
        children = {},
      }
      table.insert(of[owner], at[key])
    end
  end
  local out = {}
  for _, owner in ipairs(order) do
    local list = of[owner]
    table.sort(list, function(a, b)
      return a.ms > b.ms
    end)
    if #list > FUNCS_SHOWN then
      local dropped = #list - FUNCS_SHOWN
      local rest =
        { kind = 'func', name = owner .. ' rest', start = math.huge, ms = 0, total = 0, calls = 0, children = {} }
      for i = FUNCS_SHOWN + 1, #list do
        local n = list[i]
        rest.ms, rest.total, rest.calls = rest.ms + n.ms, rest.total + n.total, rest.calls + n.calls
        rest.start = math.min(rest.start, n.start)
        list[i] = nil
      end
      rest.label = ('%d more'):format(dropped)
      table.sort(list, function(a, b)
        return a.start < b.start
      end)
      list[#list + 1] = rest
    else
      table.sort(list, function(a, b)
        return a.start < b.start
      end)
    end
    out[#out + 1] = bundle('owner', owner, list)
  end
  table.sort(out, function(a, b)
    return a.start < b.start
  end)
  return out
end

--- This session as a tree: each span inside the one it ran within, then the top level
--- in groups: cinch's own startup, the `now` plugins and functions, the plugin/ files
--- Neovim sourced at startup, the `later` queue, everything after, builds and vim.pack
--- runs, and with profile = 'functions' every Lua function.
---@return cinch.stats.Node[]
function M.profile()
  local now = M.now()
  local owner_of = owners()
  ---@type cinch.stats.Node[]
  local nodes, disk = {}, {}
  for _, s in ipairs(M.spans) do
    local stop = s.stop or now
    local label = s.name
    if s.kind == 'file' then
      local _, rel = owner_of(s.name)
      label = rel
    elseif s.kind == 'run' then
      label = s.reason .. ' ' .. s.name
    elseif s.kind == 'step' and s.name == 'init' then
      -- Under the init phase, not its plugin: say whose it is.
      label = 'init ' .. s.reason
    end
    table.insert(s.async and disk or nodes, {
      kind = s.kind,
      name = s.name,
      label = label,
      start = s.start,
      stop = stop,
      ms = stop - s.start,
      reason = s.reason,
      failed = s.failed,
      children = {},
    })
  end
  -- Earlier first; of two that start together, the longer holds the other.
  table.sort(nodes, function(a, b)
    if a.start ~= b.start then
      return a.start < b.start
    end
    return a.stop > b.stop
  end)
  local roots, stack = {}, {}
  for _, n in ipairs(nodes) do
    while #stack > 0 and n.stop > stack[#stack].stop do
      stack[#stack] = nil
    end
    local parent = stack[#stack]
    table.insert(parent and parent.children or roots, n)
    stack[#stack + 1] = n
  end
  for _, n in ipairs(nodes) do
    n.stop = nil
  end
  for _, n in ipairs(disk) do
    n.stop = nil
  end

  local enter = M.marks.uienter or M.marks.vimenter
  local cinch, now_, startup_files, later, after = {}, {}, {}, {}, {}
  for _, n in ipairs(roots) do
    if n.kind == 'phase' and n.name == 'now' then
      -- One of the four ways a plugin loads, like `later`: a group of its own.
      now_[#now_ + 1] = n
    elseif n.kind == 'phase' and not (M.marks.done and n.start > M.marks.done) then
      cinch[#cinch + 1] = n
    elseif n.kind == 'file' and not (M.marks.vimenter and n.start > M.marks.vimenter) then
      startup_files[#startup_files + 1] = n
    elseif
      (n.kind == 'plugin' or n.kind == 'run')
      and n.reason == 'later'
      and not (M.marks.later and n.start > M.marks.later)
    then
      later[#later + 1] = n
    else
      after[#after + 1] = n
    end
  end
  local out = {}
  if #cinch > 0 then
    out[#out + 1] = bundle('group', 'cinch', cinch)
  end
  if #now_ > 0 then
    -- The phase's own time, which counts cinch's work between the plugins too.
    local g = { kind = 'group', name = 'now', label = 'now', start = now_[1].start, ms = 0, children = {} }
    for _, phase in ipairs(now_) do
      g.ms = g.ms + phase.ms
      vim.list_extend(g.children, phase.children)
    end
    out[#out + 1] = g
  end
  if #startup_files > 0 then
    out[#out + 1] = bundle('group', 'plugin files at startup', by_owner(startup_files, owner_of))
  end
  if #later > 0 then
    local g = bundle('group', 'later', later)
    g.start = enter or g.start
    out[#out + 1] = g
  end
  if #after > 0 then
    local plugins, files = {}, {}
    for _, n in ipairs(after) do
      table.insert(n.kind == 'file' and files or plugins, n)
    end
    vim.list_extend(plugins, by_owner(files, owner_of))
    table.sort(plugins, function(a, b)
      return a.start < b.start
    end)
    out[#out + 1] = bundle('group', 'after startup', plugins)
  end
  local timed = {}
  for name, r in pairs(M.timed) do
    timed[#timed + 1] = {
      kind = 'timed',
      name = name,
      label = name,
      start = r.first,
      ms = r.ms,
      calls = r.calls,
      max = r.max,
      failed = r.failed > 0 or nil,
      children = {},
    }
  end
  if #timed > 0 then
    table.sort(timed, function(a, b)
      return a.start < b.start
    end)
    out[#out + 1] = bundle('group', 'timed', timed)
  end
  if #disk > 0 then
    out[#out + 1] = bundle('group', 'builds and vim.pack', disk)
  end
  local funcs = functions(owner_of)
  if #funcs > 0 then
    out[#out + 1] = bundle('group', 'functions', funcs)
  end
  return out
end

--- Time phases, plugin loads, and every file sourced during startup or while a plugin
--- loads, for M.profile().
local function record()
  local spans = M.spans
  ---@param span cinch.stats.Span
  ---@return boolean kept
  local function keep(span)
    if #spans >= MAX_SPANS then
      return false
    end
    spans[#spans + 1] = span
    return true
  end

  events.on('Phase', function(d)
    local stop = M.now()
    keep({ kind = 'phase', name = d.name, start = d.start and (d.start - start) / 1e6 or stop - d.ms, stop = stop })
  end)

  -- A finished piece of work, `ms` long, that ended just now.
  ---@param span table a cinch.stats.Span but for its start and stop
  ---@param ms number
  local function ended(span, ms)
    span.stop = M.now()
    span.start = span.stop - ms
    keep(span --[[@as cinch.stats.Span]])
  end
  events.on('Step', function(d)
    local s = (d.start - start) / 1e6
    keep({ kind = 'step', name = d.name, reason = d.plugin.name, start = s, stop = s + d.ms, failed = not d.ok or nil })
  end)
  events.on('Run', function(d)
    ended({ kind = 'run', name = d.where, reason = d.when, failed = not d.ok or nil }, d.ms)
  end)
  events.on('Time', function(d)
    local r = M.timed[d.name]
    if not r then
      r = { first = (d.start - start) / 1e6, calls = 0, ms = 0, max = 0, failed = 0 }
      M.timed[d.name] = r
    end
    r.calls, r.ms, r.max = r.calls + 1, r.ms + d.ms, math.max(r.max, d.ms)
    r.failed = r.failed + (d.ok and 0 or 1)
  end)
  events.on('Build', function(d)
    ended({ kind = 'build', name = 'build ' .. d.plugin.name, failed = not d.ok or nil, async = true }, d.ms)
  end)
  events.on('PackOp', function(d)
    local n = d.names and #d.names
    local what = not n and 'all' or n == 1 and d.names[1] or ('%d plugins'):format(n)
    ended({ kind = 'op', name = ('%s %s'):format(d.op, what), failed = not d.ok or nil, async = true }, d.ms)
  end)

  local loading = {} ---@type table<cinch.Plugin, cinch.stats.Span>
  local busy = 0 -- plugins loading right now

  -- Functions are timed when files are: during startup, then while a plugin loads.
  local fns = M.opts.profile == 'functions'
  function window()
    hook(fns and not (M.marks.later and busy == 0))
  end
  window()
  events.on('Later', window)
  events.on('State', function(d)
    local p = d.plugin
    if d.to == 'loading' and not p.self then
      local span = { kind = 'plugin', name = p.name, start = M.now(), reason = d.reason }
      if keep(span) then
        loading[p], busy = span, busy + 1
      end
    elseif d.from == 'loading' and loading[p] then
      loading[p].stop, loading[p].failed = M.now(), d.to == 'failed' or nil
      loading[p], busy = nil, busy - 1
    end
    window()
  end)

  -- Files sourced during startup, and later only while a plugin loads: an ftplugin a
  -- buffer sources an hour in is not cinch's to show.
  local open = {} ---@type cinch.stats.Span[] files being sourced, innermost last
  local group_id = vim.api.nvim_create_augroup('cinch_stats_profile', { clear = true })
  vim.api.nvim_create_autocmd('SourcePre', {
    group = group_id,
    callback = function(ev)
      if M.marks.later and busy == 0 then
        return
      end
      local span = { kind = 'file', name = ev.match, start = M.now() }
      if keep(span) then
        open[#open + 1] = span
      end
    end,
  })
  vim.api.nvim_create_autocmd('SourcePost', {
    group = group_id,
    callback = function(ev)
      -- SourcePost comes even when the file fails; match it to its SourcePre.
      for i = #open, 1, -1 do
        if open[i].name == ev.match then
          open[i].stop = M.now()
          for j = #open, i, -1 do
            open[j] = nil
          end
          return
        end
      end
    end,
  })
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
    -- cinch itself is in no count: it was running before anything loaded.
    if d.plugin.self then
      return
    end
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
  events.on('Done', function()
    M.marks.done = M.now()
  end)
  if M.opts.profile then
    record()
  end

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
