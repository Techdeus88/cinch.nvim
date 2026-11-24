-- Saying no to the reinstall of a plugin deleted this session leaves it as it was.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({ confirm = false, spec = { { { H.src('alpha.nvim'), load = 'now' } } } })

H.after_startup(function()
  local cinch = require('cinch')
  local alpha = H.plugin('alpha.nvim')
  H.eq(alpha.state, 'loaded', 'loaded at startup')
  cinch.del('alpha.nvim', { force = true })
  H.eq(alpha.deleted, true, 'deleted from disk')

  cinch.opts.confirm = true
  vim.cmd('Cinch')
  cinch.install('alpha.nvim')
  H.press('n')
  vim.wait(50)
  H.eq({ alpha.state, alpha.err }, { 'loaded', nil }, 'a no leaves a loaded plugin alone')
end)
