-- Specs: find them, normalize them, and turn them into plugin records.
-- A spec is a vim.pack.Spec. Every cinch field lives in `data`, so any spec can
-- go to vim.pack.add unchanged. Fields written at the top level, lazy.nvim
-- style, are moved into `data`; when both set one, `data` wins.

local events = require('cinch.events')
local state = require('cinch.state')

local M = {}

---@class cinch.Key: vim.keymap.set.Opts
---@field [1] string lhs
---@field [2]? string|function rhs; omitted when the plugin maps lhs itself
---@field mode? string|string[] default 'n'

---@class cinch.Data
---@field enabled? boolean|fun(p: cinch.Plugin): boolean false: not installed, never loaded
---@field cond? boolean|fun(p: cinch.Plugin): boolean same as enabled; both exist for lazy.nvim specs
---@field load? cinch.Load default: 'trigger' with a trigger, else 'later'
---@field deps? (string|cinch.Spec)[] a name like 'plenary.nvim' refers to another spec
---@field event? string|string[] "Event" or "Event pattern"; 'VeryLazy' means load = 'later'
---@field ft? string|string[]
---@field cmd? string|string[]
---@field keys? string|(string|cinch.Key)[]
---@field init? fun(p: cinch.Plugin) every startup, before the plugin loads
---@field build? string|fun(p: cinch.Plugin, done?: fun(ok: boolean, msg?: string)) after install and update
---@field opts? table|fun(p: cinch.Plugin, opts: table): table?
---@field main? string module whose setup() gets opts; guessed from the name
---@field config? true|fun(p: cinch.Plugin, opts: table) replaces the default setup(opts) call
---@field after? fun(p: cinch.Plugin) after the plugin loaded and its config ran

---A vim.pack.Spec, with `[1]` in place of `src` and cinch fields at the top level if you like.
---@class cinch.Spec: vim.pack.Spec, cinch.Data
---@field [1]? string `owner/repo` or any src
---@field dependencies? (string|cinch.Spec)[] alias for deps
---@field commit? string becomes version
---@field tag? string becomes version
---@field branch? string becomes version

---@alias cinch.Origin { file: string, index?: integer }

---@class cinch.Entry
---@field spec string|cinch.Spec
---@field origin cinch.Origin

local pack_fields = { src = true, name = true, version = true, data = true }

-- Fields cinch reads from `data`. Trigger fields are also in `triggers`.
---@type table<string, true>
M.fields = {
  enabled = true,
  cond = true,
  load = true,
  deps = true,
  init = true,
  build = true,
  opts = true,
  main = true,
  config = true,
  after = true,
}
---@type table<string, true>
M.triggers = { event = true, ft = true, cmd = true, keys = true }
for k in pairs(M.triggers) do
  M.fields[k] = true
end

local aliases = { dependencies = 'deps' }
-- sarcina's order: commit beats tag beats version beats branch.
local pins = { 'commit', 'tag', 'version', 'branch' }
local loads = { now = true, later = true, now_if_args = true, trigger = true }

--- Make a custom trigger field known. handler.lua calls this for every handler it registers.
---@param name string
function M.field(name)
  M.fields[name], M.triggers[name] = true, true
end

--- `owner/repo` becomes a GitHub URL; anything else is a src as-is.
---@param src string
---@return string
local function expand(src)
  if src:find('^[%w_.-]+/[%w_.-]+$') then
    return 'https://github.com/' .. src
  end
  return src
end

--- `commit`, `tag` and `branch` become `version`, the one field vim.pack reads.
---@param s table
---@param notes string[]
local function resolve_version(s, notes)
  local won
  for _, k in ipairs(pins) do
    if s[k] ~= nil then
      if won then
        notes[#notes + 1] = ('sets `%s` and `%s`; using `%s`'):format(won, k, won)
      else
        won = k
      end
    end
  end
  if won then
    s.version = s[won]
  end
  s.commit, s.tag, s.branch = nil, nil, nil
  -- vim.pack reads a string as a branch, tag or commit, never as a range. Git refs
  -- cannot hold * ^ ~ or spaces, so a string with them can only be a range by mistake.
  local v = s.version
  if type(v) == 'string' and (v:find('[%*%^~%s<>=]') or v:find('%d%.[xX]')) then
    local msg = 'version `%s` looks like a range, which vim.pack reads as a branch or tag; '
      .. "write vim.version.range('%s')"
    notes[#notes + 1] = msg:format(v, v)
  end
end

---@param t table
---@return table
local function shallow(t)
  local c = {}
  for k, v in pairs(t) do
    c[k] = v
  end
  return c
end

--- Move cinch fields from the top level into `data`.
---@param s table
---@return string[] notes about ignored keys
local function hoist(s)
  local data, notes = s.data or {}, {}
  s.data = data
  resolve_version(s, notes)
  local unknown = {}
  for k, v in pairs(s) do
    if type(k) == 'string' and not pack_fields[k] then
      local field = aliases[k] or k
      if M.fields[field] then
        if data[field] == nil then
          data[field] = v
        end
        s[k] = nil
      else
        unknown[#unknown + 1] = k
      end
    end
  end
  if data.deps == nil and data.dependencies ~= nil then
    data.deps, data.dependencies = data.dependencies, nil
  end
  table.sort(unknown)
  for _, k in ipairs(unknown) do
    notes[#notes + 1] = ('has unknown field `%s`; it is ignored'):format(k)
  end
  return notes
end

--- A spec table with `src` and every cinch field in `data`, or nil without a src.
---@param s any
---@return vim.pack.Spec? spec
---@return string[]? notes
function M.normalize(s)
  if type(s) == 'string' then
    return { src = expand(s), data = {} }, {}
  end
  if type(s) ~= 'table' then
    return
  end
  -- A copy, and of its data, so your own tables stay as you wrote them: a spec
  -- table you share, or read again later, is not rearranged.
  s = shallow(s)
  if type(s.data) == 'table' then
    s.data = shallow(s.data)
  end
  if s.src == nil and type(s[1]) == 'string' then
    s.src, s[1] = expand(s[1]), nil
  end
  if type(s.src) == 'string' and s.src ~= '' then
    return s, hoist(s)
  end
end

--- The plugin name exactly as vim.pack derives it.
---@param spec vim.pack.Spec
---@return string
function M.name(spec)
  return (spec.name or spec.src:gsub('%.git$', '')):match('[^/]+$') or ''
end

---@param data cinch.Data
---@return boolean
local function has_trigger(data)
  for k in pairs(M.triggers) do
    local v = data[k]
    -- `keys = false`, as lazy.nvim configs write it, turns a trigger off.
    if v ~= nil and v ~= false and not (type(v) == 'table' and #v == 0) then
      return true
    end
  end
  return false
end

--- Work out `load` from the spec, and `when`, what it means this session.
---@param data cinch.Data
---@param dep_only boolean
---@param notes string[]
---@return cinch.Load load, cinch.When when
local function resolve_load(data, dep_only, notes)
  -- lazy.nvim's VeryLazy is the moment after startup, which is what `later` is.
  -- Dropping it leaves no trigger, so the default below makes it `later`.
  if data.event == 'VeryLazy' then
    data.event = nil
  elseif type(data.event) == 'table' then
    data.event = vim.tbl_filter(function(e)
      return e ~= 'VeryLazy'
    end, data.event --[[@as string[] ]])
  end
  local triggered = has_trigger(data)
  local load = data.load
  if load ~= nil and not loads[load] then
    notes[#notes + 1] = ('has unknown load `%s`; using the default'):format(tostring(load))
    load = nil
  end
  if load == nil then
    if triggered then
      load = 'trigger'
    elseif dep_only then
      -- A library seen only as a dependency loads when the plugin needing it does.
      load = 'trigger'
    else
      load = 'later'
    end
  elseif load ~= 'trigger' and triggered then
    notes[#notes + 1] = ('sets load = `%s`, so its triggers are ignored'):format(load)
  end
  local when = load
  if load == 'now_if_args' then
    when = vim.fn.argc(-1) > 0 and 'now' or 'later'
  end
  return load, when --[[@as cinch.When]]
end

---@param p table
---@param spec vim.pack.Spec
---@param origin cinch.Origin
---@param dep_only boolean
---@param notes string[]
local function fill(p, spec, origin, dep_only, notes)
  p.spec, p.data, p.origin = spec, spec.data, origin
  p.src, p.version = spec.src, spec.version
  p.dep_only = dep_only or nil
  p.load, p.when = resolve_load(spec.data, dep_only, notes)
end

---@param name string
---@param origin cinch.Origin
---@param notes string[]
local function report(name, origin, notes)
  for _, note in ipairs(notes) do
    events.report(('%s: `%s` %s'):format(origin.file, name, note), vim.log.levels.WARN)
  end
end

--- A dependency written as a bare name refers to another spec; anything else is a spec.
---@param d any
---@return boolean
local function is_ref(d)
  return type(d) == 'string' and not d:find('/') and not d:find(':')
end

---@param e cinch.Entry
---@param dep_of? string
---@param added cinch.Plugin[]
---@return cinch.Plugin?
local function make(e, dep_of, added)
  local spec, notes = M.normalize(e.spec)
  if not spec then
    events.report(('%s: a spec without `src`'):format(e.origin.file), vim.log.levels.ERROR)
    return
  end
  ---@cast notes string[]
  local name = M.name(spec)
  if name == '' then
    events.report(('%s: no plugin name in `%s`'):format(e.origin.file, spec.src), vim.log.levels.ERROR)
    return
  end

  -- Deps first, so they come before their dependents in the list and in vim.pack.add.
  local deps = {}
  for _, d in ipairs(spec.data.deps or {}) do
    if is_ref(d) then
      deps[#deps + 1] = d
    else
      local dp = make({ spec = d, origin = e.origin }, name, added)
      if dp then
        deps[#deps + 1] = dp.name
      end
    end
  end

  local p = state.plugins[name]
  if p then
    if dep_of then
      return p
    end
    if p.dep_only and p.state == 'registered' then
      fill(p, spec, e.origin, false, notes)
      p.deps = deps
      report(name, e.origin, notes)
    elseif p.dep_only then
      events.report(('`%s` already set up as a dependency; its own spec applies on restart'):format(name))
    else
      events.report(
        ('%s: `%s` declared twice; keeping the one in %s'):format(e.origin.file, name, p.origin.file),
        vim.log.levels.WARN
      )
    end
    return p
  end

  -- fill() and state.add() set the rest.
  ---@diagnostic disable-next-line: missing-fields
  p = { name = name, deps = deps }
  fill(p, spec, e.origin, dep_of ~= nil, notes)
  report(name, e.origin, notes)
  state.add(p --[[@as cinch.Plugin]])
  added[#added + 1] = p
  return p
end

--- Turn entries into plugin records. Names already registered are not returned.
---@param entries cinch.Entry[]
---@return cinch.Plugin[] added in declaration order, deps before dependents
function M.register(entries)
  local added = {}
  for _, e in ipairs(entries) do
    make(e, nil, added)
  end
  -- Bare-name deps can point at a spec declared later, so they are checked last.
  for _, p in ipairs(added) do
    for i = #p.deps, 1, -1 do
      if not state.plugins[p.deps[i]] then
        events.report(('`%s` depends on `%s`, which no spec declares'):format(p.name, p.deps[i]), vim.log.levels.WARN)
        table.remove(p.deps, i)
      end
    end
  end
  return added
end

-- Discovery ------------------------------------------------------------------

---@param value any
---@return boolean
local function is_single(value)
  return type(value) == 'string' or value.src ~= nil or (type(value[1]) == 'string' and value[2] == nil)
end

---@param out cinch.Entry[]
---@param value any a spec, a list of specs, or a src string
---@param origin cinch.Origin
local function push(out, value, origin)
  if type(value) ~= 'table' and type(value) ~= 'string' then
    error(('%s: expected a spec or a list of specs'):format(origin.file), 0)
  end
  if is_single(value) then
    out[#out + 1] = { spec = value, origin = origin }
    return
  end
  for i, s in ipairs(value) do
    out[#out + 1] = { spec = s, origin = { file = origin.file, index = i } }
  end
end

--- Spec files under a root, sorted: a module path like 'plugins' or a directory.
---@param root string
---@return string[]
local function files(root)
  local res
  if root:find('^[/~.]') then
    res = vim.fn.globpath(vim.fs.normalize(root), '**/*.lua', true, true)
  else
    local path = root:gsub('%.', '/')
    res = vim.api.nvim_get_runtime_file(('lua/%s.lua'):format(path), true)
    vim.list_extend(res, vim.api.nvim_get_runtime_file(('lua/%s/**/*.lua'):format(path), true))
  end
  table.sort(res)
  return res
end

--- Read every spec under `roots`. A table root is a spec or a list of them, taken as-is.
---@param roots (string|table)[]
---@param origin cinch.Origin where inline tables come from
---@return cinch.Entry[]
function M.collect(roots, origin)
  local out = {}
  for _, root in ipairs(roots) do
    if type(root) == 'table' then
      push(out, root, origin)
    else
      for _, file in ipairs(files(root)) do
        -- loadfile, not require: vim.loader caches it, and package.loaded never holds
        -- a stale copy when the specs are read again.
        local chunk, err = loadfile(file)
        local ok, res = chunk ~= nil, err
        if chunk then
          ok, res = pcall(chunk)
        end
        if ok then
          ok, res = pcall(push, out, res, { file = file })
        end
        if not ok then
          events.report(tostring(res), vim.log.levels.ERROR)
        end
      end
    end
  end
  return out
end

return M
