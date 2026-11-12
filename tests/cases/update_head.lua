-- A check measures from the checked-out commit, the one vim.pack.update moves from, not
-- the lockfile's: git can move a plugin by hand, a `git pull` in its folder say. And a
-- check whose fetches end while vim.pack runs reads once it returns, without failing.
-- A plugin vim.pack could not update, which it says only in its log, counts as failed.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local alpha_src, alpha_dir = H.own('alpha.nvim')

require('cinch').setup({ confirm = false, spec = { { { alpha_src } } } })

H.after_startup(function()
  local u, pack = require('cinch.features.updates'), require('cinch.pack')
  local p = H.plugin('alpha.nvim')
  local function check()
    u.check()
    H.wait(function()
      return not u.checking
    end, 'the check')
  end
  local function head()
    return H.sh({ 'git', 'rev-parse', 'HEAD' }, p.path)
  end

  -- Pulled by hand: the lockfile is behind, but there is nothing to update.
  H.commit(alpha_dir, 'feat: one')
  H.sh({ 'git', 'fetch', '-q', 'origin' }, p.path)
  H.sh({ 'git', 'checkout', '-q', '--detach', 'origin/HEAD' }, p.path)
  check()
  H.eq(u.results['alpha.nvim'], nil, 'a pulled plugin has no update')

  -- Checked out back by hand: the lockfile is ahead, and the update moves it there.
  local newest = head()
  H.sh({ 'git', 'checkout', '-q', '--detach', 'HEAD~1' }, p.path)
  check()
  local r = u.results['alpha.nvim']
  H.eq(r and #r.commits, 1, 'one commit behind')
  u.apply({ 'alpha.nvim' })
  H.eq(head(), newest, 'and applying moves it')

  -- A check that runs into an update: its fetches end while vim.pack.update waits.
  H.commit(alpha_dir, 'feat: two')
  u.check()
  pack.update({ 'alpha.nvim' }, { force = true })
  H.wait(function()
    return not u.checking
  end, 'the check')
  H.eq(H.noted('update check failed'), false, 'the check waits for vim.pack')
  H.eq(u.results['alpha.nvim'], nil, 'and sees the update landed')

  -- Its origin gone: vim.pack's fetch fails, yet the call returns fine.
  vim.fn.rename(alpha_dir, alpha_dir .. '-gone')
  pack.update({ 'alpha.nvim' }, { force = true })
  vim.fn.rename(alpha_dir .. '-gone', alpha_dir)
  H.eq(H.noted('Updated 0 of 1 plugin in [%d.]+m?s · 1 failed'), true, 'the failure is counted')
end)
