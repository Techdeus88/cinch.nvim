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
---@field features? string[] modules under cinch.features to load; default { 'messages', 'stats', 'updates', 'ui' }
---@field [string] table a feature's options, under its name

---@type cinch.Opts
local defaults = {
  spec = { 'plugins' },
  confirm = true,
  budget = 5,
  defer = true,
  features = { 'messages', 'stats', 'updates', 'ui' },
}

---@type cinch.Opts? set by setup()
M.opts = nil

---@param name string
---@param start integer hrtime
local function phase(name, start)
  if events.has('Phase') then
    events.emit('Phase', { name = name, ms = (hrtime() - start) / 1e6 })
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

---@type { plugins: cinch.Plugin[], confirm?: boolean }? a batch waiting for UIEnter
local deferred

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
  local wait = to_defer(install)
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
  load_features(M.opts)
  local t = hrtime()
  local added = spec.register(spec.collect(M.opts.spec, caller()))
  phase('specs', t)
  activate(added, M.opts.confirm)
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
  local ok, err = pack.del(names, opts)
  if not ok then
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
