-- The user command's name. plugin/cinch.lua and setup() can run in either order; this keeps one command.

local M = {}

M.default = 'Cinch'

---@type string? the command that exists, once one does
local current

--- The command as messages should name it: `:Cinch update`.
---@param sub? string
---@return string
function M.text(sub)
  return ('`:%s%s`'):format(current or M.default, sub and (' ' .. sub) or '')
end

---@param name string
---@return boolean ok, string? why
function M.check(name)
  if type(name) ~= 'string' or not name:find('^%u%w*$') then
    return false, 'a user command starts with a capital and has only letters and digits'
  end
  if name ~= current and vim.api.nvim_get_commands({})[name] then
    return false, 'that command already exists'
  end
  return true
end

--- Create the command under `name`, removing the one made before it.
---@param name string
function M.define(name)
  if name == current then
    return
  end
  if current then
    pcall(vim.api.nvim_del_user_command, current)
  end
  current = name
  vim.api.nvim_create_user_command(name, function(a)
    require('cinch.command').run(a.fargs, a.bang)
  end, {
    nargs = '*',
    bang = true,
    desc = 'cinch: plugins',
    complete = function(lead, line)
      return require('cinch.command').complete(lead, line)
    end,
  })
end

--- The default, unless setup() has already named one.
function M.define_default()
  if not current then
    M.define(M.default)
  end
end

return M
