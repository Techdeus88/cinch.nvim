-- updates.every: a check runs on a timer while Neovim is up, and reports only when
-- updates are pending.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local alpha_src, alpha_dir = H.own('alpha.nvim')

require('cinch').setup({ confirm = false, updates = { every = 1 }, spec = { { { alpha_src } } } })

H.after_startup(function()
  local u = require('cinch.features.updates')
  H.eq(u.opts.every, 1, 'the interval you set')
  H.commit(alpha_dir, 'feat: something new')
  H.wait(function()
    return u.results['alpha.nvim'] ~= nil
  end, 'a timer check finds the new commit', 10000)
  H.eq(H.noted('1 update available'), true, 'and reports it')
end)
