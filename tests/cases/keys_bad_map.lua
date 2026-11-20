-- A key that cannot be mapped is reported by name, and the plugin's other keys are
-- still mapped: as stubs before it loads, and as its spec mappings after.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

vim.keymap.set('n', 'gX', '<Cmd>let g:mine_x = 1<CR>')
require('cinch').setup({
  confirm = false,
  features = {},
  spec = {
    {
      { H.src('delta.nvim'), keys = { { 'gA', mode = 'Q' }, 'gB' } },
      {
        H.src('alpha.nvim'),
        load = 'now',
        keys = {
          { 'gX', '<Cmd>let g:alpha_x = 1<CR>', unique = true },
          { 'gY', '<Cmd>let g:alpha_y = 1<CR>' },
        },
      },
    },
  },
})

H.after_startup(function()
  H.eq(H.noted('`delta.nvim`: cannot map `gA`'), true, 'the bad stub is reported by its key')
  H.eq(H.noted('`alpha.nvim`: cannot map `gX`'), true, 'and so is the clashing spec mapping')

  H.eq(H.plugin('alpha.nvim').state, 'loaded', 'alpha still loaded')
  H.press('gY')
  H.eq(vim.g.alpha_y, 1, 'its other mapping exists')
  H.press('gX')
  H.eq(vim.g.mine_x, 1, 'and gX is still yours')

  H.press('gB')
  H.eq(H.plugin('delta.nvim').state, 'loaded', 'the stub after the bad one loads delta')
  H.eq(H.noted('was mapped by something else'), false, 'the stub that never existed is not reported as replaced')
end)
