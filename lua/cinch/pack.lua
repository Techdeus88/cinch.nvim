-- Adapter over vim.pack. vim.pack owns the disk: install, lockfile, update, delete.
-- Every call cinch makes to vim.pack goes through here, and this is the only
-- place that listens to PackChangedPre and PackChanged. Their handlers update
-- cinch's state first and emit on the bus after, so subscribers see it settled.

local events = require('cinch.events')
local state = require('cinch.state')

local api, uv = vim.api, vim.uv

local M = {}

-- Where vim.pack keeps plugins.
M.dir = vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'site', 'pack', 'core', 'opt')

-- The first vim.pack call of a session reads the lockfile and installs what it
-- lists, with vim.pack's own confirm prompt. Only cinch's add() may be that call.
local synced = false
-- vim.pack waits for git with vim.wait, so timers and callbacks run meanwhile;
-- none of them may call vim.pack again until it returns.
local busy = 0
-- Builds of plugins installed during add(), run once add() returns: a plugin's
-- own code may need what its build makes, so nothing loads before they start.
local adding = false
---@type cinch.Plugin[]
local queue = {}
---@type table<string, fun()[]> callbacks waiting for a plugin's build to end
local waiters = {}

---@param op 'add'|'update'|'del'|'get'
---@param names? string[]
---@param fn function
---@return boolean ok, any result
local function call(op, names, fn, ...)
  if op ~= 'add' and not synced then
    return false, 'vim.pack is not set up yet: cinch has not added plugins this session'
  end
  if busy > 0 then
    return false, 'vim.pack is busy'
  end
  if events.has('PackOpPre') then
    events.emit('PackOpPre', { op = op, names = names })
  end
  busy = busy + 1
  local start = uv.hrtime()
  local ok, res = pcall(fn, ...)
  busy = busy - 1
  if events.has('PackOp') then
    local err = not ok and tostring(res) or nil
    events.emit('PackOp', { op = op, names = names, ok = ok, ms = (uv.hrtime() - start) / 1e6, err = err })
  end
  return ok, res
end

--- Plugins the lockfile lists that are not on disk. The first vim.pack.add of a
--- session installs these, whatever it was asked to add.
---@return string[]
function M.locked_missing()
  local f = io.open(vim.go.packlockfile)
  if not f then
    return {}
  end
  local ok, lock = pcall(vim.json.decode, f:read('*a'))
  f:close()
  local res = {}
  for name in pairs(ok and type(lock) == 'table' and type(lock.plugins) == 'table' and lock.plugins or {}) do
    if not uv.fs_stat(vim.fs.joinpath(M.dir, name)) then
      res[#res + 1] = name
    end
  end
  return res
end

--- Whether vim.pack can be called now.
---@return boolean
function M.idle()
  return synced and busy == 0
end

-- Builds -------------------------------------------------------------------

-- Written when a build starts and removed when it succeeds, so a build that
-- failed or was cut off by quitting runs again on the next startup.
---@param p cinch.Plugin
local function marker(p)
  return vim.fs.joinpath(p.path, '.git', 'cinch-build')
end

---@param p cinch.Plugin
---@param start integer hrtime
---@param err? string
---@param output? string
local function finish(p, start, err, output)
  state.activity(p, nil)
  if not err then
    os.remove(marker(p))
  else
    events.report(('build of `%s` failed: %s'):format(p.name, err), vim.log.levels.ERROR)
  end
  if events.has('Build') then
    local ms = (uv.hrtime() - start) / 1e6
    events.emit('Build', { plugin = p, ok = err == nil, ms = ms, err = err, output = output })
  end
  local list = waiters[p.name] or {}
  waiters[p.name] = nil
  for _, fn in ipairs(list) do
    fn()
  end
end

--- Run `fn` once the plugin's build ends, or now when none is running.
---@param p cinch.Plugin
---@param fn fun()
function M.after_build(p, fn)
  if p.activity ~= 'building' then
    return fn()
  end
  local list = waiters[p.name] or {}
  list[#list + 1] = fn
  waiters[p.name] = list
end

--- A shell command, in the background from the plugin's directory.
---@param p cinch.Plugin
---@param cmd string
---@param start integer
local function shell_build(p, cmd, start)
  state.activity(p, 'building')
  vim.system({ vim.o.shell, vim.o.shellcmdflag, cmd }, { cwd = p.path, text = true }, function(r)
    local output = vim.trim((r.stdout or '') .. (r.stderr or ''))
    local err = r.code ~= 0 and (vim.trim(r.stderr or '') ~= '' and vim.trim(r.stderr) or ('exit ' .. r.code)) or nil
    vim.schedule(function()
      finish(p, start, err, output)
    end)
  end)
end

--- A Lua function. It sees the plugin on the runtimepath, so its modules and
--- autoload functions resolve, but the plugin is not loaded: no plugin/ files,
--- no config, and a plugin that waits for a trigger keeps waiting.
---@param p cinch.Plugin
---@param fn function
---@param start integer
local function function_build(p, fn, start)
  state.activity(p, 'building')
  local on_rtp = vim.list_contains(vim.opt.rtp:get() --[[@as string[] ]], p.path)
  local before = {}
  if not on_rtp then
    for mod in pairs(package.loaded) do
      before[mod] = true
    end
    vim.opt.rtp:prepend(p.path)
  end
  -- `function(p, done)` is async: the build ends when it calls done.
  local async = debug.getinfo(fn, 'u').nparams >= 2
  local ended = false
  local function done(ok, msg)
    if ended then
      return
    end
    ended = true
    vim.schedule(function()
      finish(p, start, ok == false and (msg or 'failed') or nil)
    end)
  end
  local ok, err = pcall(fn, p, async and done or nil)
  if not on_rtp and p.state ~= 'loaded' then
    vim.opt.rtp:remove(p.path)
    -- vim.loader searches its cached runtimepath first and re-reads it only after
    -- a miss; without one it would keep finding this plugin's modules.
    vim.loader.find(' cinch: refresh the runtimepath cache ')
    -- Forget the modules the build loaded, so a later require() loads the plugin properly.
    local lua = vim.fs.joinpath(p.path, 'lua')
    for mod in pairs(package.loaded) do
      local file = vim.fs.joinpath(lua, (mod:gsub('%.', '/')))
      if not before[mod] and (uv.fs_stat(file .. '.lua') or uv.fs_stat(file .. '/init.lua')) then
        package.loaded[mod] = nil
      end
    end
  end
  if not ok then
    ended = true
    finish(p, start, tostring(err))
  elseif not async then
    ended = true
    finish(p, start)
  end
end

---@type cinch.Plugin[] `:Cmd` builds waiting for their plugin to be able to load
local waiting = {}

--- An Ex command. It comes from the plugin itself, so the plugin loads first,
--- which needs two things: Neovim has started, so its plugin/ files and yours have
--- run, and the plugin is armed. On a first start it installs on UIEnter, after
--- startup but before it is armed, so the build waits for M.run_waiting().
---@param p cinch.Plugin
---@param cmd string
local function cmd_build(p, cmd)
  if vim.v.vim_did_enter == 0 or p.state == 'registered' then
    waiting[#waiting + 1] = p
    if #waiting == 1 and vim.v.vim_did_enter == 0 then
      api.nvim_create_autocmd('VimEnter', { once = true, callback = vim.schedule_wrap(M.run_waiting) })
    end
    return
  end
  local start = uv.hrtime()
  -- Required here, not at the top: loader.lua requires this file.
  if not require('cinch.loader').load(p, 'build') then
    return finish(p, start, 'the plugin did not load: ' .. p.state)
  end
  state.activity(p, 'building')
  local ok, err = pcall(vim.cmd --[[@as function]], cmd)
  finish(p, start, not ok and tostring(err) or nil)
end

--- Run the `:Cmd` builds that were waiting, once their plugin can load. init.lua
--- calls this after arming a batch; VimEnter calls it too.
function M.run_waiting()
  local list = waiting
  waiting = {}
  for _, p in ipairs(list) do
    cmd_build(p, p.data.build:sub(2))
  end
end

--- Run a plugin's `build`.
---@param p cinch.Plugin
function M.build(p)
  local b = p.data.build
  if not b or not p.path then
    return
  end
  local f = io.open(marker(p), 'w')
  if f then
    f:close()
  end
  local start = uv.hrtime()
  if type(b) == 'function' then
    function_build(p, b, start)
  elseif b:sub(1, 1) == ':' then
    cmd_build(p, b:sub(2))
  else
    shell_build(p, b, start)
  end
end

-- vim.pack calls -----------------------------------------------------------

--- Add plugins to vim.pack, installing the missing ones in one parallel batch.
--- Records `path` for each plugin on disk; cinch does the loading itself.
---@param plugins cinch.Plugin[]
---@param confirm? boolean ask before installing, vim.pack's prompt
---@return cinch.Plugin[] failed not on disk afterwards
function M.add(plugins, confirm)
  -- Only vim.pack's own fields: it deep-copies every spec, and `data` holds functions.
  local specs, names = {}, {}
  for i, p in ipairs(plugins) do
    -- With its cinch fields in `data`, so vim.pack.get() and PackChanged carry them too.
    specs[i] = { src = p.src, name = p.name, version = p.version, data = p.data }
    names[i] = p.name
  end
  adding = true
  local _, err = call('add', names, vim.pack.add, specs, {
    confirm = confirm,
    load = function(d)
      local p = state.plugins[d.spec.name]
      if p then
        p.path = d.path
      end
    end,
  })
  adding, synced = false, true

  local failed = {}
  for _, p in ipairs(plugins) do
    state.activity(p, nil)
    -- vim.pack skips the load callback for a plugin it already added this session.
    if not p.path then
      local path = vim.fs.joinpath(M.dir, p.name)
      p.path = uv.fs_stat(path) and path or nil
    end
    if not p.path then
      failed[#failed + 1] = p
    elseif p.data.build and uv.fs_stat(marker(p)) then
      -- Its last build failed or was interrupted.
      queue[#queue + 1] = p
    end
  end
  if #failed > 0 then
    local list = vim.tbl_map(function(p)
      return p.name
    end, failed)
    local msg = ('not installed: %s'):format(table.concat(list, ', '))
    events.report(err and (msg .. '\n' .. tostring(err)) or msg, vim.log.levels.ERROR)
  end

  local q = queue
  queue = {}
  for _, p in ipairs(q) do
    M.build(p)
  end
  return failed
end

--- vim.pack.update through cinch, so the bus sees it.
---@param names? string[]
---@param opts? vim.pack.keyset.update
---@return boolean ok, any err
function M.update(names, opts)
  return call('update', names, vim.pack.update, names, opts)
end

--- vim.pack.del through cinch. vim.pack fires PackChangedPre for every plugin
--- named but PackChanged only for those it deleted, so the rest stop "deleting" here.
---@param names string[]
---@param opts? vim.pack.keyset.del
---@return boolean ok, any err
function M.del(names, opts)
  local ok, res = call('del', names, vim.pack.del, names, opts)
  for _, name in ipairs(names) do
    local p = state.plugins[name]
    if p and p.activity == 'deleting' then
      state.activity(p, nil)
    end
  end
  return ok, res
end

-- cinch's own folder, which a clean never deletes.
local own_dir = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/lua/cinch/pack%.lua$')

---@class cinch.Orphan a plugin vim.pack has on disk that no spec names
---@field name string
---@field src string
---@field path string
---@field rev? string

--- Plugins vim.pack has on disk that no spec of this session names: what
--- `:Cinch clean` deletes.
---@return cinch.Orphan[]
function M.orphans()
  local ok, list = M.get(nil, { info = false })
  local res = {}
  for _, d in ipairs(ok and type(list) == 'table' and list or {}) do
    if not d.active and not state.plugins[d.spec.name] and d.path ~= own_dir then
      res[#res + 1] = { name = d.spec.name, src = d.spec.src, path = d.path, rev = d.rev }
    end
  end
  return res
end

--- vim.pack.get through cinch.
---@param names? string[]
---@param opts? vim.pack.keyset.get
---@return boolean ok, vim.pack.PlugData[]|string result
function M.get(names, opts)
  return call('get', names, vim.pack.get, names, opts)
end

--- The plugin's checked-out commit. vim.pack keeps every repo on a detached
--- HEAD, so `.git/HEAD` holds the hash; read once and kept until it changes.
---@param p cinch.Plugin
---@return string?
function M.rev(p)
  if p.rev == nil and p.path then
    local f = io.open(vim.fs.joinpath(p.path, '.git', 'HEAD'))
    if f then
      local line = f:read('*l') or ''
      f:close()
      p.rev = line:match('^%x+$')
    end
  end
  return p.rev
end

-- The only PackChangedPre and PackChanged handlers --------------------------

local group = api.nvim_create_augroup('cinch_pack', { clear = true })
local activities = { install = 'installing', update = 'updating', delete = 'deleting' }

---@param d vim.event.packchanged.data
---@param p? cinch.Plugin
local function payload(d, p)
  return { kind = d.kind, name = d.spec.name, plugin = p, spec = d.spec, path = d.path }
end

api.nvim_create_autocmd('PackChangedPre', {
  group = group,
  callback = function(ev)
    local d = ev.data
    local p = state.plugins[d.spec.name]
    if p then
      state.activity(p, activities[d.kind])
    end
    if events.has('PackPre') then
      events.emit('PackPre', payload(d, p))
    end
  end,
})

api.nvim_create_autocmd('PackChanged', {
  group = group,
  callback = function(ev)
    local d = ev.data
    local p = state.plugins[d.spec.name]
    if p then
      state.activity(p, nil)
      -- The commit changed or the plugin is gone, so the one read before is stale.
      p.rev = nil
      if d.kind == 'delete' then
        p.path, p.deleted = nil, true
      else
        p.path, p.deleted = d.path, nil
        if p.data.build then
          if adding then
            queue[#queue + 1] = p
          else
            M.build(p)
          end
        end
      end
    end
    if events.has('Pack') then
      events.emit('Pack', payload(d, p))
    end
  end,
})

return M
