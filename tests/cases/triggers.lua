-- handler.lua: event, ft, cmd and keys triggers, their replays, and a custom trigger.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

cinch.trigger('on_flag', {
  arm = function(p)
    vim.g.flag_armed = p.name
    _G.load_flag = function()
      require('cinch.handler').fire(p, 'flag')
    end
  end,
})

cinch.setup({
  confirm = false,
  spec = {
    {
      { H.src('alpha.nvim'), cmd = 'AlphaCmd' },
      {
        H.src('delta.nvim'),
        keys = {
          'gD',
          {
            'gX',
            function()
              require('delta').hit()
            end,
            desc = 'hit',
          },
        },
      },
      { H.src('gamma'), event = { 'User GammaGo', 'BufReadPost' } },
      { src = (H.own('gamma')), name = 'gamma-ft', ft = 'cnc' },
      { H.src('vimmy'), ft = 'cnc' },
      { H.src('cmdy'), cmd = 'Ghost' },
      { H.src('beta.nvim'), on_flag = true },
    },
  },
})

H.after_startup(function()
  local alpha = H.plugin('alpha.nvim')
  H.eq(alpha.state, 'pending', 'cmd plugin waits')
  vim.cmd('AlphaCmd! one two')
  H.eq(alpha.reason, 'cmd AlphaCmd', 'cmd loads')
  H.eq(vim.g.alpha_cmd, { args = 'one two', bang = true, range = 0 }, 'the command runs again with its args')
  H.eq(vim.g.alpha_plugin, 1, 'plugin/ sourced once')
  H.eq(vim.g.alpha_after, 1, 'after/plugin/ sourced on a load after startup')

  local delta = H.plugin('delta.nvim')
  H.press('gD')
  H.eq(delta.reason, 'keys gD', 'a key loads')
  H.eq(vim.g.delta_own, 1, 'the key is fed again to the mapping the plugin made')
  H.press('gX')
  H.eq(vim.g.delta_hit, 1, 'a key with an rhs is mapped once the plugin loaded')
  H.eq(vim.fn.maparg('gX', 'n', false, true).desc, 'hit', 'with its options')

  local gamma = H.plugin('gamma')
  vim.api.nvim_exec_autocmds('User', { pattern = 'GammaGo' })
  H.eq(gamma.reason, 'event User GammaGo', 'an event loads')
  H.eq(vim.g.gamma_user, 1, 'the plugin sees the event that woke it, once')
  vim.api.nvim_exec_autocmds('User', { pattern = 'GammaGo' })
  H.eq(vim.g.gamma_user, 2, 'and later ones as usual')
  local stubs = vim.tbl_filter(function(a)
    return (a.desc or ''):find('^cinch:') ~= nil
  end, vim.api.nvim_get_autocmds({ event = 'BufReadPost' }))
  H.eq(#stubs, 0, 'its other trigger is removed')

  vim.cmd('enew | setfiletype cnc')
  H.eq(H.plugin('gamma-ft').reason, 'event FileType cnc', 'a filetype loads')
  H.eq(vim.b.gamma_ft, true, 'and its ftplugin applies to the buffer')
  H.eq(vim.b.vimmy, 1, 'a Vimscript FileType autocmd replays once, able to call its s: functions')
  H.eq(H.noted('replaying FileType'), false, 'with no error')

  vim.cmd('Ghost')
  H.eq(H.noted('Not an editor command: Ghost$'), true, 'a command the plugin never defines fails once')
  H.eq(vim.api.nvim_get_commands({}).Ghost, nil, 'and the stub is gone')

  H.eq(vim.g.flag_armed, 'beta.nvim', 'a custom trigger is armed')
  _G.load_flag()
  H.eq(H.plugin('beta.nvim').reason, 'flag', 'and loads its plugin')
end)
