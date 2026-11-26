-- Extensions: plugins that add to cinch, loaded the way Telescope loads its own. One
-- ships lua/cinch/extensions/<name>.lua, which returns register({ setup, exports,
-- health }). setup() loads each one `extensions` names before it reads a spec, so an
-- extension can see every spec. One cinch knows the repo of is installed if missing.

local events = require('cinch.events')

local M = {}

---@class cinch.Extension
---@field setup? fun(opts: table, cinch_opts: cinch.Opts) called with `extensions.<name>`
---@field exports? table what `require('cinch').extensions.<name>` gives
---@field health? fun() run by :checkhealth cinch, with vim.health in scope

--- Extensions cinch installs by name when they are missing.
---@type table<string, string>
M.known = {
  groups = 'https://github.com/techdeus88/cinch-groups.nvim',
}

---@type table<string, cinch.Extension> loaded, by name
M.loaded = {}
---@type table<string, string> the repo each one was loaded from, by name
M.dirs = {}

--- What an extension's module returns.
---@param ext cinch.Extension
---@return cinch.Extension
function M.register(ext)
  vim.validate('ext', ext, 'table')
  vim.validate('ext.setup', ext.setup, 'function', true)
  vim.validate('ext.exports', ext.exports, 'table', true)
  vim.validate('ext.health', ext.health, 'function', true)
  return ext
end

---@param name string
---@return string? file
local function find(name)
  return vim.api.nvim_get_runtime_file(('lua/cinch/extensions/%s.lua'):format(name), false)[1]
end

---@param name string
---@param msg string
local function fail(name, msg)
  events.report(('extension `%s`: %s'):format(name, msg), vim.log.levels.ERROR)
end

--- Load one extension, installing it first when cinch knows its repo.
---@param name string
---@param opts table its options
---@param cinch_opts cinch.Opts
---@return cinch.Extension?
function M.load(name, opts, cinch_opts)
  if M.loaded[name] then
    return M.loaded[name]
  end
  if not find(name) then
    local src = M.known[name]
    if not src then
      return fail(name, 'not found, and cinch knows no repo to install it from')
    end
    -- You named it in `extensions`, which is the yes vim.pack would ask for.
    local ok, err = pcall(vim.pack.add, { src }, { confirm = false })
    if not ok or not find(name) then
      return fail(name, ('could not install it from %s: %s'):format(src, tostring(err or 'it has no module')))
    end
  end
  local ok, ext = pcall(require, 'cinch.extensions.' .. name)
  if not ok or type(ext) ~= 'table' then
    return fail(name, ok and 'its module returns no table' or tostring(ext))
  end
  if ext.setup then
    local ran, err = pcall(ext.setup, type(opts) == 'table' and opts or {}, cinch_opts)
    if not ran then
      return fail(name, tostring(err))
    end
  end
  M.loaded[name] = ext
  -- lua/cinch/extensions/<name>.lua, four levels under the repo.
  M.dirs[name] = vim.fn.fnamemodify(find(name) --[[@as string]], ':p:h:h:h:h')
  return ext
end

--- Load every extension `extensions` names, by name.
---@param exts table<string, table>
---@param cinch_opts cinch.Opts
function M.load_all(exts, cinch_opts)
  for name, opts in vim.spairs(exts) do
    if type(name) == 'string' then
      M.load(name, opts, cinch_opts)
    end
  end
end

return M
