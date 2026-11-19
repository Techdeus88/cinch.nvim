-- `User CinchLoadError` fires for a failed load even when nothing listens on the bus.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

local fired = {}
vim.api.nvim_create_autocmd('User', {
  pattern = 'CinchLoadError',
  callback = function(ev)
    fired[#fired + 1] = ev.data.name
  end,
})

cinch.setup({
  confirm = false,
  features = {},
  spec = {
    {
      H.src('alpha.nvim'),
      load = 'now',
      config = function()
        error('boom')
      end,
    },
  },
})

H.after_startup(function()
  H.eq(H.plugin('alpha.nvim').state, 'failed', 'its config raised')
  H.eq(fired, { 'alpha.nvim' }, 'User CinchLoadError fired once, for it')
end)
