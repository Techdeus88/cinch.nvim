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

--- A copy of `v` that Neovim's API can convert. vim.pack sends each spec through
--- autocmd event data, which refuses a table with both list items and named fields
--- (a lazy-style key such as { 'gx', fn, desc = '...' }), cycles and userdata. Such a
--- table keeps its list items under "1", "2", ...; what cannot cross becomes text.
---@param v any
---@param seen? table<table, true>
---@return any
function M.portable(v, seen)
  local t = type(v)
  if t == 'userdata' or t == 'thread' then
    return tostring(v)
  elseif t ~= 'table' then
    return v
  end
  seen = seen or {}
  if seen[v] then
    return '<cycle>'
  end
  seen[v] = true
  local list, dict = true, true
  for k in pairs(v) do
    list = list and type(k) == 'number' and k >= 1 and k % 1 == 0
    dict = dict and type(k) == 'string'
  end
  local out = {}
  for k, x in pairs(v) do
    out[(list or dict) and k or tostring(k)] = M.portable(x, seen)
  end
  seen[v] = nil
  return out
end

---@param path string
---@return table?
local function read_json(path)
  local f = io.open(path)
  if not f then
    return
  end
  local ok, res = pcall(vim.json.decode, f:read('*a'))
  f:close()
  return ok and type(res) == 'table' and res or nil
end

--- Plugins the lockfile lists that are not on disk. The first vim.pack.add of a
--- session installs these, whatever it was asked to add.
---@return string[]
function M.locked_missing()
  local lock = read_json(vim.go.packlockfile)
  local res = {}
  for name in pairs(lock and type(lock.plugins) == 'table' and lock.plugins or {}) do
    if not uv.fs_stat(vim.fs.joinpath(M.dir, name)) then
      res[#res + 1] = name
    end
  end
  return res
end

--- Give plugins that are not installed yet the commit lazy-lock.json records, by
--- writing it to vim.pack's lockfile, which the first vim.pack.add installs from.
--- A plugin on disk or in the lockfile already is left alone.
---@param plugins cinch.Plugin[]
---@return string[] names taken from lazy-lock.json
function M.import_lazy_lock(plugins)
  local path = vim.fs.joinpath(vim.fn.stdpath('config') --[[@as string]], 'lazy-lock.json')
  if synced or not uv.fs_stat(path) then
    return {}
  end
  local lazy, lock = read_json(path) or {}, read_json(vim.go.packlockfile) or {}
  if type(lock.plugins) ~= 'table' then
    lock.plugins = {}
  end
  local names = {}
  for _, p in ipairs(plugins) do
    local l = lazy[p.name]
    local commit = type(l) == 'table' and l.commit
    if
      type(commit) == 'string'
      and commit:find('^%x+$')
      and lock.plugins[p.name] == nil
      and not uv.fs_stat(vim.fs.joinpath(M.dir, p.name))
    then
      lock.plugins[p.name] = { src = p.src, rev = commit }
      names[#names + 1] = p.name
    end
  end
  if #names > 0 then
    vim.fn.mkdir(vim.fs.dirname(vim.go.packlockfile), 'p')
    local json = vim.json.encode(lock, { indent = '  ', sort_keys = true })
    vim.fn.writefile(vim.split(json, '\n'), vim.go.packlockfile)
  end
  return names
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

--- How long an async function build may take before it fails, in ms.
M.timeout = 300000

-- Lines of build output kept on the plugin.
local log_max = 100

--- New lines of a build's output onto `p.build_log`, without terminal colors.
---@param p cinch.Plugin
---@param lines string[]
local function add_output(p, lines)
  local log = p.build_log or {}
  for _, line in ipairs(lines) do
    log[#log + 1] = line
  end
  while #log > log_max do
    table.remove(log, 1)
  end
  p.build_log = log
  if events.has('BuildOutput') then
    events.emit('BuildOutput', { plugin = p, lines = lines })
  end
end

--- A vim.system stream reader: collects the whole text in `raw` and passes each
--- complete line on as it arrives. A carriage return ends a line too, so a progress
--- counter shows as it moves.
---@param p cinch.Plugin
---@param raw string[]
---@return fun(err?: string, data?: string)
local function reader(p, raw)
  local partial = ''
  return function(_, data)
    raw[#raw + 1] = data
    local parts = vim.split(partial .. (data or ''), '[\r\n]')
    partial = data and table.remove(parts) or ''
    local lines = {}
    for _, part in ipairs(parts) do
      local line = vim.trim((part:gsub('\27%[[%d;?]*%a', '')))
      if line ~= '' then
        lines[#lines + 1] = line
      end
    end
    if #lines > 0 then
      vim.schedule(function()
        add_output(p, lines)
      end)
    end
  end
end

--- A shell command, in the background from the plugin's directory. Its output
--- streams onto `p.build_log` as it runs.
---@param p cinch.Plugin
---@param cmd string
---@param start integer
local function shell_build(p, cmd, start)
  state.activity(p, 'building')
  local out, errs = {}, {}
  -- sh on Unix, whatever your 'shell' is (fish, nushell), so a build runs the same
  -- everywhere; on Windows your 'shell', its flags split into words (PowerShell's are several).
  local argv = vim.fn.has('win32') == 1
      and vim.list_extend({ vim.o.shell }, vim.split(vim.o.shellcmdflag, ' ', { trimempty = true }))
    or { 'sh', '-c' }
  argv[#argv + 1] = cmd
  vim.system(argv, {
    cwd = p.path,
    text = true,
    stdout = reader(p, out),
    stderr = reader(p, errs),
  }, function(r)
    local stderr = vim.trim(table.concat(errs))
    local output = vim.trim(table.concat(out) .. table.concat(errs))
    local err = r.code ~= 0 and (stderr ~= '' and stderr or ('exit ' .. r.code)) or nil
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
  -- `function(p, done)` is async: the build ends when it calls done, or fails
  -- after M.timeout, so what waits on it is not stuck forever.
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
  if async then
    vim.defer_fn(function()
      done(false, ('did not call done() within %ds'):format(M.timeout / 1000))
    end, M.timeout)
  end
  local ok, err = pcall(fn, p, async and done or nil)
  if not on_rtp and p.state ~= 'loaded' then
    vim.opt.rtp:remove(p.path)
    -- vim.loader searches its cached runtimepath first and re-reads it only after
    -- a miss; without one it would keep finding this plugin's modules. This leans on
    -- how vim.loader caches today; the builds test pins it with vim.loader enabled.
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
  p.build_log = {}
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
    specs[i] = { src = p.src, name = p.name, version = p.version, data = M.portable(p.data) }
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

--- The names of the plugins a kind of change reached while `fn` ran, in order.
---@param kind 'update'|'delete'
---@param fn fun(): boolean, any
---@return string[] reached, boolean ok, any err
local function reaching(kind, fn)
  local reached = {}
  local off = events.on('Pack', function(d)
    if d.kind == kind then
      reached[#reached + 1] = d.name
    end
  end)
  local ok, res = fn()
  off()
  return reached, ok, res
end

---@param names string[]
---@param reached string[]
---@return string[] those of `names` not in `reached`
local function missed(names, reached)
  return vim.tbl_filter(function(name)
    return not vim.list_contains(reached, name)
  end, names)
end

--- vim.pack.update through cinch, so the bus sees it. One that applies without the
--- review tab is framed by Updating and Updated, and says how it ended; a review tab
--- and a restore from the lockfile are not.
---@param names? string[]
---@param opts? vim.pack.keyset.update
---@return boolean ok, any err
function M.update(names, opts)
  opts = opts or {}
  if not opts.force or opts.target == 'lockfile' then
    return call('update', names, vim.pack.update, names, opts)
  end
  local asked = names
    or vim.tbl_map(
      function(p)
        return p.name
      end,
      vim.tbl_filter(function(p)
        return p.path ~= nil
      end, state.list)
    )
  local start = uv.hrtime()
  events.emit('Updating', { names = asked })
  local updated, ok, res = reaching('update', function()
    return call('update', names, vim.pack.update, names, opts)
  end)
  local restart = vim.iter(updated):any(function(name)
    local p = state.plugins[name]
    return p ~= nil and p.state == 'loaded'
  end)
  -- Without names a plugin with nothing new is not a failure; with them, it is.
  local failed = (not ok and names) and missed(names, updated) or {}
  local d = {
    names = asked,
    updated = updated,
    failed = failed,
    total = names and #names or #updated + #failed,
    ms = (uv.hrtime() - start) / 1e6,
    restart = restart,
  }
  events.emit('Updated', d)
  events.report(require('cinch.ops').summary('update', d))
  return ok, res
end

--- vim.pack.del through cinch. vim.pack fires PackChangedPre for every plugin
--- named but PackChanged only for those it deleted, so the rest stop "deleting" here.
---@param names string[]
---@param opts? vim.pack.keyset.del
---@return boolean ok, any err
function M.del(names, opts)
  local start = uv.hrtime()
  events.emit('Deleting', { names = names })
  local deleted, ok, res = reaching('delete', function()
    return call('del', names, vim.pack.del, names, opts)
  end)
  for _, name in ipairs(names) do
    local p = state.plugins[name]
    if p and p.activity == 'deleting' then
      state.activity(p, nil)
    end
  end
  local d = { names = names, deleted = deleted, failed = missed(names, deleted), ms = (uv.hrtime() - start) / 1e6 }
  events.emit('Deleted', d)
  if #deleted > 0 then
    events.report(require('cinch.ops').summary('delete', d))
  end
  return ok, res
end

--- Whether `path` is cinch's own folder, links resolved: a clean never deletes it.
---@param path string
---@return boolean
local function is_own(path)
  local cinch = package.loaded['cinch']
  local own = cinch and cinch.own_dir
  return own ~= nil and (uv.fs_realpath(path) or path) == (uv.fs_realpath(own) or own)
end

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
    if not d.active and not state.plugins[d.spec.name] and not is_own(d.path) then
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

--- The commit a ref names in the git dir: its loose ref file, else packed-refs.
---@param git string the .git directory
---@param ref string such as refs/heads/main
---@return string?
local function resolve_ref(git, ref)
  local f = io.open(vim.fs.joinpath(git, ref))
  if f then
    local line = f:read('*l') or ''
    f:close()
    if line:match('^%x+$') then
      return line
    end
  end
  f = io.open(vim.fs.joinpath(git, 'packed-refs'))
  if not f then
    return nil
  end
  for line in f:lines() do
    local sha, name = line:match('^(%x+) (.+)$')
    if name == ref then
      f:close()
      return sha
    end
  end
  f:close()
  return nil
end

--- The plugin's checked-out commit. `.git/HEAD` holds the hash when it is detached,
--- which is how vim.pack leaves a repo, or `ref: refs/heads/<branch>` when a branch
--- is checked out, and then the commit is the one that ref names. Read once and kept
--- until it changes.
---@param p cinch.Plugin
---@return string?
function M.rev(p)
  if p.rev == nil and p.path then
    local git = vim.fs.joinpath(p.path, '.git')
    local f = io.open(vim.fs.joinpath(git, 'HEAD'))
    if f then
      local line = f:read('*l') or ''
      f:close()
      local ref = line:match('^ref: (.+)$')
      p.rev = ref and resolve_ref(git, ref) or line:match('^%x+$')
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
