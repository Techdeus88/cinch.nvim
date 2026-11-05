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

  vim.cmd('Cinch restore! alpha.nvim')
  alpha.rev = nil
  H.eq(pack.rev(alpha), locked, 'restore puts it back on the locked commit')
end)
