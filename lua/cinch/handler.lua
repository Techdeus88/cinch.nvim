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
---@field disarm? fun(p: cinch.Plugin, values: any[], loading?: boolean) remove it; `loading`: it is about to load
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
--- stays pending was vetoed (LoadPre): its trigger is still armed, so replaying it
--- would land on the same stub again. One that failed has no stub left, so a replayed
--- key would run as the keys themselves. The replay runs only when some plugin loaded,
--- which is when the trigger has something real to run.
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
      moved = moved or p.state == 'loaded'
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

--- Whether an autocmd's pattern matches what the event fired for. A pattern with no
--- slash matches the file's tail, as Neovim does: `Cargo.toml` for /a/b/Cargo.toml.
---@param pattern string
---@param match string
---@return boolean
local function pattern_matches(pattern, match)
  local re = vim.fn.glob2regpat(pattern)
  return vim.fn.match(match, re) >= 0 or not pattern:find('/') and vim.fn.match(vim.fs.basename(match), re) >= 0
end

--- Run `fn` in a buffer, or where the cursor is when the buffer is gone: something
--- else on the event deleted it, a dashboard on VimEnter say.
---@param buf integer
---@param fn fun()
local function in_buf(buf, fn)
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_call(buf, fn)
  else
    fn()
  end
end

--- Run only the autocmds that appeared since `seen`, so no other handler of the
--- event runs twice. From sarcina's replay.lua.
---@param event string
---@param args vim.api.keyset.create_autocmd.callback_args
---@param seen cinch.Seen
local function replay_event(event, args, seen)
  local ran = {}
  if not api.nvim_buf_is_valid(args.buf) then
    args = vim.tbl_extend('force', args, { buf = api.nvim_get_current_buf() })
  end
  for _, au in ipairs(api.nvim_get_autocmds({ event = event })) do
    local applies = au.buflocal and (au.buf or au['buffer']) == args.buf
      or not au.buflocal and pattern_matches(au.pattern, args.match or '')
    if applies and not seen.keys[autocmd_key(au)] then
      if au.group and not au.buflocal and not seen.groups[au.group] then
        -- A group the plugin just made: Neovim runs it, each autocmd in the script
        -- that defined it, so a Vimscript one can still call its s: functions.
        if not ran[au.group] then
          ran[au.group] = true
          try('replaying ' .. event, in_buf, args.buf, function()
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
        try('replaying ' .. event, in_buf, args.buf, function()
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
          -- So what a config does fires its own autocmds: a colorscheme, a filetype.
          nested = true,
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

--- Whether a command is cinch's stub. Neovim 0.12 has its description in `definition`.
---@param def table from nvim_get_commands
---@param name string
---@return boolean
local function is_stub(def, name)
  return (def.desc or def.definition) == cmd_desc .. name
end

--- The replayed command's own error, a missing argument say: not cinch's, so it shows
--- where Neovim shows one you typed, on the command line, as Neovim words it. It is
--- logged too, with `shown` set so no subscriber shows it again.
---@param err string
local function command_error(err)
  local msg = err:match('Vim%b():(.*)$') or err:match('Vim:(.*)$') or err
  api.nvim_echo({ { msg } }, true, { err = true })
  if events.has('Report') then
    events.emit('Report', { msg = msg, level = vim.log.levels.ERROR, source = 'command', shown = true })
  end
end

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
    local ok, err = pcall(vim.cmd --[[@as function]], line)
    if not ok then
      command_error(tostring(err))
    end
  end)
end

M.handlers.cmd = {
  arm = function(p, names)
    local defs = api.nvim_get_commands({})
    for _, name in ipairs(names) do
      -- A command of yours or another plugin's stays: one with a Lua callback could
      -- not be put back when the stub goes, as a mapping can.
      if defs[name] and not is_stub(defs[name], name) then
        local msg = '`%s`: `:%s` already exists, so it does not load the plugin'
        events.report(msg:format(p.name, name), vim.log.levels.WARN, p.name)
      else
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
            if not def or is_stub(def, name) then
              return {}
            end
            return vim.fn.getcompletion(line, 'cmdline')
          end,
          desc = cmd_desc .. name,
        })
      end
    end
  end,
  disarm = function(p, names, loading)
    for _, name in ipairs(names) do
      local c = cmds[name]
      if c then
        c[p.name] = nil
        -- Only our stub: another plugin may have defined the real command meanwhile.
        local def = api.nvim_get_commands({})[name]
        local ours = def and is_stub(def, name)
        if loading and def and not ours then
          local msg = '`%s`: its command `:%s` was defined by something else before it loaded'
          events.report(msg:format(p.name, name), vim.log.levels.WARN, p.name)
        end
        if not next(c) then
          cmds[name] = nil
          if ours then
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
---@field fts? string[] only in buffers of these filetypes, as lazy.nvim's `ft` on a key

---@type table<string, table<string, cinch.Plugin>> "mode lhs" -> plugins
local stubs = {}
---@type table<string, { fn: function, prev?: table }> "mode lhs" -> the stub mapped there, and the mapping it replaced
local stub_maps = {}

--- Whether a stub is still mapped: you or a plugin may have mapped the key since.
---@param mode string
---@param fn function the stub's callback
---@return boolean
local function is_key_stub(mode, fn)
  local ok, maps = pcall(api.nvim_get_keymap, mode)
  if not ok then
    return true
  end
  return vim.iter(maps):any(function(m)
    return m.callback == fn
  end)
end

--- vim.keymap.set, reporting a failure instead of raising it: one bad key never stops
--- the plugin's other keys from being mapped.
---@param p cinch.Plugin
---@param mode string|string[]
---@param lhs string
---@param rhs string|function
---@param opts vim.keymap.set.Opts
---@return boolean ok
local function set_map(p, mode, lhs, rhs, opts)
  local ok, err = pcall(vim.keymap.set, mode, lhs, rhs, opts)
  if not ok then
    local modes = type(mode) == 'table' and table.concat(mode) or mode
    local msg = ('`%s`: cannot map `%s` (%s): %s'):format(p.name, lhs, modes, err)
    events.report(msg, vim.log.levels.ERROR, p.name)
  end
  return ok
end

-- Modes where a register and a count can come before a key.
local counted = { n = true, x = true, v = true, o = true }

---@param mode string
---@param lhs string
---@param plugins? table<string, cinch.Plugin> default: every plugin behind the global stub
local function on_key(mode, lhs, plugins)
  -- What came before the key: "a, a count, and in operator-pending mode the
  -- operator itself, which ends when this stub returns without a motion.
  local prefix = ''
  if counted[mode] then
    prefix = '"' .. vim.v.register .. (vim.v.count > 0 and tostring(vim.v.count) or '')
    if mode == 'o' then
      prefix = prefix .. vim.v.operator
    end
  end
  fire_all(ordered(plugins or stubs[mode .. ' ' .. lhs]), 'keys ' .. lhs, function()
    -- Fed again with remapping, so the mapping the plugin or its spec just made runs.
    api.nvim_feedkeys(prefix .. vim.keycode(lhs), 'mit', false)
  end)
end

--- The buffers open now whose filetype is one of `fts`.
---@param fts string[]
---@return integer[]
local function buffers_of(fts)
  return vim.tbl_filter(function(b)
    return api.nvim_buf_is_loaded(b) and vim.list_contains(fts, vim.bo[b].filetype)
  end, api.nvim_list_bufs())
end

--- Run `fn(buf)` for each buffer of the key's filetypes: those open now, and each one
--- that gets one of them later, until the returned autocmd is deleted.
---@param k cinch.ParsedKey
---@param fn fun(buf: integer)
---@return integer autocmd
local function each_ft_buffer(k, fn)
  local au = api.nvim_create_autocmd('FileType', {
    pattern = k.fts,
    callback = function(ev)
      fn(ev.buf)
    end,
  })
  for _, b in ipairs(buffers_of(k.fts or {})) do
    fn(b)
  end
  return au
end

---@class cinch.FtStub a key with `ft`: its own stub in each buffer of those filetypes
---@field au? integer the FileType autocmd that maps it in new buffers
---@field maps table<integer, table<string, { fn: function, prev?: table }>> buffer -> mode -> stub

---@type table<string, cinch.FtStub> "plugin mode... lhs" -> its stubs
local ft_stubs = {}

---@param p cinch.Plugin
---@param k cinch.ParsedKey
---@return string
local function ft_id(p, k)
  return p.name .. ' ' .. table.concat(k.modes, ',') .. ' ' .. k.lhs
end

--- Map a key with `ft` as a stub in each buffer of its filetypes: buffer-local, so in
--- any other buffer the key stays as it was.
---@param p cinch.Plugin
---@param k cinch.ParsedKey
local function arm_ft(p, k)
  local id = ft_id(p, k)
  if ft_stubs[id] then
    return
  end
  local entry = { maps = {} } ---@type cinch.FtStub
  ft_stubs[id] = entry
  entry.au = each_ft_buffer(k, function(buf)
    entry.maps[buf] = entry.maps[buf] or {}
    for _, mode in ipairs(k.modes) do
      if not entry.maps[buf][mode] then
        -- A buffer-local mapping of this key, from an ftplugin say, comes back after.
        local prev = api.nvim_buf_call(buf, function()
          return vim.fn.maparg(k.lhs, mode, false, true)
        end)
        local fn = function()
          on_key(mode, k.lhs, { [p.name] = p })
        end
        local opts = { buffer = buf, desc = k.opts.desc or ('cinch: load ' .. p.name) }
        if set_map(p, mode, k.lhs, fn, opts) then
          entry.maps[buf][mode] = { fn = fn, prev = next(prev) and prev.buffer == 1 and prev or nil }
        end
      end
    end
  end)
end

---@param p cinch.Plugin
---@param k cinch.ParsedKey
---@param loading? boolean
local function disarm_ft(p, k, loading)
  local id = ft_id(p, k)
  local entry = ft_stubs[id]
  if not entry then
    return
  end
  ft_stubs[id] = nil
  pcall(api.nvim_del_autocmd, entry.au)
  for buf, modes in pairs(entry.maps) do
    for mode, stub in pairs(modes) do
      local ok, maps = pcall(api.nvim_buf_get_keymap, buf, mode)
      local ours = ok and vim.iter(maps):any(function(m)
        return m.callback == stub.fn
      end)
      if ours then
        pcall(vim.keymap.del, mode, k.lhs, { buffer = buf })
        if stub.prev then
          pcall(api.nvim_buf_call, buf, function()
            vim.fn.mapset(mode, false, stub.prev)
          end)
        end
      elseif loading and ok then
        local msg = '`%s`: its key `%s` was mapped by something else before it loaded'
        events.report(msg:format(p.name, k.lhs), vim.log.levels.WARN, p.name)
      end
    end
  end
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
        local fts = k.ft and list(k.ft)
        res[#res + 1] = { lhs = k[1], rhs = k[2], modes = list(k.mode or 'n'), opts = opts, fts = fts }
      end
    end
    return res
  end,
  arm = function(p, keys)
    for _, k in ipairs(keys) do
      if k.fts then
        arm_ft(p, k)
      end
      for _, mode in ipairs(k.fts and {} or k.modes) do
        local id = mode .. ' ' .. k.lhs
        stubs[id] = stubs[id] or {}
        stubs[id][p.name] = p
        if not stub_maps[id] then
          local prev = vim.fn.maparg(k.lhs, mode, false, true)
          local fn = function()
            on_key(mode, k.lhs)
          end
          if set_map(p, mode, k.lhs, fn, { desc = k.opts.desc or ('cinch: load ' .. p.name) }) then
            -- A mapping of yours the stub replaces comes back when the stub goes.
            stub_maps[id] = { fn = fn, prev = next(prev) and prev.buffer == 0 and prev or nil }
          else
            -- No stub there, so nothing for disarm to undo or report.
            stubs[id] = nil
          end
        end
      end
    end
  end,
  disarm = function(p, keys, loading)
    for _, k in ipairs(keys) do
      if k.fts then
        disarm_ft(p, k, loading)
      end
      for _, mode in ipairs(k.fts and {} or k.modes) do
        local id = mode .. ' ' .. k.lhs
        if stubs[id] then
          stubs[id][p.name] = nil
          local stub = stub_maps[id]
          -- Only our stub: you or another plugin may have mapped the key meanwhile.
          local ours = stub and is_key_stub(mode, stub.fn)
          if loading and stub and not ours then
            local msg = '`%s`: its key `%s` was mapped by something else before it loaded'
            events.report(msg:format(p.name, k.lhs), vim.log.levels.WARN, p.name)
          end
          if not next(stubs[id]) then
            stubs[id] = nil
            stub_maps[id] = nil
            if stub and ours then
              pcall(vim.keymap.del, mode, k.lhs)
              if stub.prev then
                pcall(vim.fn.mapset, mode, false, stub.prev)
              end
            end
          end
        end
      end
    end
  end,
  -- Keys with an rhs are mappings the spec defines, once the plugin is there. One with
  -- `ft` is buffer-local, in each buffer of those filetypes, now and later.
  loaded = function(p, keys)
    for _, k in ipairs(keys) do
      if k.rhs ~= nil and k.fts then
        each_ft_buffer(k, function(buf)
          set_map(p, k.modes, k.lhs, k.rhs, vim.tbl_extend('force', k.opts, { buffer = buf }))
        end)
      elseif k.rhs ~= nil then
        set_map(p, k.modes, k.lhs, k.rhs, k.opts)
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
  local ok, err = xpcall(fn, events.traceback)
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
    elseif x.state == 'pending' and (x.when == 'later' or x.very_lazy) then
      -- Skipped: a plugin loaded meanwhile, as a dependency say, or moved off `later` by add().
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
  -- While a first-start batch waits, so does the queue; start() runs again after it.
  if not later_draining and not M.held then
    later_draining = true
    vim.schedule(drain)
  end
end

--- Read the arguments Neovim reads: none after `--`, which only names files, nor after
--- `-l` and its script. `-s` is silent mode only after `-e` or `-E`; before them it
--- names a script file.
---@param argv string[]
---@return boolean ui false when Neovim never gets one: headless, silent Ex mode or `-l`
---@return boolean embed
local function scan(argv)
  local ex, embed = false, false
  for _, a in ipairs(argv) do
    if a == '--' then
      break
    elseif a == '--headless' or a == '-l' or a == '-es' or a == '-Es' or (ex and a == '-s') then
      return false, embed
    end
    ex = ex or a == '-e' or a == '-E'
    embed = embed or a == '--embed'
  end
  return true, embed
end

--- Whether a UI will attach, so UIEnter will fire. Headless Neovim never gets one,
--- nor does silent Ex mode or a `-l` script. An embedded one, which a GUI or the
--- terminal UI starts, has its UI attached before init.lua runs; with none by then,
--- it is driven without one.
---@param argv? string[] default: v:argv
---@param uis? integer how many UIs are attached; default: now
---@return boolean
function M.ui_coming(argv, uis)
  local ui, embed = scan(argv or vim.v.argv)
  return ui and ((uis or #api.nvim_list_uis()) > 0 or not embed)
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
      if M.held then
        now_queue[#now_queue + 1] = x
      else
        run('now', x)
      end
    end
  end
  if vim.v.vim_did_enter == 1 then
    return start_drain()
  elseif not first then
    -- An add() while init.lua still runs: the autocmd below is already waiting.
    return
  end
  -- With no UI coming there is no UIEnter; VimEnter is the moment there.
  api.nvim_create_autocmd(M.ui_coming() and 'UIEnter' or 'VimEnter', { once = true, callback = start_drain })
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
---@param loading? boolean for disarm: the plugin is about to load
local function call(hook, name, p, loading)
  local fn = M.handlers[name][hook]
  if fn then
    try(('%s %s of `%s`'):format(hook, name, p.name), fn, p, p.triggers[name], loading)
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

--- Remove a plugin's stubs. With `loading`, right before it loads, a stub that
--- something else replaced meanwhile is reported: that trigger never loaded the plugin.
---@param p cinch.Plugin
---@param loading? boolean
function M.disarm(p, loading)
  for name in pairs(p.armed or {}) do
    call('disarm', name, p, loading)
  end
  p.armed = nil
end

--- Let each of the plugin's handlers finish up after it loaded.
---@param p cinch.Plugin
function M.loaded(p)
  for name in pairs(p.triggers or {}) do
    call('loaded', name, p)
  end
  -- A plugin that loads on its own has no triggers, but the mappings its spec defines are still its own.
  local keys = p.data.keys
  if p.when ~= 'trigger' and keys then
    local k = M.handlers.keys
    try(('loaded keys of `%s`'):format(p.name), k.loaded, p, k.parse(keys))
  end
end

return M
