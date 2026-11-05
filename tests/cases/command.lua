-- command.lua: :Cinch subcommands, the ones features add, bang forms and completion.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = { { { H.src('alpha.nvim'), cmd = 'AlphaCmd' }, { H.src('beta.nvim') } } },
})

H.after_startup(function()
  local command = require('cinch.command')
  H.eq(
    command.complete('', 'Cinch '),
    { 'build', 'check', 'clean', 'del', 'load', 'open', 'restore', 'stats', 'update' },
    'every subcommand'
  )
  H.eq(command.complete('a', 'Cinch load a'), { 'alpha.nvim' }, 'plugin names')
  H.eq(command.complete('', 'Cinch update! '), { 'alpha.nvim', 'beta.nvim' }, 'after a bang too')

  vim.cmd('Cinch load alpha.nvim')
  H.eq(H.plugin('alpha.nvim').reason, 'manual', ':Cinch load')

  vim.cmd('Cinch check')
  H.wait(function()
    return H.noted('everything is up to date')
  end, ':Cinch check')

  vim.cmd('Cinch update! beta.nvim')
  H.eq(H.noted('subcommands'), false, 'update! is update with a bang')

  vim.cmd('Cinch nope')
  H.eq(
    H.noted('subcommands: build, check, clean, del, load, open, restore, stats, update'),
    true,
    'an unknown one lists them'
  )
  H.eq(require('cinch.command') ~= nil, true, 'loaded on first use')
end)
