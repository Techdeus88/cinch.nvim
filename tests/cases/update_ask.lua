-- :Cinch update without !: cinch checks, then the row of each plugin with something
-- new asks. vim.pack's review tab never opens.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local alpha_src, alpha_dir = H.own('alpha.nvim')

require('cinch').setup({ confirm = false, spec = { { { alpha_src }, { H.src('beta.nvim') } } } })

H.after_startup(function()
  local u, pack = require('cinch.features.updates'), require('cinch.pack')
  local alpha = H.plugin('alpha.nvim')
  local function settled()
    H.wait(function()
      return not u.checking
    end, 'the check')
    vim.wait(50)
  end
  ---@param text string
  local function shows(text)
    local w = require('cinch.features.ui').windows()
    local lines = w.list and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w.list), 0, -1, false) or {}
    return table.concat(lines, '\n'):find(text, 1, true) ~= nil
  end
  settled()
  local before = pack.rev(alpha)

  vim.cmd('Cinch update')
  settled()
  H.eq(shows('Yes (y)'), false, 'nothing new: nothing asks')

  H.commit(alpha_dir, 'feat: newer')
  vim.cmd('Cinch update')
  settled()
  H.eq(shows('Update alpha.nvim Yes (y) or No (n)'), true, 'the row of the plugin with an update asks')
  H.eq(shows('Update beta.nvim'), false, 'and only that one')
  H.press('n')
  alpha.rev = nil
  H.eq(pack.rev(alpha), before, 'n applies nothing')

  vim.cmd('Cinch update')
  settled()
  H.press('y')
  H.wait(function()
    alpha.rev = nil
    return pack.rev(alpha) ~= before
  end, 'the update to apply')
  H.eq(vim.fn.tabpagenr('$'), 1, "vim.pack's review tab never opened")
end)
