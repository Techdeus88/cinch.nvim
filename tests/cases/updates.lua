-- features/updates.lua: a check finds new commits in the background, reports a fetch that
-- fails, and applying moves a plugin and clears it from pending.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local alpha_src, alpha_dir = H.own('alpha.nvim')
local beta_src, beta_dir = H.own('beta.nvim')
local gamma_src, gamma_dir = H.own('gamma')

require('cinch').setup({
  confirm = false,
  spec = { { { alpha_src }, { beta_src, cmd = 'BetaGo' }, { gamma_src } } },
})

H.after_startup(function()
  local u, pack = require('cinch.features.updates'), require('cinch.pack')
  H.commit(alpha_dir, 'feat: one')
  H.commit(alpha_dir, 'fix: two')
  H.commit(beta_dir, 'docs: three')
  vim.fn.rename(gamma_dir, gamma_dir .. '-gone')

  H.eq(u.fresh(), false, 'never checked')
  u.check(nil, { notify = true })
  H.eq(H.plugin('alpha.nvim').activity, 'checking', 'runs in the background')
  H.wait(function()
    return not u.checking
  end, 'the check')

  local subjects = vim.tbl_map(function(c)
    return c.subject
  end, u.results['alpha.nvim'].commits)
  H.eq(subjects, { 'fix: two', 'feat: one' }, 'new commits, newest first')
  H.eq(#u.results['beta.nvim'].commits, 1, 'beta has one')
  H.eq(u.results.gamma, nil, 'gamma could not be checked')
  H.eq(H.noted('could not fetch `gamma`'), true, 'which is reported')
  H.eq(H.noted('2 updates available'), true, 'the outcome is reported')
  H.eq(u.fresh(), true, 'fresh now')

  local alpha = H.plugin('alpha.nvim')
  local before = pack.rev(alpha)
  u.apply({ 'alpha.nvim' })
  H.eq(pack.rev(alpha) ~= before, true, 'applying moves the plugin')
  H.eq(u.results['alpha.nvim'], nil, 'and clears it')
  H.eq(H.noted('restart Neovim to run the new code of alpha.nvim'), true, 'a loaded plugin needs a restart')
  u.apply()
  H.eq(vim.tbl_count(u.results), 0, 'apply() takes the rest')
  H.eq(H.noted('new code of beta.nvim'), false, 'beta was not loaded, so no restart')
  vim.fn.rename(gamma_dir .. '-gone', gamma_dir)
end)
