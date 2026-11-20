-- A `cmd` trigger never replaces a command that already exists: it is left alone, with a
-- warning, and the plugin's other triggers still work.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

vim.api.nvim_create_user_command('AlphaCmd', function()
  vim.g.mine = true
end, {})
require('cinch').setup({
  confirm = false,
  features = {},
  spec = { { { H.src('alpha.nvim'), cmd = { 'AlphaCmd', 'AlphaGo' } } } },
})

H.after_startup(function()
  H.eq(H.noted('`:AlphaCmd` already exists'), true, 'the clash is reported')
  local alpha = H.plugin('alpha.nvim')
  vim.cmd('AlphaCmd')
  H.eq(vim.g.mine, true, 'your command still runs')
  H.eq(alpha.state, 'pending', 'and does not load the plugin')
  -- alpha defines no AlphaGo, so the replay fails once it has loaded.
  pcall(vim.cmd, 'AlphaGo')
  H.eq(alpha.state, 'loaded', 'its other command still loads it')
  H.eq(H.noted('defined by something else'), false, 'with no warning that the trigger was taken')
end)
