-- Update checks: which plugins have new commits, without changing anything on disk.
--   1. `git fetch` every plugin in parallel, in the background, with vim.pack's arguments
--   2. one offline vim.pack.get: vim.pack works out each plugin's target the way an update would
--   3. `git log` for each plugin that would move, also in parallel
-- Applying runs vim.pack.update offline, so it uses what the check fetched.

local events = require('cinch.events')
local pack = require('cinch.pack')
local state = require('cinch.state')

local levels = vim.log.levels
local uv = vim.uv

local M = {}

---@class cinch.updates.Opts
---@field fresh? integer seconds a check stays fresh: opening the UI checks again only after. Default 300
---@field every? integer|false seconds between background checks while Neovim runs, quiet unless
---something is pending. Default 86400 (a day), false: none

---@type cinch.updates.Opts
M.opts = { fresh = 300, every = 86400 }

---@class cinch.Update
---@field rev string checked-out commit
---@field rev_to string the commit an update moves to
---@field commits { hash: string, subject: string }[] what it brings, newest first

---@type table<string, cinch.Update> pending updates by plugin name
M.results = {}
---@type table<string, string> plugins whose fetch failed, with git's message
M.failed = {}
---@type integer? os.time() of the last finished check
M.checked_at = nil
M.checking = false

--- git, the way vim.pack runs it: no auto-gc messages, no GIT_DIR from outside.
---@param args string[]
---@param cwd string
---@param cb fun(r: vim.SystemCompleted)
local function git(args, cwd, cb)
  local env = vim.fn.environ()
  env.GIT_DIR, env.GIT_WORK_TREE, env.GIT_INDEX_FILE = nil, nil, nil
  local cmd = vim.list_extend({ 'git', '-c', 'gc.auto=0' }, args)
  vim.system(cmd, { cwd = cwd, text = true, env = env, clear_env = true }, function(r)
    vim.schedule(function()
      cb(r)
    end)
  end)
end

--- A callback that runs `fn` once it has been called `n` times.
---@param n integer
---@param fn fun()
---@return fun()
local function join(n, fn)
  if n == 0 then
    fn()
  end
  return function()
    n = n - 1
    if n == 0 then
      fn()
    end
  end
end

--- Whether the last check is recent enough to skip another.
---@return boolean
function M.fresh()
  return M.checked_at ~= nil and os.time() - M.checked_at < M.opts.fresh
end

---@param plugins cinch.Plugin[]
---@param results table<string, cinch.Update>
---@param opts { notify?: boolean, on_done?: fun(results: table<string, cinch.Update>) }
---@param failed? boolean the check could not read what was fetched: every earlier result stands
local function finish(plugins, results, opts, failed)
  for _, p in ipairs(plugins) do
    if p.activity == 'checking' then
      state.activity(p, nil)
    end
    -- A failed fetch learned nothing: what an earlier check found still stands.
    if not (failed or M.failed[p.name]) then
      M.results[p.name] = results[p.name]
    end
  end
  M.checked_at, M.checking = os.time(), false
  for name, err in pairs(M.failed) do
    events.report(('could not fetch `%s`: %s'):format(name, err), levels.WARN)
  end
  if opts.notify then
    local n = vim.tbl_count(M.results)
    events.report(n == 0 and 'everything is up to date' or ('%d update%s available'):format(n, n == 1 and '' or 's'))
  end
  events.emit('Updates', { results = M.results })
  if opts.on_done then
    opts.on_done(M.results)
  end
end

---@param plugins cinch.Plugin[]
---@param opts table
local function resolve(plugins, opts)
  local names = vim.tbl_map(function(p)
    return p.name
  end, plugins)
  local ok, data = pack.get(names, { offline = true })
  if not ok then
    events.report(('update check failed: %s'):format(data), levels.ERROR)
    return finish(plugins, {}, opts, true)
  end
  ---@cast data vim.pack.PlugData[]
  local moving = vim.tbl_filter(function(d)
    return d.rev and d.rev_to and d.rev ~= d.rev_to and not M.failed[d.spec.name]
  end, data)
  local results = {}
  local logged = join(#moving, function()
    finish(plugins, results, opts)
  end)
  for _, d in ipairs(moving) do
    -- Empty when the target is older, a pin moved back; it still counts as an update.
    git({ 'log', '--format=%h%x09%s', d.rev .. '..' .. d.rev_to }, d.path, function(r)
      local commits = {}
      for line in (r.stdout or ''):gmatch('[^\n]+') do
        local hash, subject = line:match('^(%S+)\t(.*)$')
        if hash then
          commits[#commits + 1] = { hash = hash, subject = subject }
        end
      end
      results[d.spec.name] = { rev = d.rev, rev_to = d.rev_to, commits = commits }
      logged()
    end)
  end
end

--- Check plugins for updates, in the background.
---@param names? string[] default: every plugin on disk
---@param opts? { notify?: boolean, on_done?: fun(results: table<string, cinch.Update>) }
function M.check(names, opts)
  opts = opts or {}
  if M.checking then
    return opts.notify and events.report('an update check is already running')
  end
  local plugins = vim.tbl_filter(function(p)
    return p.path ~= nil and (not names or vim.list_contains(names, p.name))
  end, state.list)
  M.checking, M.failed = true, {}
  local fetched = join(#plugins, function()
    resolve(plugins, opts)
  end)
  for _, p in ipairs(plugins) do
    -- A plugin already busy, building say, keeps showing that.
    if p.activity == nil then
      state.activity(p, 'checking')
    end
    -- vim.pack's own fetch: tags too, and conflicting tags follow the remote.
    git({ 'fetch', '--quiet', '--tags', '--force', '--recurse-submodules=yes', 'origin' }, p.path, function(r)
      if r.code ~= 0 then
        M.failed[p.name] = vim.trim(r.stderr or ('exit ' .. r.code))
      end
      fetched()
    end)
  end
end

---@type string[]? loaded plugins updated during the current apply()
local restart

--- Apply pending updates, offline: the commits the last check fetched.
---@param names? string[] default: every plugin with a pending update
function M.apply(names)
  names = names or vim.tbl_keys(M.results)
  if #names == 0 then
    return events.report('nothing to update')
  end
  table.sort(names)
  restart = {}
  local ok, err = pack.update(names, { force = true, offline = true })
  if not ok then
    events.report(('update failed: %s'):format(err), levels.ERROR)
  end
  if #restart > 0 then
    events.report(('restart Neovim to run the new code of %s'):format(table.concat(restart, ', ')))
  end
  restart = nil
end

---@return string[]
local function names()
  return vim.tbl_map(function(p)
    return p.name
  end, state.list)
end

-- `:Cinch check [names]`, found by command.lua.
M.commands = {
  check = {
    run = function(args)
      M.check(#args > 0 and args or nil, { notify = true })
    end,
    complete = names,
  },
}

---@type uv.uv_timer_t? the background check timer, while `every` is set
M.timer = nil

--- Check every `every` seconds, in the background. Quiet unless updates are pending;
--- a tick that finds a check running or vim.pack busy waits for the next one.
local function schedule()
  local every = M.opts.every
  if not every or every <= 0 then
    return
  end
  M.timer = uv.new_timer()
  M.timer:start(
    every * 1000,
    every * 1000,
    vim.schedule_wrap(function()
      if M.checking or not pack.idle() then
        return
      end
      M.check(nil, {
        on_done = function(results)
          local n = vim.tbl_count(results)
          if n > 0 then
            events.report(('%d update%s available · `:Cinch check` lists them'):format(n, n == 1 and '' or 's'))
          end
        end,
      })
    end)
  )
  -- Only while Neovim runs: a pending timer must not keep it open.
  M.timer:unref()
end

---@param opts? cinch.updates.Opts
function M.setup(opts)
  M.opts = vim.tbl_extend('force', M.opts, opts or {})
  events.define('Updates') -- { results }: a check finished
  -- An update that landed is no longer pending, whoever applied it.
  events.on('Pack', function(d)
    if d.kind ~= 'install' and M.results[d.name] then
      M.results[d.name] = nil
      if restart and d.plugin and d.plugin.state == 'loaded' then
        restart[#restart + 1] = d.name
      end
      events.emit('Updates', { results = M.results })
    end
  end)
  schedule()
end

return M
