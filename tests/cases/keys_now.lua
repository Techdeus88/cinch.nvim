-- The mappings a spec defines are made for a plugin that loads on its own, not only for a trigger one.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = {
    { { H.src('delta.nvim'), load = 'now', keys = { { 'gX', '<Cmd>let g:gx = 1<CR>', desc = 'x' } } } },
  },
})

H.after_startup(function()
  H.eq(H.plugin('delta.nvim').state, 'loaded', 'the plugin loaded at startup')
  H.press('gX')
  H.eq(vim.g.gx, 1, 'its spec mapping exists')
  H.eq(H.noted('triggers are ignored'), false, 'and nothing is said to be ignored')
end)
