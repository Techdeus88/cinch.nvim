-- VeryLazy beside other events: whichever comes first, one of the events or the
-- `later` queue, loads the plugin, and it loads once.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

cinch.setup({
  confirm = false,
  spec = {
    {
      -- Its event never fires: `later` loads it.
      { H.src('alpha.nvim'), event = { 'VeryLazy', 'User NeverFires' } },
      -- Its event fires during init.lua, before `later` starts.
      { H.src('beta.nvim'), event = { 'VeryLazy', 'User BetaGo' } },
    },
  },
})

vim.api.nvim_exec_autocmds('User', { pattern = 'BetaGo' })
local beta_in_init = H.plugin('beta.nvim').reason

H.after_startup(function()
  local alpha = H.plugin('alpha.nvim')
  H.wait(function()
    return alpha.state == 'loaded'
  end, 'alpha.nvim to load later')
  H.eq(alpha.reason, 'later', 'with no event, later loads it')
  H.eq(vim.g.alpha_plugin, 1, 'once')
  local stubs = vim.tbl_filter(function(a)
    return (a.desc or ''):find('^cinch:') ~= nil
  end, vim.api.nvim_get_autocmds({ event = 'User', pattern = 'NeverFires' }))
  H.eq(#stubs, 0, 'and its event stub is removed')

  local beta = H.plugin('beta.nvim')
  H.eq(beta_in_init, 'event User BetaGo', 'an event that fires first loads it')
  H.eq(beta.reason, 'event User BetaGo', 'later does not load it again')
  H.eq(vim.g.beta_order, 'beta ', 'its plugin/ file ran once')
end)
