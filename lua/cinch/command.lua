-- :Cinch and its subcommands. Not part of the core: nothing here is needed to
-- install, load or update plugins, and this file loads only when :Cinch is used
-- or a feature adds a subcommand.

local cinch = require('cinch')
local events = require('cinch.events')
local state = require('cinch.state')

local M = {}

---@return string[]
local function names()
  return vim.tbl_map(function(p)
    return p.name
  end, state.list)
end

---@class cinch.Command
---@field run fun(args: string[], bang: boolean)
---@field complete? fun(): string[]

--- Subcommands by name. Features add theirs with register().
---@type table<string, cinch.Command>
M.commands = {
  load = {
    run = function(args)
      cinch.load(args)
    end,
    complete = names,
  },
  -- Plugins your specs list that are not on disk: all of them, or those named.
  install = {
    run = function(args)
      cinch.install(#args > 0 and args or nil)
    end,
    complete = function()
      return vim.tbl_map(
        function(p)
          return p.name
        end,
        vim.tbl_filter(function(p)
          return not p.path
        end, state.list)
      )
    end,
  },
  build = {
    run = function(args)
      cinch.build(args)
    end,
    complete = names,
  },
  update = {
    run = function(args, bang)
      cinch.update(#args > 0 and args or nil, { force = bang })
    end,
    complete = names,
  },
  -- Back to the revisions the lockfile records, after a checkout moved on its own.
  -- With !, without vim.pack's confirmation.
  restore = {
    run = function(args, bang)
      cinch.update(#args > 0 and args or nil, { force = bang, target = 'lockfile' })
    end,
    complete = names,
  },
  -- With !, also plugins your specs list; they install again on the next start.
  del = {
    run = function(args, bang)
      if #args == 0 then
        local usercmd = require('cinch.usercmd')
        events.report(
          ('which plugins? %s; %s deletes those no spec names'):format(
            usercmd.text('del {name}'),
            usercmd.text('clean')
          )
        )
        return
      end
      cinch.del(args, { force = bang })
    end,
    complete = function()
      return vim.list_extend(
        vim.tbl_map(function(o)
          return o.name
        end, require('cinch.pack').orphans()),
        names()
      )
    end,
  },
  -- Install what is missing, offer to delete what no spec names, check for updates.
  sync = {
    run = function()
      cinch.sync()
    end,
  },
  -- With !, without asking, and even when a spec file failed to load.
  clean = {
    run = function(_, bang)
      cinch.clean({ confirm = not bang, force = bang })
    end,
  },
}

---@param name string
---@param def cinch.Command
function M.register(name, def)
  M.commands[name] = def
end

--- Every subcommand: the registered ones, plus those of each loaded feature, which
--- exports `command` (under the feature's name) or `commands` (under their own).
--- Features never load this file to add one.
---@return table<string, cinch.Command>
local function all()
  local res = vim.tbl_extend('force', {}, M.commands)
  for mod, f in pairs(package.loaded) do
    local name = mod:match('^cinch%.features%.([%w_]+)$')
    if name and type(f) == 'table' then
      if type(f.command) == 'table' and not res[name] then
        res[name] = f.command
      end
      for sub, def in pairs(type(f.commands) == 'table' and f.commands or {}) do
        res[sub] = res[sub] or def
      end
    end
  end
  return res
end

--- Run `:Cinch[!] {sub}[!] {args}`. With no subcommand, `open` if a feature added one.
---@param args string[]
---@param bang boolean
function M.run(args, bang)
  local cmds = all()
  local sub = table.remove(args, 1) or (cmds.open and 'open')
  -- `:Cinch update!` reads better than `:Cinch! update`; both work.
  if sub and sub:sub(-1) == '!' then
    sub, bang = sub:sub(1, -2), true
  end
  local c = sub and cmds[sub]
  if not c then
    local subs = vim.tbl_keys(cmds)
    table.sort(subs)
    return events.report(('subcommands: %s'):format(table.concat(subs, ', ')), vim.log.levels.WARN)
  end
  c.run(args, bang)
end

---@param lead string
---@param line string
---@return string[]
function M.complete(lead, line)
  local words = vim.split(line, '%s+', { trimempty = true })
  local n = #words - (lead == '' and 0 or 1)
  local cmds = all()
  local list ---@type string[]
  if n <= 1 then
    list = vim.tbl_keys(cmds)
  else
    local c = cmds[(words[2]:gsub('!$', ''))]
    list = c and c.complete and c.complete() or {}
  end
  table.sort(list)
  return vim.tbl_filter(function(s)
    return vim.startswith(s, lead)
  end, list)
end

return M
