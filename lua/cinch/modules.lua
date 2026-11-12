-- Load a plugin when something requires one of its modules. The searcher sits last in
-- package.loaders, so a module that resolves normally never reaches it.

local events = require('cinch.events')
local loader = require('cinch.loader')
local pack = require('cinch.pack')
local state = require('cinch.state')

local uv = vim.uv

local M = {}

---@type table<string, cinch.Plugin[]>? top-level module -> plugins, in declaration order; nil: scan on the next miss
local tops

---@type table<string, true> modules already warned about
local warned = {}

---@param p cinch.Plugin
---@return string
local function dir_of(p)
  return p.path or vim.fs.joinpath(pack.dir, p.name)
end

---@param p cinch.Plugin
---@return boolean
local function on_disk(p)
  return uv.fs_stat(dir_of(p)) ~= nil
end

--- A plugin with no files says nothing about its modules, so go by `main` and its name.
---@param p cinch.Plugin
---@return string[]
local function guess_tops(p)
  local name = p.name:gsub('%.n?vim$', ''):gsub('%.lua$', ''):gsub('^n?vim%-', '')
  return { type(p.data.main) == 'string' and p.data.main:match('^[^.]+') or name }
end

---@param p cinch.Plugin
---@return string[]
local function tops_of(p)
  if not on_disk(p) then
    return guess_tops(p)
  end
  local res = {}
  for entry, kind in vim.fs.dir(vim.fs.joinpath(dir_of(p), 'lua')) do
    res[#res + 1] = kind == 'file' and entry:match('^(.+)%.%w+$') or entry
  end
  return res
end

---@return table<string, cinch.Plugin[]>
local function scan()
  local res = {}
  for _, p in ipairs(state.list) do
    if not p.self then
      for _, top in ipairs(tops_of(p)) do
        res[top] = res[top] or {}
        table.insert(res[top], p)
      end
    end
  end
  return res
end

---@param p cinch.Plugin
---@param mod string
---@return boolean
local function provides(p, mod)
  if not on_disk(p) then
    return true
  end
  local file = vim.fs.joinpath(dir_of(p), 'lua', (mod:gsub('%.', '/')))
  for _, suffix in ipairs({ '.lua', '/init.lua', '.so', '.dll' }) do
    if uv.fs_stat(file .. suffix) then
      return true
    end
  end
  return false
end

--- The plugins that could provide `mod`: none has loaded, or Lua would have found it.
---@param mod string
---@return cinch.Plugin[]
local function providers(mod)
  tops = tops or scan()
  return vim.tbl_filter(function(p)
    return p.state ~= 'loaded' and p.data.module ~= false and provides(p, mod)
  end, tops[mod:match('^[^.]+')] or {})
end

--- A dependency still in `registered` would fail `p` for the rest of the session.
---@param p cinch.Plugin
---@param seen? table<cinch.Plugin, true>
---@return cinch.Plugin?
local function unstarted_dep(p, seen)
  seen = seen or {}
  seen[p] = true
  for _, name in ipairs(p.deps) do
    local d = state.plugins[name]
    if d and not seen[d] then
      local found = d.state == 'registered' and d or unstarted_dep(d, seen)
      if found then
        return found
      end
    end
  end
end

--- Why `p` cannot load right now, or nil when it can.
---@param p cinch.Plugin
---@return string?
local function refusal(p)
  if p.state == 'disabled' then
    return 'is disabled'
  elseif p.state == 'failed' then
    return p.failed_in == 'load' and ('failed to load: %s'):format(p.err) or 'is not installed'
  elseif not on_disk(p) then
    return 'is not installed'
  elseif p.state == 'registered' then
    return 'has not started yet'
  elseif p.state == 'loading' then
    return 'is still loading'
  end
  local b = loader.building(p)
  if b then
    return b == p and 'is still building' or ('needs `%s`, which is still building'):format(b.name)
  end
  local dep = unstarted_dep(p, nil)
  if dep then
    return ('needs `%s`, which has not started yet'):format(dep.name)
  end
  if vim.in_fast_event() then
    return 'cannot load in a fast event'
  end
end

---@param p cinch.Plugin
---@param mod string
---@param why string
---@return string
local function not_loaded(p, mod, why)
  return ("\n\tcinch: `%s` provides '%s' but %s"):format(p.name, mod, why)
end

--- The first pending provider in declaration order, warning when others could also serve.
---@param found cinch.Plugin[]
---@param mod string
---@return cinch.Plugin
local function pick(found, mod)
  local pending = vim.tbl_filter(function(p)
    return p.state == 'pending'
  end, found)
  if #pending > 1 and not warned[mod] then
    warned[mod] = true
    local names = vim.tbl_map(function(p)
      return '`' .. p.name .. '`'
    end, pending)
    events.report(
      ("'%s' is in %s; loading the first declared"):format(mod, table.concat(names, ' and ')),
      vim.log.levels.WARN
    )
  end
  return pending[1] or found[1]
end

---@param mod string
---@return function|string|nil
local function search(mod)
  local found = providers(mod)
  if #found == 0 then
    return nil
  end
  local p = pick(found, mod)
  local why = refusal(p)
  if why then
    return not_loaded(p, mod, why)
  end
  local loaded, cancelled = loader.load(p, 'require ' .. mod)
  if not loaded then
    return not_loaded(
      p,
      mod,
      cancelled and ('its load was cancelled: %s'):format(cancelled) or refusal(p) or 'did not load'
    )
  end
  -- Captured now: require() puts a sentinel in package.loaded before it calls the loader.
  local value = package.loaded[mod]
  if value ~= nil then
    return function()
      return value
    end
  end
  for _, searcher in ipairs(package.loaders) do
    if searcher ~= search then
      local fn = searcher(mod)
      if type(fn) == 'function' then
        return fn
      end
    end
  end
  return not_loaded(p, mod, 'it loaded without that module')
end

local function forget()
  tops = nil
end

local subscribed = false

--- Add or remove the searcher.
---@param on boolean
function M.set(on)
  local at
  for i, searcher in ipairs(package.loaders) do
    if searcher == search then
      at = i
    end
  end
  if on and not at then
    table.insert(package.loaders, search)
  elseif at and not on then
    table.remove(package.loaders, at)
  end
  if on and not subscribed then
    subscribed = true
    events.on('Register', forget)
    events.on('Pack', forget)
    events.on('Build', forget)
  end
end

return M
