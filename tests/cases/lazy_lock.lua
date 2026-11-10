-- lazy-lock.json: a plugin not installed yet installs at the commit lazy.nvim locked.
-- One on disk, or in vim.pack's lockfile already, keeps what it has.
-- phases: 2
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local alpha_src, alpha_dir = H.own('alpha.nvim')
local beta_src, beta_dir = H.own('beta.nvim')
local head = { 'git', 'rev-parse', 'HEAD' }

if H.phase == 1 then
  local locked = H.sh(head, alpha_dir)
  H.commit(alpha_dir, 'newer than the lock')
  H.write('lazy-lock.json', {
    vim.json.encode({
      ['alpha.nvim'] = { branch = 'main', commit = locked },
      ['beta.nvim'] = { branch = 'main', commit = 'not a commit' },
      ['gone.nvim'] = { branch = 'main', commit = locked },
    }),
  })
  vim.g.locked = locked
else
  -- Rewritten to a commit alpha is not on: nothing may read it now.
  H.write('lazy-lock.json', { vim.json.encode({ ['alpha.nvim'] = { commit = H.sh(head, alpha_dir) } }) })
end

require('cinch').setup({ confirm = false, spec = { { { alpha_src }, { beta_src } } } })

H.after_startup(function()
  local pack = require('cinch.pack')
  local lock = vim.json.decode(table.concat(vim.fn.readfile(vim.go.packlockfile), '\n'))
  local at = pack.rev(H.plugin('alpha.nvim'))
  H.eq(lock.plugins['alpha.nvim'].rev, at, 'the lockfile records what is on disk')
  H.eq(lock.plugins['gone.nvim'], nil, 'a plugin no spec names is not imported')
  if H.phase == 1 then
    H.eq(at, vim.g.locked, 'installed at the commit from lazy-lock.json')
    H.eq(H.noted('^1 plugin installs at the commit in lazy%-lock%.json$'), true, 'and says so')
    H.eq(pack.rev(H.plugin('beta.nvim')), H.sh(head, beta_dir), 'a bad entry is skipped: the newest commit')
    H.eq(H.plugin('alpha.nvim').state, 'loaded', 'and it loads')
  else
    H.eq(at ~= H.sh(head, alpha_dir), true, 'an installed plugin keeps its commit')
    H.eq(H.noted('lazy%-lock'), false, 'with nothing said')
  end
end)
