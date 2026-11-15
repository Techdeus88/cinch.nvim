-- A key whose plugin fails to load is not replayed: its stub is gone, so the keys would
-- run as themselves.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

vim.g.mapleader = ' '
require('cinch').setup({
  confirm = false,
  -- Without the window, which a failed load opens over the buffer.
  features = {},
  spec = {
    {
      {
        H.src('delta.nvim'),
        keys = '<leader>dd',
        config = function()
          error('boom')
        end,
      },
    },
  },
})

H.after_startup(function()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two' })
  H.press('<leader>dd')
  H.eq(H.plugin('delta.nvim').state, 'failed', 'the load failed')
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'one', 'two' }, 'and dd did not delete a line')
end)
