-- How far git has got with a plugin, from what it prints with --progress: the percent
-- and meter on the plugin's row while it installs, is checked or updates. vim.pack runs
-- git quietly, so while it installs or updates, watch() gives its clone and checkout
-- --progress, and keeps those lines from vim.pack, which would warn with them. A check
-- runs its own fetch, through reader().

local state = require('cinch.state')

local M = {}

-- Each phase git reports, and the share of a plugin's work it spans: the remote's
-- counting and compressing, the download, then the checkout.
local phases = {
  ['Counting objects'] = { 0, 5 },
  ['Compressing objects'] = { 5, 15 },
  ['Receiving objects'] = { 15, 80 },
  ['Resolving deltas'] = { 80, 95 },
  ['Updating files'] = { 95, 100 },
}

-- Disk work whose row shows how far it is.
M.metered = { installing = true, checking = true, updating = true }

--- One record git printed, as the share of the plugin's work it says is done.
---@param record string
---@return integer? nil: not a phase it reports
function M.percent(record)
  local phase, n = (record:gsub('^remote: ', '')):match('^(%a[%a ]*): +(%d+)%%')
  local span = phases[phase]
  return span and math.floor(span[1] + (span[2] - span[1]) * tonumber(n) / 100)
end

--- Whether a record is git telling how it goes, which --quiet would have kept back.
---@param record string
---@return boolean
local function chatter(record)
  local r = record:gsub('^remote: ', '')
  return r:match('^%a[%a ]*: +%d+%%') ~= nil
    or r:match('^%a[%a ]*: +%d+, done%.') ~= nil
    or r:match('^Total %d+') ~= nil
    or r:match('^Cloning into ') ~= nil
    -- A fetch's refs: `From <url>`, then ` * [new tag]  v1 -> v1` or `   a..b  main -> origin/main`.
    or r:match('^From ') ~= nil
    or r:match('^ .* %-> ') ~= nil
    or r:match('^Fetching submodule ') ~= nil
    or vim.trim(r) == ''
end

--- Move `p`'s percent on to `n`: only forward, and only while it does disk work.
---@param p cinch.Plugin
---@param n integer
function M.set(p, n)
  if M.metered[p.activity] then
    p.percent = math.max(p.percent or 0, n)
  end
end

--- A stderr handler for git run with --progress on `p`: moves its percent as git
--- reports, and keeps everything else git said.
---@param p cinch.Plugin
---@return fun(err?: string, data?: string) handler
---@return fun(): string said what is left of stderr, as --quiet would have printed it
function M.reader(p)
  local carry, kept = '', {}
  local function take(record)
    local n = M.percent(record)
    if n then
      M.set(p, n)
    elseif not chatter(record) then
      kept[#kept + 1] = (record:gsub('%s+$', ''))
    end
  end
  local function handler(_, data)
    local text = carry .. (data or '')
    local last = 0
    for record, at in text:gmatch('([^\r\n]*)[\r\n]()') do
      take(record)
      last = at
    end
    carry = text:sub(last)
    if not data and carry ~= '' then
      take(carry)
      carry = ''
    end
  end
  return handler, function()
    return #kept > 0 and (table.concat(kept, '\n') .. '\n') or ''
  end
end

--- What vim.pack runs, made to report: the plugin it is for and the command with
--- --progress. A clone also loses --quiet, which hides the download; a checkout keeps
--- it, which hides git's advice.
---@param cmd string[]
---@param opts? table
---@return cinch.Plugin? p
---@return string[]? cmd
---@return string? sub clone or checkout
local function reporting(cmd, opts)
  if type(cmd) ~= 'table' or cmd[1] ~= 'git' then
    return
  end
  local i = 2
  while cmd[i] and vim.startswith(cmd[i], '-') do
    i = i + (cmd[i] == '-c' and 2 or 1)
  end
  local sub = cmd[i]
  local path = sub == 'clone' and cmd[#cmd] or sub == 'checkout' and opts and opts.cwd
  local p = path and state.plugins[vim.fs.basename(path)]
  if not p then
    return
  end
  local out = vim.list_slice(cmd)
  for j = i + 1, #out do
    if sub == 'clone' and out[j] == '--quiet' then
      out[j] = '--progress'
      return p, out, sub
    end
  end
  table.insert(out, i + 1, '--progress')
  return p, out, sub
end

--- While vim.pack installs or updates: each clone and checkout it runs reports how far
--- it is on its plugin's row. A checkout that ends well is that plugin's last step.
---@return fun() restore
function M.watch()
  local system = vim.system
  local function wrapped(cmd, opts, on_exit)
    local p, args, sub = reporting(cmd, opts)
    if not (p and args and on_exit) then
      return system(cmd, opts, on_exit)
    end
    local handler, said = M.reader(p)
    local o = vim.tbl_extend('force', opts or {}, { stderr = handler })
    return system(args, o, function(out)
      out.stderr = said()
      if out.code == 0 and sub == 'checkout' then
        M.set(p, 100)
      end
      on_exit(out)
    end)
  end
  vim.system = wrapped
  return function()
    if vim.system == wrapped then
      vim.system = system
    end
  end
end

return M
