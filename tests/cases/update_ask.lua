-- :Cinch update without !, and u and U in the window: the row of each plugin with
-- something new asks. With confirm off, they apply without asking. vim.pack's review
-- tab never opens.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local alpha_src, alpha_dir = H.own('alpha.nvim')

require('cinch').setup({ confirm = false, spec = { { { alpha_src }, { H.src('beta.nvim') } } } })

H.after_startup(function()
  -- Installed without asking; the rows ask from here on.
  local cinch = require('cinch')
  cinch.opts.confirm = true
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
  ---@param msg string
  local function newer(msg)
    H.commit(alpha_dir, msg)
    u.check()
    settled()
    before = pack.rev(alpha)
  end
  local function applied()
    H.wait(function()
      alpha.rev = nil
      return pack.rev(alpha) ~= before
    end, 'the update to apply')
  end

  -- u and U ask on the row too.
  newer('feat: for u')
  local function on_alpha()
    local w = require('cinch.features.ui').windows()
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w.list), 0, -1, false)
    vim.api.nvim_win_set_cursor(w.list, { vim.fn.match(lines, ' alpha\\.nvim ') + 1, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(w.list) })
  end
  on_alpha()
  H.press('u')
  H.eq(shows('Update alpha.nvim Yes (y) or No (n)'), true, 'u asks on the row')
  H.press('n')
  H.press('U')
  H.eq(shows('Update alpha.nvim Yes (y) or No (n)'), true, 'and so does U')
  H.press('y')
  applied()
  on_alpha()
  H.press('u')
  local w = require('cinch.features.ui').windows()
  local list = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w.list), 0, -1, false), '\n')
  H.eq(
    { shows('Yes (y)'), list:find(' alpha%.nvim [^\n]*already up to date') ~= nil },
    { false, true },
    'then it is up to date'
  )

  -- With confirm off, nothing asks.
  cinch.opts.confirm = false
  newer('feat: no asking')
  vim.cmd('Cinch update')
  settled()
  H.eq(shows('Yes (y)'), false, ':Cinch update does not ask')
  applied()
  newer('feat: no asking for U')
  H.press('U')
  H.eq(shows('Yes (y)'), false, 'nor does U')
  applied()
  H.eq(vim.fn.tabpagenr('$'), 1, "vim.pack's review tab never opened")
end)
