-- args: notes.cnc
-- A file on the command line: its FileType comes after Neovim's load-plugins step but
-- before VimEnter, so an ft plugin loads in between. It still gets plugin/ and
-- after/plugin/, each once.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

vim.filetype.add({ extension = { cnc = 'cnc' } })
-- Installed during init.lua, so the trigger is armed when the file is read.
require('cinch').setup({ confirm = false, spec = { { { H.src('alpha.nvim'), ft = 'cnc' } } } })

local at = {}
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'cnc',
  once = true,
  callback = function()
    at = { init = vim.v.vim_did_init, enter = vim.v.vim_did_enter }
  end,
})

H.after_startup(function()
  H.eq(at, { init = 1, enter = 0 }, 'the file got its filetype between the two')
  H.eq(H.plugin('alpha.nvim').reason, 'event FileType cnc', 'its ft plugin loaded')
  H.eq(vim.g.alpha_plugin, 1, 'plugin/ ran once')
  H.eq(vim.g.alpha_after, 1, 'after/plugin/ ran once')
end)
