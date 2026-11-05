-- :checkhealth cinch. Reads what cinch knows about Neovim, git, the lockfile, the
-- plugins, the features and the timing; changes nothing.

local h = vim.health

local M = {}

--- git, which vim.pack clones and updates plugins with.
local function git()
  if vim.fn.executable('git') ~= 1 then
    return h.error('git is not on PATH: vim.pack clones and updates plugins with it')
  end
  local r = vim.system({ 'git', '--version' }, { text = true }):wait()
  h.ok(vim.trim(r.stdout or 'git'))
end

--- The lockfile vim.pack keeps: readable, and written at the first install.
local function lockfile()
  local path = vim.go.packlockfile
  local f = io.open(path)
  if not f then
    return h.info('no lockfile yet: vim.pack writes one at the first install')
  end
  local text = f:read('*a')
  f:close()
  if pcall(vim.json.decode, text) then
    h.ok('lockfile is readable: ' .. path)
  else
    h.error('lockfile is not valid JSON: ' .. path)
  end
end

--- The plugins: how many, in which states, and the ones that need attention.
---@param pack table cinch.pack
---@param state table cinch.state
local function plugins(pack, state)
  local yours = state.yours()
  local by = {}
  for _, p in ipairs(yours) do
    by[p.state] = (by[p.state] or 0) + 1
  end
  local parts = {}
  for s in vim.spairs(by) do
    parts[#parts + 1] = by[s] .. ' ' .. s
  end
  h.info(('%d plugin%s: %s'):format(#yours, #yours == 1 and '' or 's', table.concat(parts, ', ')))
  for _, p in ipairs(yours) do
    if p.state == 'failed' then
      h.error(('`%s` failed to load: %s'):format(p.name, vim.split(p.err or '?', '\n')[1]))
    end
  end
  local missing = pack.locked_missing()
  if #missing > 0 then
    h.warn(('in the lockfile, not on disk: %s; the next start installs them'):format(table.concat(missing, ', ')))
  end
  local orphans = vim.tbl_map(function(o)
    return o.name
  end, pack.orphans())
  if #orphans > 0 then
    h.warn(('on disk, in no spec: %s; `:Cinch clean` deletes them'):format(table.concat(orphans, ', ')))
  end
end

--- Each feature setup() asked for: loaded, or not.
---@param cinch table the cinch module
local function features(cinch)
  for _, name in ipairs(cinch.opts.features) do
    if package.loaded['cinch.features.' .. name] then
      h.ok(('feature `%s` is loaded'):format(name))
    else
      h.info(('feature `%s` is not loaded'):format(name))
    end
  end
end

--- Where the startup time comes from, and how often updates are checked.
local function timing()
  local stats = package.loaded['cinch.features.stats']
  if stats then
    if stats.source == 'os' then
      h.ok('startup is timed from when the process began')
    else
      h.warn('startup is timed from CPU time: the OS gave no start time, so it reads a few ms late')
    end
  end
  local updates = package.loaded['cinch.features.updates']
  if updates then
    local every = updates.opts.every
    if every then
      h.ok(('checks for updates every %d seconds'):format(every))
    else
      h.info('background update checks are off')
    end
  end
end

function M.check()
  h.start('cinch')
  local v = vim.version()
  if vim.pack then
    h.ok(('vim.pack is there, Neovim %d.%d.%d'):format(v.major, v.minor, v.patch))
  else
    h.error('vim.pack is missing: cinch wraps it, so it needs a Neovim that has it')
  end
  git()
  if vim.fn.has('win32') == 0 and vim.fn.executable('sh') == 0 then
    h.warn('sh is not on PATH: shell builds, such as `build = "make"`, will fail')
  end
  local cinch = require('cinch')
  if not cinch.opts then
    return h.warn('setup() has not run in this session, so nothing is registered')
  end
  h.ok('setup() ran')
  lockfile()

  h.start('cinch: plugins')
  plugins(require('cinch.pack'), require('cinch.state'))

  h.start('cinch: features')
  features(cinch)

  h.start('cinch: timing and updates')
  timing()
end

return M
