-- A keys stub is cinch's to delete only while it is still the mapping: one of yours set
-- since stays, and one of yours the stub replaced comes back when the stub goes.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

vim.keymap.set('n', 'gC', '<Cmd>let g:mine_c = 1<CR>')
require('cinch').setup({
  confirm = false,
  spec = { { { H.src('delta.nvim'), keys = { 'gA', 'gB', 'gC' } } } },
})
vim.keymap.set('n', 'gB', '<Cmd>let g:mine_b = 1<CR>')

H.after_startup(function()
  H.press('gA')
  H.eq(H.plugin('delta.nvim').state, 'loaded', 'gA loads the plugin')
  H.press('gB')
  H.eq(vim.g.mine_b, 1, 'a mapping of yours set after setup() stays')
  H.press('gC')
  H.eq(vim.g.mine_c, 1, 'and one the stub replaced is back')
  H.eq(vim.fn.maparg('gA', 'n'), '', 'the stub itself is gone')
end)
