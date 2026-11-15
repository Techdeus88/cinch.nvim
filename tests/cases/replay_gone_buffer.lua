-- Replaying an event whose buffer is gone: another handler of the event deleted it, the
-- way a dashboard swaps out the first buffer on VimEnter. The plugin's autocmds still run.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = {
    {
      {
        src = H.src('gamma'),
        name = 'wiper',
        event = 'User EnteryGo',
        config = function()
          local buf = vim.api.nvim_get_current_buf()
          vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
          vim.api.nvim_buf_delete(buf, { force = true })
        end,
      },
      { H.src('entery'), event = 'User EnteryGo' },
    },
  },
})

H.after_startup(function()
  vim.api.nvim_exec_autocmds('User', { pattern = 'EnteryGo' })
  H.eq(H.plugin('entery').state, 'loaded', 'the event loads it')
  H.eq(H.noted('Invalid buffer'), false, 'the replay does not raise')
  H.eq(vim.g.entery_group, true, 'an autocmd in a group of its own runs')
  H.eq(vim.g.entery_buf_valid, true, 'and a callback gets a buffer that exists')
end)
