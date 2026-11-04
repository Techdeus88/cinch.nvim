-- The startup sequence: now during init.lua, later after VimEnter, triggers wait;
-- init hooks, enabled and cond, failed installs, and the Later event.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

vim.api.nvim_create_autocmd('User', {
  pattern = 'CinchLater',
  callback = function()
    vim.g.later_fired = vim.v.vim_did_enter
  end,
})

require('cinch').setup({
  confirm = false,
  spec = {
    {
      {
        H.src('early'),
        load = 'now',
        init = function(p)
          vim.g.init_state = p.state
        end,
      },
      { H.src('beta.nvim') },
      { H.src('alpha.nvim'), cmd = 'AlphaCmd' },
      { H.src('gamma'), enabled = false },
      {
        H.src('delta.nvim'),
        cond = function()
          return false
        end,
      },
      {
        H.src('twomods'),
        cond = function()
          error('oops')
        end,
      },
      { H.src('missing') },
    },
  },
})
vim.g.early_state_in_init = H.plugin('early').state

H.after_startup(function()
  local pack = require('cinch.pack')
  H.eq(vim.g.early_state_in_init, 'loaded', 'now loads during init.lua')
  H.eq(vim.g.early_did_enter, 0, 'and its plugin/ runs in the normal startup pass')
  H.eq(vim.g.init_state, 'registered', 'init runs before the plugin is armed')
  H.eq(H.plugin('beta.nvim').reason, 'later', 'later loads after startup')
  H.eq(vim.g.beta_order, 'early beta ', 'now before later')
  H.eq(vim.g.later_fired, 1, 'User CinchLater fires after VimEnter')
  H.eq(H.plugin('alpha.nvim').state, 'pending', 'a trigger plugin waits')
  H.eq(vim.o.rtp:find('alpha.nvim', 1, true), nil, 'and is not on the runtimepath')
  H.eq({ H.plugin('gamma').state, H.plugin('gamma').reason }, { 'disabled', 'enabled' }, 'enabled = false')
  H.eq(vim.uv.fs_stat(pack.dir .. '/gamma'), nil, 'a disabled plugin is not installed')
  H.eq({ H.plugin('delta.nvim').state, H.plugin('delta.nvim').reason }, { 'disabled', 'cond' }, 'cond returns false')
  H.eq(H.plugin('twomods').state, 'loaded', 'a cond that raises leaves the plugin on')
  H.eq(H.noted('cond raised, so it stays on'), true, 'with a warning')
  local m = H.plugin('missing')
  H.eq({ m.state, m.failed_in }, { 'failed', 'install' }, 'a src that does not exist')
  H.eq(H.noted('not installed: missing'), true, 'is reported')
end)
