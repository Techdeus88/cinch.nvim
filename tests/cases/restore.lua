-- :Cinch restore: puts plugins back on the revisions the lockfile records, after their
-- checkouts moved on their own. With ! it does not ask first.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local alpha_src = H.own('alpha.nvim')

require('cinch').setup({ confirm = false, spec = { { { alpha_src } } } })

H.after_startup(function()
  local pack = require('cinch.pack')
  local alpha = H.plugin('alpha.nvim')
  local locked = pack.rev(alpha)
  H.commit(alpha.path, 'drift: the checkout moves on its own')
  alpha.rev = nil
  H.eq(pack.rev(alpha) ~= locked, true, 'the checkout is off the locked commit')

  ---@return boolean whether alpha's row asks
  local function asks()
    local w = require('cinch.features.ui').windows()
    local lines = w.list and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w.list), 0, -1, false) or {}
    return table.concat(lines, '\n'):find('Restore alpha.nvim Yes (y) or No (n)', 1, true) ~= nil
  end
  vim.cmd('Cinch restore')
  H.eq(asks(), true, 'without !, the row of the plugin that moved asks')
  H.press('n')
  alpha.rev = nil
  H.eq(pack.rev(alpha) ~= locked, true, 'n leaves it where it is')
  vim.cmd('Cinch restore')
  H.press('y')
  alpha.rev = nil
  H.eq(pack.rev(alpha), locked, 'y puts it back on the locked commit')
  vim.cmd('Cinch restore')
  H.eq({ asks(), H.noted('^nothing to restore$') }, { false, true }, 'then nothing has moved, and it says so')

  H.commit(alpha.path, 'drift again')
  vim.cmd('Cinch restore! alpha.nvim')
  alpha.rev = nil
  H.eq(pack.rev(alpha), locked, 'restore! puts it back without asking')
end)
