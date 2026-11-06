-- Event bus. Core modules announce what happened; features and user code listen.
-- Subscribers run in priority order and may change the payload. An event that
-- allows it is cancelled by setting `data.cancel = true`.

local M = {}

---@class cinch.Sub
---@field fn fun(data: table, name: string)
---@field priority integer lower runs first
---@field once? boolean
---@field dead? boolean unsubscribed; skipped by a dispatch already walking its list
---@field off? fun() set right after the record is made

-- Every event cinch emits, with its payload. Subscribing to a name not listed
-- here warns, so a typo never fails silently. Features add theirs with `define()`.
---@type table<string, true>
M.names = {
  Register = true, -- { plugin }                        a spec became a plugin record
  State = true, -- { plugin, from, to, reason }         every state change
  Activity = true, -- { plugin, from, to }              disk work on a plugin started or ended
  LoadWait = true, -- { plugin, reason, build }          waits for a build to end: its own or a dep's
  LoadPre = true, -- { plugin, reason }                 set cancel = true and cancel_reason to stop it
  Load = true, -- { plugin, reason, ms }                ms = { packadd, config }
  Step = true, -- { plugin, name, start, ms, ok }       one part of a load: init, packadd, opts, config, after;
  --                                                    start is its hrtime()
  LoadError = true, -- { plugin, reason, err }
  PackPre = true, -- { kind, name, plugin?, spec, path } from PackChangedPre, after state is updated
  Pack = true, -- { kind, name, plugin?, spec, path }   from PackChanged, after state is updated
  PackOpPre = true, -- { op, names }                    before cinch calls vim.pack.<op>
  PackOp = true, -- { op, names, ok, ms, err? }         after it returns
  Build = true, -- { plugin, ok, ms, err?, output? }
  BuildOutput = true, -- { plugin, lines }               new output from a running shell build
  Phase = true, -- { name, ms, start }                  a startup step finished; start is its hrtime()
  Later = true, -- {}                                   the later queue is drained
  Done = true, -- {}                                    setup() is done: specs read, now plugins loaded;
  --                                                    with plugins missing, after their install on UIEnter
  Run = true, -- { when, where, ok, ms, err? }         one of your cinch.now/later functions ran
  Time = true, -- { name, start, ms, ok, err? }         a function wrapped with cinch.time() returned;
  --                                                    start is its hrtime()
  Installing = true, -- { names }                       a batch of installs starts
  Installed = true, -- { names, failed, ms }            and ended; failed lists names not on disk
  Report = true, -- { msg, level }                      cinch has something to tell the user
}

-- Mirrored as `User Cinch<Name>` for config code that prefers autocmds.
-- Disk events stay off this list: PackChanged already carries more.
M.public = { Load = true, LoadError = true, Later = true, Done = true }

---@type table<string, cinch.Sub[]>
local subs = {}

--- Declare an event a feature emits.
---@param name string
function M.define(name)
  M.names[name] = true
end

--- Subscribe to an event, or '*' for every event.
---@param name string
---@param fn fun(data: table, name: string)
---@param opts? { priority?: integer, once?: boolean } priority: lower runs first, default 50
---@return fun() unsubscribe
function M.on(name, fn, opts)
  if name ~= '*' and not M.names[name] then
    M.report(('unknown event `%s`'):format(name), vim.log.levels.WARN)
  end
  opts = opts or {}
  local sub = { fn = fn, priority = opts.priority or 50, once = opts.once } --[[@as cinch.Sub]]
  -- Lists are replaced, never changed in place, so a dispatch in progress can
  -- walk its list without copying it first.
  sub.off = function()
    sub.dead = true
    subs[name] = vim.tbl_filter(function(s)
      return s ~= sub
    end, subs[name] or {})
  end
  local list = vim.list_slice(subs[name] or {})
  -- Stable insert: equal priorities keep registration order.
  local i = #list + 1
  while i > 1 and list[i - 1].priority > sub.priority do
    i = i - 1
  end
  table.insert(list, i, sub)
  subs[name] = list
  return sub.off
end

---@param list? cinch.Sub[]
---@param name string
---@param data table
local function dispatch(list, name, data)
  if not list then
    return
  end
  for _, sub in ipairs(list) do
    if not sub.dead then
      if sub.once then
        sub.off()
      end
      local ok, err = xpcall(sub.fn, debug.traceback, data, name)
      if not ok then
        local msg = ('%s handler failed:\n%s'):format(name, err)
        -- A failing Report handler must not report through itself.
        if name == 'Report' then
          vim.notify('cinch: ' .. msg, vim.log.levels.ERROR)
        else
          M.report(msg, vim.log.levels.ERROR)
        end
      end
    end
  end
end

--- Run the subscribers of `name`, then the '*' ones.
---@param name string
---@param data? table
---@return table data the payload, as the subscribers left it
function M.emit(name, data)
  data = data or {}
  dispatch(subs[name], name, data)
  dispatch(subs['*'], name, data)
  if M.public[name] then
    local p = data.plugin
    vim.api.nvim_exec_autocmds('User', {
      pattern = 'Cinch' .. name,
      modeline = false,
      data = { name = p and p.name, reason = data.reason, err = data.err and tostring(data.err) },
    })
  end
  return data
end

--- Whether anything listens to `name`. Emitters check this before building a payload.
---@param name string
---@return boolean
function M.has(name)
  local a, b = subs[name], subs['*']
  return (a ~= nil and #a > 0) or (b ~= nil and #b > 0)
end

--- Tell the user something. The message feature takes this over by subscribing
--- to Report; with no subscriber it falls back to vim.notify.
---@param msg string
---@param level? integer vim.log.levels, default INFO
function M.report(msg, level)
  level = level or vim.log.levels.INFO
  local list = subs.Report
  if list and #list > 0 then
    M.emit('Report', { msg = msg, level = level })
  else
    vim.notify('cinch: ' .. msg, level)
  end
end

return M
