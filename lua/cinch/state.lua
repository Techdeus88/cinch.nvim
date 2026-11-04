-- Plugin registry and session state. Each plugin has one `state`, changed only
-- through `set()` and a fixed table of allowed moves. Disk work is a separate
-- axis, `activity`, because a plugin can be loaded and updating at once.
-- What is on disk belongs to vim.pack and is read from it, never stored here.

local events = require('cinch.events')

local M = {}

---@alias cinch.State
---| 'registered' a record, not yet checked against the disk
---| 'disabled'   `enabled` or `cond` is false, or turned off this session
---| 'pending'    on disk, waiting for its moment: now, later or a trigger
---| 'loading'
---| 'loaded'
---| 'failed'     install or load failed; `failed_in` says which

---@alias cinch.Load 'now'|'later'|'now_if_args'|'trigger'
---@alias cinch.When 'now'|'later'|'trigger'
---@alias cinch.Activity 'installing'|'updating'|'deleting'|'building'|'checking'

---@class cinch.Plugin
---@field name string
---@field src string
---@field version? string|vim.VersionRange
---@field spec vim.pack.Spec as declared
---@field dep_only? boolean only seen as another plugin's dependency so far
---@field data cinch.Data normalized cinch fields, see spec.lua
---@field load cinch.Load as declared
---@field when cinch.When resolved at startup: now_if_args becomes now or later
---@field deps string[] names, loaded before this one
---@field triggers? table<string, any[]> handler name -> parsed values, see handler.lua
---@field armed? table<string, true> handlers set up and not yet removed
---@field origin? { file: string, index?: integer } where the spec was declared
---@field path? string set once vim.pack reports the plugin on disk
---@field rev? string checked-out commit, from vim.pack
---@field deleted? true deleted from disk this session; installs again on the next start
---@field self? true cinch itself, kept updated as one of its plugins
---@field state cinch.State
---@field activity? cinch.Activity
---@field build_log? string[] the last build's output, newest last; streams in while a shell build runs
---@field reason? string what loaded or disabled it: 'event BufReadPost', 'dep of x', 'cond'
---@field err? string
---@field failed_in? 'install'|'load'
---@field order? integer load sequence number
---@field opts_used? table the opts config or setup() received
---@field main_used? string the module whose setup() was called

---@type table<string, cinch.Plugin>
M.plugins = {}
---@type cinch.Plugin[] declaration order
M.list = {}

-- Every move a plugin may make. Anything else is a bug in cinch and raises.
---@type table<cinch.State, table<cinch.State, true>>
local allowed = {
  registered = { pending = true, disabled = true, failed = true },
  pending = { loading = true, disabled = true },
  loading = { loaded = true, failed = true },
  -- Lua modules cannot be unloaded, so a loaded plugin stays loaded.
  loaded = {},
  -- A failed install goes back through the disk check; a failed load retries.
  failed = { registered = true, pending = true },
  -- Turned on this session: checked against the disk like a new plugin.
  disabled = { registered = true },
}

--- Your plugins, in declaration order: every record but cinch itself, which the
--- update check and `:Cinch update` cover like a plugin but no list or count shows.
---@return cinch.Plugin[]
function M.yours()
  return vim.tbl_filter(function(p)
    return not p.self
  end, M.list)
end

--- Add a record to the registry. spec.lua dedupes first, so a name seen twice is a bug.
---@param p cinch.Plugin
---@return cinch.Plugin
function M.add(p)
  if M.plugins[p.name] then
    error(('cinch: %s registered twice'):format(p.name), 2)
  end
  p.state = 'registered'
  M.plugins[p.name] = p
  M.list[#M.list + 1] = p
  if events.has('Register') then
    events.emit('Register', { plugin = p })
  end
  return p
end

--- Whether `p` may move to `to` from where it is now.
---@param p cinch.Plugin
---@param to cinch.State
---@return boolean
function M.can(p, to)
  return allowed[p.state][to] == true
end

--- Move a plugin to another state.
---@param p cinch.Plugin
---@param to cinch.State
---@param reason? string
---@return boolean changed false when it was already there
function M.set(p, to, reason)
  local from = p.state
  if from == to then
    return false
  end
  if not allowed[from][to] then
    error(('cinch: %s cannot go from %s to %s'):format(p.name, from, to), 2)
  end
  p.state = to
  if reason then
    p.reason = reason
  end
  if to == 'failed' then
    p.failed_in = from == 'loading' and 'load' or 'install'
  end
  if events.has('State') then
    events.emit('State', { plugin = p, from = from, to = to, reason = reason })
  end
  return true
end

--- Mark the disk work happening to a plugin, or nil when it ends.
---@param p cinch.Plugin
---@param what? cinch.Activity
function M.activity(p, what)
  local from = p.activity
  if from == what then
    return
  end
  p.activity = what
  if events.has('Activity') then
    events.emit('Activity', { plugin = p, from = from, to = what })
  end
end

return M
