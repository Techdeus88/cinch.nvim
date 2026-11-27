-- The older way in still works: `features = { 'groups' }` with `groups = { ... }`.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
vim.opt.rtp:prepend(assert(vim.env.CINCH_GROUPS_ROOT))

require('cinch').setup({
  confirm = false,
  features = { 'messages', 'groups' },
  groups = { real = { cmd = 'AlphaCmd' } },
  spec = { { { H.src('alpha.nvim'), group = 'real' } } },
})

H.after_startup(function()
  local alpha = H.plugin('alpha.nvim')
  H.eq({ require('cinch-groups').of('alpha.nvim'), alpha.load }, { 'real', 'trigger' }, 'the feature still starts it')
end)
