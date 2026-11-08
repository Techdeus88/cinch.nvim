-- require() while init.lua runs loads the plugin once, with its plugin/ files left to
-- Neovim's startup pass. An init hook cannot load a plugin whose dependency has not
-- started: that would fail the plugin for the session.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local from_init

require('cinch').setup({
  confirm = false,
  spec = {
    {
      {
        H.src('modly'),
        cmd = 'ModlyGo',
        config = function()
          require('modly')
        end,
      },
      { H.src('beta.nvim'), deps = { 'delta.nvim' } },
      {
        H.src('twomods'),
        init = function()
          from_init = { pcall(require, 'beta') }
        end,
      },
      { H.src('delta.nvim'), cmd = 'DeltaGo' },
    },
  },
})

H.eq(vim.v.vim_did_init, 0, 'still in init.lua')
H.eq(require('modly').name, 'modly', 'require works here')
H.eq(H.plugin('modly').reason, 'require modly', 'and loads the plugin')

H.after_startup(function()
  H.eq(vim.g.modly_plugin, 1, 'its plugin/ ran once')
  H.eq(vim.g.modly_runs, 1, 'its module ran once')

  H.eq(from_init[1], false, 'the init hook could not load beta')
  H.eq(from_init[2]:find('needs `delta.nvim`, which has not started yet', 1, true) ~= nil, true, from_init[2])
  H.eq(H.plugin('beta.nvim').state, 'loaded', 'and beta loaded in its turn')
end)
