-- An event trigger is nested: what a config does fires its own autocmds.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local schemes = 0
vim.api.nvim_create_autocmd('ColorScheme', {
  callback = function()
    schemes = schemes + 1
  end,
})
require('cinch').setup({
  confirm = false,
  spec = {
    {
      {
        H.src('gamma'),
        event = 'User NestyGo',
        config = function()
          vim.cmd.colorscheme('habamax')
        end,
      },
    },
  },
})

H.after_startup(function()
  vim.api.nvim_exec_autocmds('User', { pattern = 'NestyGo' })
  H.eq(H.plugin('gamma').state, 'loaded', 'the event loads it')
  H.eq(schemes, 1, 'ColorScheme fired for the colorscheme its config set')
end)
