-- Public API and the startup sequence:
-- collect specs -> register -> vim.pack.add -> init hooks -> arm -> now, then later.

local events = require('cinch.events')
local handler = require('cinch.handler')
local loader = require('cinch.loader')
local pack = require('cinch.pack')
local spec = require('cinch.spec')
local state = require('cinch.state')

local levels, hrtime = vim.log.levels, vim.uv.hrtime

local M = {}

M.on = events.on
M.trigger = handler.register
M.now = handler.now
M.later = handler.later
M.now_if_args = handler.now_if_args

---@class cinch.Opts
---@field spec? (string|cinch.Spec|cinch.Spec[])[] module paths, directories or specs; default { 'plugins' }
---@field confirm? boolean ask before installing, vim.pack's prompt; default true
---@field budget? integer ms of `later` loading per event-loop tick; default 5
---@field defer? boolean when plugins are missing, install once the UI is up, not during init.lua; default true
---@field build_timeout? integer seconds an async function build may take before it fails; default 300
---@field disable_runtime? string[] Neovim's own plugins not to load: 'netrwPlugin', 'gzip', 'tutor'; default {}
---@field self? boolean|{ version?: any, tag?: string, branch?: string, commit?: string } update cinch as one of its
---plugins when it lives in vim.pack's folder; a table pins it, as in a spec; default true: its default branch
---@field features? string[] modules under cinch.features to load; default { 'messages', 'stats', 'updates', 'ui' }
---@field [string] table a feature's options, under its name

---@type cinch.Opts
local defaults = {
  spec = { 'plugins' },
  confirm = true,
  budget = 5,
  defer = true,
  build_timeout = 300,
  disable_runtime = {},
  self = true,
  features = { 'messages', 'stats', 'updates', 'ui' },
}

---@type cinch.Opts? set by setup()
M.opts = nil

--- Neovim's own plugins that disable_runtime kept from loading, by name.
---@type string[]
M.runtime_off = {}

--- Keep the plugins of $VIMRUNTIME/plugin that you name from loading at startup:
--- 'netrwPlugin', 'gzip', 'tarPlugin', 'zip', 'tutor', 'tohtml', 'rplugin' and so on,
--- by file name. They have no common switch to turn them off, so for startup's own
--- pass a SourceCmd autocmd stands in for each of those files and sources only the
--- others. After startup it is gone: :runtime and :source work as usual.
---@param names string[]
local function disable_runtime(names)
  if #names == 0 then
    return
  end
  if vim.v.vim_did_init == 1 then
    return events.report('disable_runtime works only from init.lua, before Neovim loads its plugins', levels.WARN)
  end
  local dir = vim.fs.joinpath(vim.env.VIMRUNTIME, 'plugin')
  local known, off = {}, {}
  for _, f in ipairs(vim.fn.glob(dir .. '/*.{vim,lua}', false, true)) do
    known[vim.fn.fnamemodify(f, ':t:r')] = true
  end
  for _, name in ipairs(names) do
    if known[name] then
      off[name] = true
      M.runtime_off[#M.runtime_off + 1] = name
    else
      local all = vim.tbl_keys(known)
      table.sort(all)
      events.report(
        ('disable_runtime: no runtime plugin `%s`; there are %s'):format(name, table.concat(all, ', ')),
        levels.WARN
      )
    end
  end
  if #M.runtime_off == 0 then
    return
  end
  local id = vim.api.nvim_create_autocmd('SourceCmd', {
    pattern = dir .. '/*',
    desc = 'cinch: skip the runtime plugins in disable_runtime',
    callback = function(ev)
      if off[vim.fn.fnamemodify(ev.match, ':t:r')] then
        return
      end
      -- A SourceCmd stands in for Neovim's own sourcing, which fires these; without
      -- them the Profile view and anything else listening never sees the file.
      local autocmd = { pattern = ev.match, modeline = false }
      vim.api.nvim_exec_autocmds('SourcePre', autocmd)
      local ok, err = pcall(vim.cmd.source, { ev.match, magic = { file = false } })
      vim.api.nvim_exec_autocmds('SourcePost', autocmd)
      if not ok then
        error(err, 0)
      end
    end,
  })
  vim.api.nvim_create_autocmd('VimEnter', {
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_autocmd, id)
    end,
  })
end

--- cinch's own folder: three levels up from this file.
M.own_dir = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

---@param path string
---@return string
local function real(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- The url of a repo's origin remote, read from its .git/config.
---@param dir string
---@return string?
local function origin_of(dir)
  local f = io.open(vim.fs.joinpath(dir, '.git', 'config'))
  if not f then
    return
  end
  local text = f:read('*a')
  f:close()
  local section = text:match('%[remote "origin"%](.-)\n%[') or text:match('%[remote "origin"%](.*)$')
  return section and section:match('\n%s*url%s*=%s*(%S+)')
end

--- cinch as one of its own plugins, so the update check, `u` and `:Cinch update`
--- keep it current like the rest. Only when it lives in vim.pack's folder, where
--- the install clones it: a checkout anywhere else is yours to manage. A spec of
--- yours that lists it is used as it is.
---@param added cinch.Plugin[]
local function adopt_self(added)
  if (M.opts or defaults).self == false or vim.fs.dirname(real(M.own_dir)) ~= real(pack.dir) then
    return
  end
  local name = vim.fs.basename(M.own_dir)
  local p = state.plugins[name]
  local src = not p and origin_of(M.own_dir)
  if src then
    local file = vim.fs.joinpath(M.own_dir, 'lua', 'cinch', 'init.lua')
    local own = { src = src, name = name, load = 'now' }
    -- `self = { tag = 'v1.0.0' }` pins it, with the keys a spec pins a plugin with.
    local pin = (M.opts or defaults).self
    if type(pin) == 'table' then
      for _, k in ipairs({ 'version', 'tag', 'branch', 'commit' }) do
        own[k] = pin[k]
      end
    end
    p = spec.register({ { spec = own, origin = { file = file } } })[1]
    added[#added + 1] = p
  end
  if p then
    p.self = true
  end
end

---@param name string
---@param start integer hrtime
local function phase(name, start)
  if events.has('Phase') then
    events.emit('Phase', { name = name, ms = (hrtime() - start) / 1e6, start = start })
  end
end

--- Where setup() or add() was called from, for messages about inline specs.
---@return cinch.Origin
local function caller()
  local info = debug.getinfo(3, 'S')
  return { file = info and info.source:gsub('^@', '') or '?' }
end

--- `enabled` or `cond` set to false, or a function returning false, turns a plugin off.
--- A function that raises leaves it on, with a warning.
---@param p cinch.Plugin
---@return boolean on, string? why
local function enabled(p)
  for _, k in ipairs({ 'enabled', 'cond' }) do
    local v = p.data[k]
    if type(v) == 'function' then
      local ok, res = pcall(v, p)
      if not ok then
        events.report(('`%s`: %s raised, so it stays on: %s'):format(p.name, k, res), levels.WARN)
      elseif res == false then
        return false, k
      end
    elseif v == false then
      return false, k
    end
  end
  return true
end

--- Install a batch in one vim.pack.add call, telling the bus when it starts and ends.
---@param install cinch.Plugin[]
---@param confirm? boolean
local function install_all(install, confirm)
  local t = hrtime()
  local missing = {}
  for _, p in ipairs(install) do
    if not vim.uv.fs_stat(vim.fs.joinpath(pack.dir, p.name)) then
      missing[#missing + 1] = p.name
    end
  end
  if #missing > 0 and events.has('Installing') then
    events.emit('Installing', { names = missing })
  end
  local failed = {}
  for _, p in ipairs(pack.add(install, confirm)) do
    p.err = 'not installed'
    state.set(p, 'failed', 'install')
    failed[#failed + 1] = p.name
  end
  if #missing > 0 and events.has('Installed') then
    events.emit('Installed', { names = missing, failed = failed, ms = (hrtime() - t) / 1e6 })
  end
  phase('install', t)
end

--- Run init hooks, arm every plugin on disk, then load what can load now.
---@param install cinch.Plugin[]
local function start(install)
  local t = hrtime()
  for _, p in ipairs(install) do
    if p.state == 'registered' then
      local ok, err = loader.hook(p, 'init')
      if not ok then
        events.report(('`%s` %s'):format(p.name, err), levels.ERROR)
      end
      state.set(p, 'pending')
      handler.arm(p)
    end
  end
  phase('init', t)

  t = hrtime()
  handler.start()
  phase('now', t)
  -- `:Cmd` builds of plugins installed in this batch can run now they are armed.
  pack.run_waiting()
end

--- Whether a UI will attach. Headless Neovim never gets one. Replaceable for tests.
---@return boolean
function M.ui_coming()
  return not vim.list_contains(vim.v.argv, '--headless')
end

---@type { plugins: cinch.Plugin[], confirm?: boolean, done?: boolean }? a batch waiting for UIEnter
local deferred

--- Done: setup() has read the specs and loaded the `now` plugins. When a batch
--- waits for the UI, that is once the batch has installed and started.
local function done()
  events.emit('Done', {})
end

--- The plugins to hold until the UI is up, so the window can show them install:
--- none when nothing is missing or no UI is coming; the missing ones; or all of
--- them when the lockfile lists plugins that are not on disk, as on a new machine,
--- because the first vim.pack.add would install those during init.lua anyway.
---@param install cinch.Plugin[]
---@return cinch.Plugin[]
local function to_defer(install)
  if (M.opts or defaults).defer == false or vim.v.vim_did_enter == 1 or not M.ui_coming() then
    return {}
  end
  local missing = vim.tbl_filter(function(p)
    return not vim.uv.fs_stat(vim.fs.joinpath(pack.dir, p.name))
  end, install)
  -- The lockfile matters only before vim.pack's first call of the session.
  if #missing > 0 and not pack.idle() and #pack.locked_missing() > 0 then
    return install
  end
  return missing
end

--- `wait` plus every plugin of `install` that needs one of them, however deeply:
--- one that loaded during init.lua would load without its dependency.
---@param wait cinch.Plugin[]
---@param install cinch.Plugin[]
---@return cinch.Plugin[] in declaration order
local function with_dependents(wait, install)
  local held = {}
  for _, p in ipairs(wait) do
    held[p.name] = true
  end
  local grew = #wait > 0
  while grew do
    grew = false
    for _, p in ipairs(install) do
      if not held[p.name] and vim.iter(p.deps):any(function(d)
        return held[d]
      end) then
        held[p.name], grew = true, true
      end
    end
  end
  return vim.tbl_filter(function(p)
    return held[p.name]
  end, install)
end

--- Install, init and arm new plugins, then load what can load now. Plugins that
--- must wait for the UI do all of that on UIEnter instead.
---@param added cinch.Plugin[]
---@param confirm? boolean
local function activate(added, confirm)
  local install = {}
  for _, p in ipairs(added) do
    local on, why = enabled(p)
    if on then
      install[#install + 1] = p
    else
      state.set(p, 'disabled', why)
    end
  end
  if deferred then
    -- add() while a batch waits: it joins the batch.
    vim.list_extend(deferred.plugins, install)
    return
  end
  local wait = with_dependents(to_defer(install), install)
  local now = #wait == 0 and install
    or vim.tbl_filter(function(p)
      return not vim.list_contains(wait, p)
    end, install)
  if #now > 0 then
    install_all(now, confirm)
  end
  start(now)
  if #wait > 0 then
    deferred = { plugins = wait, confirm = confirm }
    -- When the whole batch waits (a first start, a new machine), cinch.now()
    -- functions wait with it; when only some plugins are missing, the rest started.
    handler.held = #now == 0
    vim.api.nvim_create_autocmd('UIEnter', {
      once = true,
      callback = vim.schedule_wrap(function()
        local d = deferred --[[@as table]]
        deferred = nil
        install_all(d.plugins, d.confirm)
        handler.held = false
        start(d.plugins)
        if d.done then
          done()
        end
      end),
    })
  end
end

--- Load each feature named in opts.features. A feature that is not there is skipped.
---@param opts cinch.Opts
local function load_features(opts)
  for _, name in ipairs(opts.features) do
    local mod = 'cinch.features.' .. name
    local ok, f = pcall(require, mod)
    if not ok then
      if not tostring(f):find(("module '%s' not found"):format(mod), 1, true) then
        events.report(('feature `%s`: %s'):format(name, f), levels.ERROR)
      end
    elseif type(f) == 'table' and type(f.setup) == 'function' then
      local ran, err = pcall(f.setup, opts[name] or {})
      if not ran then
        events.report(('feature `%s`: %s'):format(name, err), levels.ERROR)
      end
    end
  end
end

--- Read your specs and start your plugins. Call it once, from init.lua.
---@param opts? cinch.Opts
function M.setup(opts)
  if M.opts then
    return events.report('setup() already ran; use add() for more plugins', levels.WARN)
  end
  M.opts = vim.tbl_extend('force', defaults, opts or {})
  handler.budget = M.opts.budget
  disable_runtime(M.opts.disable_runtime)
  pack.timeout = M.opts.build_timeout * 1000
  load_features(M.opts)
  local t = hrtime()
  local added = spec.register(spec.collect(M.opts.spec, caller()))
  adopt_self(added)
  phase('specs', t)
  activate(added, M.opts.confirm)
  -- User CinchDone, for config code that runs once cinch has set everything up: now,
  -- or once a batch that waits for the UI has installed and loaded too.
  if deferred then
    deferred.done = true
  else
    done()
  end
end

--- Add plugins, the way vim.pack.add does: a list of specs, cinch fields allowed.
---@param specs (string|cinch.Spec)[]
---@param opts? { confirm?: boolean }
---@return cinch.Plugin[] added
function M.add(specs, opts)
  local confirm = opts and opts.confirm
  if confirm == nil then
    confirm = (M.opts or defaults).confirm
  end
  local added = spec.register(spec.collect({ specs }, caller()))
  activate(added, confirm)
  return added
end

---@param names string|string[]
---@return cinch.Plugin[]
local function resolve(names)
  local res = {}
  for _, name in ipairs(type(names) == 'table' and names or { names }) do
    local p = state.plugins[name]
    if p then
      res[#res + 1] = p
    else
      events.report(('no plugin named `%s`'):format(name), levels.WARN)
    end
  end
  return res
end

--- Load plugins now, whatever they were waiting for.
---@param names string|string[]
---@param reason? string
function M.load(names, reason)
  for _, p in ipairs(resolve(names)) do
    loader.load(p, reason or 'manual')
  end
end

--- Run plugins' builds again.
---@param names string|string[]
function M.build(names)
  vim.tbl_map(pack.build, resolve(names))
end

--- One plugin record, or all of them in declaration order.
---@param name? string
---@return cinch.Plugin|cinch.Plugin[]|nil
function M.get(name)
  if name then
    return state.plugins[name]
  end
  return state.list
end

M.update = pack.update

--- Delete plugins from disk through vim.pack. A plugin your specs list is in use
--- this session, so vim.pack deletes it only with `force`, and it installs again
--- on the next start unless you take it out of your specs.
---@param names string|string[]
---@param opts? { force?: boolean }
---@return boolean ok, any err
function M.del(names, opts)
  names = type(names) == 'table' and names or { names }
  -- Not cinch itself: the code doing the deleting.
  names = vim.tbl_filter(function(name)
    local p = state.plugins[name]
    if p and p.self then
      events.report(('not deleted: `%s` is cinch itself'):format(name), levels.WARN)
      return false
    end
    return true
  end, names)
  if #names == 0 then
    return false, 'nothing to delete'
  end
  local ok, err = pack.del(names, opts)
  if not ok then
    -- vim.pack says which plugins it kept only in its error text; the delete test
    -- pins this wording, so a change upstream fails there, not silently here.
    local active = tostring(err):match('active and were not deleted: (.-)%. Remove')
    local why = ('delete failed: %s'):format((tostring(err):gsub('^[^:]*:%d+: ', '')))
    if active then
      why = ('not deleted: %s is in your specs and in use. Take it out of your specs and restart, '):format(active)
        .. 'or `:Cinch del!` deletes it now and it installs again on the next start'
    end
    events.report(why, levels.ERROR)
  end
  return ok, err
end

--- Delete every plugin on disk that no spec names.
---@return string[] deleted
function M.clean()
  local names = vim.tbl_map(function(o)
    return o.name
  end, pack.orphans())
  if #names == 0 then
    events.report('nothing to clean: every plugin on disk is in your specs')
    return {}
  end
  return M.del(names) and names or {}
end

return M
