-- When plugins load. Each plugin waits on its `when`:
--   now     loaded in the startup pass, in declaration order
--   later   queued, loaded once the UI is up, a few at a time
--   trigger loaded by its handlers: event, ft, cmd, keys, or a custom one
-- Handlers are organized by trigger, not by plugin: one autocmd, stub command
-- or stub mapping per key, with every plugin waiting on it behind it.

local events = require('cinch.events')
local spec = require('cinch.spec')

local api, uv = vim.api, vim.uv

local M = {}

---@class cinch.Handler
---@field parse? fun(value: any): any[] spec value -> list of values; default wraps one value in a list
---@field arm fun(p: cinch.Plugin, values: any[]) set up what loads the plugin
---@field disarm? fun(p: cinch.Plugin, values: any[]) remove it; runs right before the plugin loads
---@field loaded? fun(p: cinch.Plugin, values: any[]) after a successful load

---@type table<string, cinch.Handler>
M.handlers = {}

-- Milliseconds of `later` loading per event-loop tick, so typing stays responsive.
M.budget = 5

---@param v any
---@return any[]
local function list(v)
  if v == nil then
    return {}
  end
  return type(v) == 'table' and v or { v }
end

--- Load a plugin. `done` runs once it is loaded or has failed, maybe after its build.
---@param p cinch.Plugin
---@param reason string
---@param done? fun()
function M.fire(p, reason, done)
  -- Required here, not at the top: loader.lua requires this file.
  require('cinch.loader').load(p, reason, done)
end

--- The plugins behind a trigger, in declaration order: kept in a table by name,
--- which `pairs` walks in no particular order.
---@param set? table<string, cinch.Plugin>
---@return cinch.Plugin[]
local function ordered(set)
  local res = vim.tbl_values(set or {})
  if #res > 1 then
    local at = {}
    for i, p in ipairs(require('cinch.state').list) do
      at[p] = i
    end
    table.sort(res, function(a, b)
      return (at[a] or 0) < (at[b] or 0)
    end)
  end
  return res
end

--- Load several plugins, then run `replay` once, after the last one. A plugin that
--- stays pending was vetoed (LoadPre) or waits for nothing else: its trigger is still
--- armed, so replaying it would land on the same stub again. The replay runs only when
--- some plugin got past pending, which is when the trigger has something real to run.
---@param plugins cinch.Plugin[]
---@param reason string
---@param replay fun()
local function fire_all(plugins, reason, replay)
  local left, moved = #plugins, false
  if left == 0 then
    return replay()
  end
  for _, p in ipairs(plugins) do
    M.fire(p, reason, function()
      left = left - 1
      moved = moved or p.state ~= 'pending'
      if left == 0 and moved then
        replay()
      end
    end)
  end
end

---@param label string
---@param fn function
local function try(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    events.report(('%s: %s'):format(label, err), vim.log.levels.ERROR)
  end
end

-- event / ft ---------------------------------------------------------------

---@type table<string, { id: integer, plugins: table<string, cinch.Plugin> }> "Event pattern" -> autocmd
local autocmds = {}

-- The runtime applies a filetype's ftplugin, indent and syntax files from these groups.
local filetype_groups = { 'filetypeplugin', 'filetypeindent', 'syntaxset' }

--- Autocmds defined from Vimscript have no id, so they are told apart by what they are.
---@param au table an item of nvim_get_autocmds()
---@return integer|string
local function autocmd_key(au)
  return au.id or table.concat({ tostring(au.group), au.pattern or '', tostring(au.command) }, '\0')
end

---@class cinch.Seen the autocmds of an event before a plugin loads
---@field keys table<integer|string, true>
---@field groups table<integer, true> groups that had any

---@param event string
---@return cinch.Seen
local function autocmd_ids(event)
  local seen = { keys = {}, groups = {} }
  for _, au in ipairs(api.nvim_get_autocmds({ event = event })) do
    seen.keys[autocmd_key(au)] = true
    if au.group then
      seen.groups[au.group] = true
    end
  end
  return seen
end

--- Run only the autocmds that appeared since `seen`, so no other handler of the
--- event runs twice. From sarcina's replay.lua.
---@param event string
---@param args vim.api.keyset.create_autocmd.callback_args
---@param seen cinch.Seen
local function replay_event(event, args, seen)
  local ran = {}
  for _, au in ipairs(api.nvim_get_autocmds({ event = event })) do
    local applies = au.buflocal and (au.buf or au['buffer']) == args.buf
      or not au.buflocal and vim.fn.match(args.match or '', vim.fn.glob2regpat(au.pattern)) >= 0
    if applies and not seen.keys[autocmd_key(au)] then
      if au.group and not au.buflocal and not seen.groups[au.group] then
        -- A group the plugin just made: Neovim runs it, each autocmd in the script
        -- that defined it, so a Vimscript one can still call its s: functions.
        if not ran[au.group] then
          ran[au.group] = true
          try('replaying ' .. event, api.nvim_buf_call, args.buf, function()
            api.nvim_exec_autocmds(event, {
              group = au.group,
              pattern = args.match ~= '' and args.match or nil,
              modeline = false,
              data = args.data,
            })
          end)
        end
      elseif type(au.callback) == 'function' then
        -- Called directly, so what Neovim does after a callback is up to us: delete
        -- a `once` autocmd, or one whose callback returns true.
        local ok, res = pcall(au.callback, vim.tbl_extend('force', args, { id = au.id, group = au.group }))
        if not ok then
          events.report(('replaying %s: %s'):format(event, res), vim.log.levels.ERROR)
        end
        if au.id and (au.once or (ok and res == true)) then
          pcall(api.nvim_del_autocmd, au.id)
        end
      elseif au.command and au.command ~= '' then
        try('replaying ' .. event, api.nvim_buf_call, args.buf, function()
          vim.cmd(au.command)
        end)
        if au.id and au.once then
          pcall(api.nvim_del_autocmd, au.id)
        end
      end
    end
  end
end

--- A plugin loaded after a buffer got its filetype may bring ftdetect scripts and
--- ftplugin, indent and syntax files. Detect again if ftdetect scripts appeared, then
--- run the runtime's own FileType groups for every buffer of that filetype.
---@param ft string
---@param ftdetect_before string[]
local function refresh_filetype(ft, ftdetect_before)
  local detect = #api.nvim_get_runtime_file('ftdetect/*.{vim,lua}', true) ~= #ftdetect_before
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      api.nvim_buf_call(buf, function()
        if detect and vim.bo.buftype == '' then
          vim.cmd('filetype detect')
        end
        if vim.bo.filetype == ft then
          for _, g in ipairs(filetype_groups) do
            pcall(api.nvim_exec_autocmds, 'FileType', { group = g, buffer = buf, modeline = false })
          end
        end
      end)
    end
  end
end

---@param key string "Event" or "Event pattern"
---@param args vim.api.keyset.create_autocmd.callback_args
local function on_event(key, args)
  local a = autocmds[key]
  if not a then
    return
  end
  local event = args.event
  local seen = autocmd_ids(event)
  local ftdetect = event == 'FileType' and api.nvim_get_runtime_file('ftdetect/*.{vim,lua}', true)
  fire_all(ordered(a.plugins), 'event ' .. key, function()
    replay_event(event, args, seen)
    if ftdetect then
      refresh_filetype(args.match, ftdetect)
    end
  end)
end

M.handlers.event = {
  arm = function(p, keys)
    for _, key in ipairs(keys) do
      local a = autocmds[key]
      if not a then
        local event, pattern = key:match('^(%S+)%s*(.*)$')
        a = { plugins = {} }
        a.id = api.nvim_create_autocmd(event, {
          pattern = pattern ~= '' and pattern or nil,
          desc = 'cinch: load on ' .. key,
          callback = function(args)
            on_event(key, args)
          end,
        })
        autocmds[key] = a
      end
      a.plugins[p.name] = p
    end
  end,
  disarm = function(p, keys)
    for _, key in ipairs(keys) do
      local a = autocmds[key]
      if a then
        a.plugins[p.name] = nil
        if not next(a.plugins) then
          pcall(api.nvim_del_autocmd, a.id)
          autocmds[key] = nil
        end
      end
    end
  end,
}

M.handlers.ft = {
  parse = function(v)
    return vim.tbl_map(function(ft)
      return 'FileType ' .. ft
    end, list(v))
  end,
  arm = M.handlers.event.arm,
  disarm = M.handlers.event.disarm,
}

-- cmd -----------------------------------------------------------------------

---@type table<string, table<string, cinch.Plugin>> command -> plugins
local cmds = {}
local cmd_desc = 'cinch: load on :'

---@param name string
---@param args vim.api.keyset.create_user_command.command_args
local function on_cmd(name, args)
  fire_all(ordered(cmds[name]), 'cmd ' .. name, function()
    local range = args.range == 2 and (args.line1 .. ',' .. args.line2)
      or args.range == 1 and tostring(args.line1)
      or ''
    -- As text, the way it was typed: fargs would lose escaped spaces and a register.
    local line = ('%s%s%s%s%s'):format(
      args.mods ~= '' and (args.mods .. ' ') or '',
      range,
      name,
      args.bang and '!' or '',
      args.args ~= '' and (' ' .. args.args) or ''
    )
    try(':' .. name, vim.cmd --[[@as function]], line)
  end)
end

M.handlers.cmd = {
  arm = function(p, names)
    for _, name in ipairs(names) do
      cmds[name] = cmds[name] or {}
      cmds[name][p.name] = p
      api.nvim_create_user_command(name, function(args)
        on_cmd(name, args)
      end, {
        nargs = '*',
        bang = true,
        range = true,
        -- Completing the command loads the plugin, then asks the real command.
        complete = function(_, line)
          fire_all(ordered(cmds[name]), 'cmd ' .. name, function() end)
          -- Still this stub (a build is running, or LoadPre cancelled the load):
          -- asking again would land here, forever.
          local def = api.nvim_get_commands({})[name]
          if not def or def.desc == cmd_desc .. name then
            return {}
          end
          return vim.fn.getcompletion(line, 'cmdline')
        end,
        desc = cmd_desc .. name,
      })
    end
  end,
  disarm = function(p, names)
    for _, name in ipairs(names) do
      local c = cmds[name]
      if c then
        c[p.name] = nil
        if not next(c) then
          cmds[name] = nil
          -- Only our stub: another plugin may have defined the real command meanwhile.
          local def = api.nvim_get_commands({})[name]
          if def and def.desc == cmd_desc .. name then
            api.nvim_del_user_command(name)
          end
        end
      end
    end
  end,
}

-- keys ----------------------------------------------------------------------

-- Passed to vim.keymap.set for a mapping that has an rhs. From sarcina's keys.lua.
local map_options = { 'desc', 'silent', 'noremap', 'remap', 'nowait', 'expr', 'unique', 'script', 'buffer' }

---@class cinch.ParsedKey
---@field lhs string
---@field rhs? string|function
---@field modes string[]
---@field opts vim.keymap.set.Opts

---@type table<string, table<string, cinch.Plugin>> "mode lhs" -> plugins
local stubs = {}

-- Modes where a register and a count can come before a key.
local counted = { n = true, x = true, v = true, o = true }

---@param mode string
---@param lhs string
local function on_key(mode, lhs)
  -- What came before the key: "a, a count, and in operator-pending mode the
  -- operator itself, which ends when this stub returns without a motion.
  local prefix = ''
  if counted[mode] then
    prefix = '"' .. vim.v.register .. (vim.v.count > 0 and tostring(vim.v.count) or '')
    if mode == 'o' then
      prefix = prefix .. vim.v.operator
    end
  end
  fire_all(ordered(stubs[mode .. ' ' .. lhs]), 'keys ' .. lhs, function()
    -- Fed again with remapping, so the mapping the plugin or its spec just made runs.
    api.nvim_feedkeys(prefix .. vim.keycode(lhs), 'mit', false)
  end)
end

M.handlers.keys = {
  parse = function(v)
    local res = {}
    for _, k in ipairs(list(v)) do
      if type(k) == 'string' then
        res[#res + 1] = { lhs = k, modes = { 'n' }, opts = {} }
      elseif type(k) == 'table' and type(k[1]) == 'string' then
        local opts = {}
        for _, o in ipairs(map_options) do
          opts[o] = k[o]
        end
        res[#res + 1] = { lhs = k[1], rhs = k[2], modes = list(k.mode or 'n'), opts = opts }
      end
    end
    return res
  end,
  arm = function(p, keys)
    for _, k in ipairs(keys) do
      for _, mode in ipairs(k.modes) do
        local id = mode .. ' ' .. k.lhs
        stubs[id] = stubs[id] or {}
        stubs[id][p.name] = p
        vim.keymap.set(mode, k.lhs, function()
          on_key(mode, k.lhs)
        end, { desc = k.opts.desc or ('cinch: load ' .. p.name) })
      end
    end
  end,
  disarm = function(p, keys)
    for _, k in ipairs(keys) do
      for _, mode in ipairs(k.modes) do
        local id = mode .. ' ' .. k.lhs
        if stubs[id] then
          stubs[id][p.name] = nil
          if not next(stubs[id]) then
            stubs[id] = nil
            pcall(vim.keymap.del, mode, k.lhs)
          end
        end
      end
    end
  end,
  -- Keys with an rhs are mappings the spec defines, once the plugin is there.
  loaded = function(_, keys)
    for _, k in ipairs(keys) do
      if k.rhs ~= nil then
        vim.keymap.set(k.modes, k.lhs, k.rhs, k.opts)
      end
    end
  end,
}

-- now / later -------------------------------------------------------------

-- Both queues hold plugins and your own functions (cinch.now, cinch.later).
---@type (cinch.Plugin|function)[]
local now_queue = {}
---@type (cinch.Plugin|function)[]
local later_queue = {}
local later_next = 1
local later_draining = false
local later_done = false
local started = false

--- Held while a first start's batch waits for the UI, so `now` functions run after
--- the plugins they may require are installed. init.lua sets it.
M.held = false

--- The function each cinch.time() wrapper calls, so a wrapped function is still
--- named by where you wrote it, not by the wrapper in cinch.
---@type table<function, function>
M.wraps = setmetatable({}, { __mode = 'k' })

--- Run one of your functions, protected: an error is reported, and the rest go on.
---@param when 'now'|'later'
---@param fn function
local function run(when, fn)
  local src = fn
  while M.wraps[src] do
    src = M.wraps[src]
  end
  local info = debug.getinfo(src, 'S')
  local where = ('%s:%d'):format(vim.fs.basename(info.short_src), info.linedefined)
  local t = uv.hrtime()
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    events.report(('%s function at %s failed: %s'):format(when, where, err), vim.log.levels.ERROR)
  end
  if events.has('Run') then
    events.emit('Run', { when = when, where = where, ok = ok, ms = (uv.hrtime() - t) / 1e6, err = err })
  end
end

local function drain()
  local start = uv.hrtime()
  while later_next <= #later_queue do
    local x = later_queue[later_next]
    later_next = later_next + 1
    if type(x) == 'function' then
      run('later', x)
    elseif x.state == 'pending' then
      -- A plugin loaded meanwhile, as a dependency say, is skipped.
      M.fire(x, 'later')
    end
    if (uv.hrtime() - start) / 1e6 >= M.budget then
      return vim.schedule(drain)
    end
  end
  later_draining = false
  if not later_done then
    later_done = true
    events.emit('Later')
  end
end

local function start_drain()
  if not later_draining then
    later_draining = true
    vim.schedule(drain)
  end
end

--- Load the `now` plugins, run the `now` functions waiting for them, then wait for
--- the UI to work through the `later` queue. init.lua calls this once all plugins
--- are armed; plugins and functions added after it start right away.
function M.start()
  local first = not started
  started = true
  local q = now_queue
  now_queue = {}
  for _, x in ipairs(q) do
    if type(x) ~= 'function' and x.state == 'pending' then
      M.fire(x, 'now')
    end
  end
  -- After the plugins, so a function can require() them.
  for _, x in ipairs(q) do
    if type(x) == 'function' then
      run('now', x)
    end
  end
  if not first or vim.v.vim_did_enter == 1 then
    return start_drain()
  end
  -- Headless Neovim never gets UIEnter; VimEnter is the moment there.
  local headless = vim.list_contains(vim.v.argv, '--headless')
  api.nvim_create_autocmd(headless and 'VimEnter' or 'UIEnter', { once = true, callback = start_drain })
end

--- Run `fn` now: at once once startup has run, else right after the `now` plugins.
---@param fn function
function M.now(fn)
  if started and not M.held then
    return run('now', fn)
  end
  now_queue[#now_queue + 1] = fn
end

--- Run `fn` later: in the `later` queue once the UI is up, in turn with plugins.
---@param fn function
function M.later(fn)
  later_queue[#later_queue + 1] = fn
  if started and vim.v.vim_did_enter == 1 then
    start_drain()
  end
end

--- `now` when Neovim started with a file argument, `later` when it did not.
---@param fn function
function M.now_if_args(fn)
  if vim.fn.argc(-1) > 0 then
    M.now(fn)
  else
    M.later(fn)
  end
end

-- registry ------------------------------------------------------------------

--- Add a trigger. Its name is also its spec field.
---@param name string
---@param h cinch.Handler
function M.register(name, h)
  M.handlers[name] = h
  spec.field(name)
end

--- Read the trigger fields of a `trigger` plugin into `p.triggers`.
---@param p cinch.Plugin
function M.parse(p)
  if p.when ~= 'trigger' then
    return
  end
  local t
  for name, h in pairs(M.handlers) do
    local v = p.data[name]
    if v ~= nil and v ~= false then
      local values = (h.parse or list)(v)
      if #values > 0 then
        t = t or {}
        t[name] = values
      end
    end
  end
  p.triggers = t
end

---@param hook 'arm'|'disarm'|'loaded'
---@param name string handler
---@param p cinch.Plugin
local function call(hook, name, p)
  local fn = M.handlers[name][hook]
  if fn then
    try(('%s %s of `%s`'):format(hook, name, p.name), fn, p, p.triggers[name])
  end
end

---@param p cinch.Plugin
local function queue_later(p)
  later_queue[#later_queue + 1] = p
  if started and vim.v.vim_did_enter == 1 then
    start_drain()
  end
end

--- Set up what loads a pending plugin, by its `when`.
---@param p cinch.Plugin
function M.arm(p)
  if p.when == 'now' then
    now_queue[#now_queue + 1] = p
  elseif p.when == 'later' then
    queue_later(p)
  else
    -- No triggers: it loads when a plugin that depends on it does, or by hand.
    M.parse(p)
    p.armed = {}
    for name in pairs(p.triggers or {}) do
      -- Marked first, so a partly failed arm is still undone.
      p.armed[name] = true
      call('arm', name, p)
    end
    -- VeryLazy beside other events: `later` loads it if none of them fired first.
    -- The queue skips it once a trigger has loaded it.
    if p.very_lazy then
      queue_later(p)
    end
  end
end

--- Remove a plugin's stubs, right before it loads.
---@param p cinch.Plugin
function M.disarm(p)
  for name in pairs(p.armed or {}) do
    call('disarm', name, p)
  end
  p.armed = nil
end

--- Let each of the plugin's handlers finish up after it loaded.
---@param p cinch.Plugin
function M.loaded(p)
  for name in pairs(p.triggers or {}) do
    call('loaded', name, p)
  end
end

return M
