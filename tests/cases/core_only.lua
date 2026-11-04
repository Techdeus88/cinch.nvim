-- No features at all: the core alone still installs, loads and updates plugins, and
-- reports through plain vim.notify.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
H.unreport()

local gamma_src, gamma_dir = H.own('gamma')
require('cinch').setup({
  confirm = false,
  features = {},
  spec = { { { H.src('alpha.nvim') }, { H.src('beta.nvim'), cmd = 'BetaGo' }, { gamma_src }, { H.src('missing') } } },
})

H.after_startup(function()
  for _, f in ipairs({ 'messages', 'stats', 'updates', 'ui' }) do
    H.eq(package.loaded['cinch.features.' .. f], nil, f .. ' not loaded')
  end
  H.eq(H.plugin('alpha.nvim').state, 'loaded', 'installs and loads')
  H.eq(H.noted('^cinch: not installed: missing'), true, 'reports fall back to vim.notify')

  vim.cmd('Cinch load beta.nvim')
  H.eq(H.plugin('beta.nvim').state, 'loaded', ':Cinch load works without features')

  local pack = require('cinch.pack')
  local gamma = H.plugin('gamma')
  local before = pack.rev(gamma)
  H.commit(gamma_dir, 'feat: core only')
  local ok = require('cinch').update({ 'gamma' }, { force = true })
  H.eq(ok, true, 'update through the core')
  H.eq(pack.rev(gamma) ~= before, true, 'moves the plugin')
  H.eq(H.noted('subcommands: build, load, update'), false, 'nothing went wrong')
end)
