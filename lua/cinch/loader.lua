-- Loading one plugin: its dependencies, packadd, config and after, in that order.
-- A plugin moves pending -> loading -> loaded or failed. Loading never throws
-- into whatever asked for it; a failure is reported and recorded on the plugin.

local events = require('cinch.events')
local handler = require('cinch.handler')
local pack = require('cinch.pack')
local state = require('cinch.state')

local api, uv = vim.api, vim.uv

local M = {}

-- Load sequence number, for the order plugins loaded in.
local count = 0

--- Announce one part of a load, begun at hrtime `t`, for the Profile view.
---@param p cinch.Plugin
---@param name 'init'|'packadd'|'opts'|'config'|'after'
---@param t integer hrtime
---@param ok boolean
function M.step(p, name, t, ok)
  if events.has('Step') then
    events.emit('Step', { plugin = p, name = name, start = t, ms = (uv.hrtime() - t) / 1e6, ok = ok })
  end
end

--- Call a spec hook in protected mode.
---@param p cinch.Plugin
---@param name 'init'|'opts'|'config'|'after'
---@return boolean ok, any result or error
function M.hook(p, name, ...)
  local fn = p.data[name]
  if type(fn) ~= 'function' then
    return true, nil
  end
  local t = uv.hrtime()
  local ok, res = xpcall(fn, debug.traceback, p, ...)
  M.step(p, name, t, ok)
  if not ok then
    res = ('%s: %s'):format(name, res)
  end
  return ok, res
end

---@param s string
---@return string
local function norm(s)
  return (s:lower():gsub('^n?vim[-_.]', ''):gsub('[-_.]n?vim$', ''):gsub('%.lua$', ''):gsub('[^%w]', ''))
end

--- The module whose setup() gets opts: `main`, the one in lua/ named like the
--- plugin or its repo, or the only one there. From sarcina's main_module.lua.
---@param p cinch.Plugin
---@return string
local function main_module(p)
  if p.data.main then
    return p.data.main
  end
  local wanted = { norm(p.name), norm(p.src:gsub('%.git$', ''):match('[^/]+$') or '') }
  local mods = {}
  for entry, kind in vim.fs.dir(vim.fs.joinpath(p.path, 'lua')) do
    local mod = kind == 'directory' and entry or entry:match('^(.+)%.lua$')
    if mod then
      if norm(mod) == wanted[1] or norm(mod) == wanted[2] then
        return mod
      end
      mods[#mods + 1] = mod
    end
  end
  if #mods == 1 then
    return mods[1]
  end
  table.sort(mods)
  error(('cannot tell which module gets opts (%s); set `main`'):format(table.concat(mods, ', ')), 0)
end

--- opts, then config: config(p, opts), or require(main).setup(opts).
---@param p cinch.Plugin
---@return boolean ok, string? err
local function configure(p)
  local d = p.data
  local opts = d.opts
  if type(opts) == 'function' then
    -- sarcina style: return a table, or fill in the empty one given.
    local given = {}
    local ok, res = M.hook(p, 'opts', given)
    if not ok then
      return false, res
    end
    opts = res == nil and given or res
  end
  -- What the plugin was given, for the UI's spec view.
  p.opts_used = opts
  if type(d.config) == 'function' then
    return M.hook(p, 'config', opts or {})
  end
  if d.config == true or opts ~= nil then
    local t = uv.hrtime()
    local ok, err = xpcall(function()
      local main = main_module(p)
      p.main_used = main
      local mod = require(main)
      if type(mod) ~= 'table' or type(mod.setup) ~= 'function' then
        error(('`%s` has no setup(); set `main` or `config`'):format(main), 0)
      end
      mod.setup(opts or {})
    end, function(e)
      return 'config: ' .. tostring(e)
    end)
    M.step(p, 'config', t, ok)
    return ok, err
  end
  return true
end

---@param path string
---@return string
local function real(path)
  return uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- Source the plugin's after/plugin/ files, skipping those in `done`.
---@param p cinch.Plugin
---@param done? table<string, true> real paths already sourced
local function source_after(p, done)
  -- Most plugins have no after/: skip the recursive glob for them.
  if not p.path or not uv.fs_stat(p.path .. '/after') then
    return
  end
  for _, f in ipairs(vim.fn.glob(p.path .. '/after/plugin/**/*.{vim,lua}', false, true)) do
    if not (done and done[real(f)]) then
      vim.cmd.source({ f, magic = { file = false } })
    end
  end
end

-- Plugins packadded after init.lua but before VimEnter, a file on the command line
-- triggering an ft plugin say. Neovim's after/plugin/ pass may already be over by
-- then, so VimEnter sources what it missed, and only that.
---@type cinch.Plugin[]
local late = {}

local function source_late()
  local done = {}
  for _, info in ipairs(vim.fn.getscriptinfo()) do
    done[real(info.name)] = true
  end
  for _, p in ipairs(late) do
    source_after(p, done)
  end
  late = {}
end

--- Whether `path` is on the runtimepath as written there. A plain compare: realpath on
--- every entry for every load cost ~40 ms over 50 plugins.
---@param path string
---@return boolean
local function on_rtp(path)
  return vim.list_contains(vim.opt.rtp:get() --[[@as string[] ]], path)
end

---@param p cinch.Plugin
local function packadd(p)
  -- Already on the runtimepath, put there by your init.lua: cinch itself, say, or a
  -- plugin you packadd yourself. Its plugin/ files ran then; again would run them twice.
  if p.path and on_rtp(p.path) then
    return
  end
  local name = vim.fn.escape(p.name, ' ')
  -- While init.lua runs, Neovim's load-plugins step sources plugin/ and
  -- after/plugin/ later, in normal startup order; :packadd! only adds the path.
  if vim.v.vim_did_init == 0 then
    vim.cmd.packadd({ name, bang = true, magic = { file = false } })
    return
  end
  vim.cmd.packadd({ name, magic = { file = false } })
  if vim.v.vim_did_enter == 0 then
    if #late == 0 then
      api.nvim_create_autocmd('VimEnter', { once = true, callback = source_late })
    end
    late[#late + 1] = p
    return
  end
  -- After startup :packadd does not source after/plugin/.
  source_after(p)
  -- :packadd sourced its ftdetect/; buffers opened before it never saw them.
  if #vim.fn.glob(p.path .. '/ftdetect/*.{vim,lua}', false, true) > 0 then
    for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == '' and vim.bo[b].filetype == '' then
        api.nvim_buf_call(b, function()
          vim.cmd('filetype detect')
        end)
      end
    end
  end
end

--- A build that must end before `p` loads: its own, or that of any dependency not
--- loaded yet, however deep.
---@param p cinch.Plugin
---@param seen? table<cinch.Plugin, true>
---@return cinch.Plugin?
local function building(p, seen)
  seen = seen or {}
  if seen[p] then
    return
  end
  seen[p] = true
  if p.activity == 'building' then
    return p
  end
  for _, name in ipairs(p.deps) do
    local d = state.plugins[name]
    local b = d and d.state ~= 'loaded' and building(d, seen)
    if b then
      return b
    end
  end
end

-- Why a dependency did not load, by its state.
local dep_why = {
  disabled = 'is disabled',
  failed = 'failed to load',
  registered = 'is not installed yet',
  pending = 'did not load',
}

---@type table<cinch.Plugin, fun()[]> plugins waiting for a build, and who waits on each
local waiting = {}

---@param p cinch.Plugin
---@param reason string
---@param err string
local function fail(p, reason, err)
  p.err = err
  state.set(p, 'failed', reason)
  events.report(('`%s` failed to load: %s'):format(p.name, err), vim.log.levels.ERROR)
  if events.has('LoadError') then
    events.emit('LoadError', { plugin = p, reason = reason, err = err })
  end
end

--- Load a pending plugin and its dependencies. `done` runs once, when it has
--- loaded or failed, which may be later if a build is still running.
---@param p cinch.Plugin
---@param reason string 'now', 'later', 'event BufReadPost', 'dep of x', ...
---@param done? fun()
---@return boolean loaded now
function M.load(p, reason, done)
  done = done or function() end
  if p.state ~= 'pending' then
    done()
    return p.state == 'loaded'
  end
  -- Its build makes something it needs: load once the build ends, never block.
  local b = building(p)
  if b then
    -- Asked again while it waits, a completion on every keystroke say: one wait.
    if waiting[p] then
      table.insert(waiting[p], done)
      return false
    end
    waiting[p] = { done }
    if events.has('LoadWait') then
      events.emit('LoadWait', { plugin = p, reason = reason, build = b })
    end
    pack.after_build(b, function()
      local list = waiting[p]
      waiting[p] = nil
      M.load(p, reason, function()
        for _, fn in ipairs(list) do
          fn()
        end
      end)
    end)
    return false
  end
  local pre = events.has('LoadPre') and events.emit('LoadPre', { plugin = p, reason = reason }) or {}
  if pre.cancel then
    events.report(('`%s` not loaded: %s'):format(p.name, pre.cancel_reason or 'cancelled'))
    done()
    return false
  end

  state.set(p, 'loading', reason)
  for _, name in ipairs(p.deps) do
    local d = state.plugins[name]
    if d.state == 'loading' then
      events.report(('dependency cycle: `%s` and `%s`'):format(p.name, name), vim.log.levels.WARN)
    elseif not M.load(d, 'dep of ' .. p.name) then
      -- No build is running anywhere below (checked above), so it will not load
      -- later either: disabled, failed, cancelled or not installed. Loading without
      -- it would only fail in a stranger way.
      handler.disarm(p)
      fail(p, reason, ('dependency `%s` %s'):format(name, dep_why[d.state] or d.state))
      done()
      return false
    end
  end
  -- Before packadd, so a stub never shadows or deletes what the plugin defines.
  handler.disarm(p)
  pack.rev(p)

  local t0 = uv.hrtime()
  local ok, err = pcall(packadd, p)
  M.step(p, 'packadd', t0, ok)
  local t1 = uv.hrtime()
  if ok then
    ok, err = configure(p)
  end
  if ok then
    ok, err = M.hook(p, 'after')
  end
  local t2 = uv.hrtime()
  if not ok then
    fail(p, reason, tostring(err))
    done()
    return false
  end

  count = count + 1
  p.order = count
  handler.loaded(p)
  state.set(p, 'loaded', reason)
  -- Always emitted: it is also the `User CinchLoad` autocmd.
  events.emit('Load', { plugin = p, reason = reason, ms = { packadd = (t1 - t0) / 1e6, config = (t2 - t1) / 1e6 } })
  done()
  return true
end

return M
