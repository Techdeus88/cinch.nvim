-- How an install, check, update or delete ends, in words: the same line in the window's
-- header and in your messages.

local M = {}

--- `1.2s`, or `350ms` under a second.
---@param ms number
---@return string
local function duration(ms)
  return ms >= 1000 and ('%.1fs'):format(ms / 1000) or ('%dms'):format(ms)
end
M.duration = duration

---@param n integer
---@param word string
---@return string
local function count(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

---@param d { failed?: string[] }
---@return string
local function failures(d)
  local n = #(d.failed or {})
  return n > 0 and (' · %d failed'):format(n) or ''
end

---@alias cinch.OpKind 'install'|'check'|'update'|'delete'

--- The line that ends an operation.
---@param kind cinch.OpKind
---@param d table the Installed, Checked, Updated or Deleted payload
---@return string
function M.summary(kind, d)
  if kind == 'install' then
    local done = #d.names - #d.failed
    return ('Installed %d of %s in %s%s'):format(done, count(#d.names, 'plugin'), duration(d.ms), failures(d))
  elseif kind == 'check' then
    local found = d.updates > 0 and count(d.updates, 'update') or 'no updates'
    return ('Checked %s in %s · %s%s'):format(count(#d.names, 'plugin'), duration(d.ms), found, failures(d))
  elseif kind == 'update' then
    if #d.updated == 0 and #d.failed == 0 then
      return 'nothing to update'
    end
    local restart = d.restart and ' · restart to use them' or ''
    return ('Updated %d of %s in %s%s%s'):format(
      #d.updated,
      count(d.total, 'plugin'),
      duration(d.ms),
      restart,
      failures(d)
    )
  end
  if #d.deleted == #d.names then
    return ('Deleted %s'):format(count(#d.deleted, 'plugin'))
  end
  return ('Deleted %d of %s'):format(#d.deleted, count(#d.names, 'plugin'))
end

return M
