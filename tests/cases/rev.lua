-- pack.rev: the commit a plugin is on, whether HEAD is detached, names a branch whose
-- ref is loose, or names a branch whose ref is packed.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
require('cinch').setup({ confirm = false, spec = { { { H.src('alpha.nvim') } } } })

H.after_startup(function()
  local pack = require('cinch.pack')
  local alpha = H.plugin('alpha.nvim')
  local function head()
    return H.sh({ 'git', '-C', alpha.path, 'rev-parse', 'HEAD' })
  end
  local function rev()
    alpha.rev = nil -- what the cache holds is not the question
    return pack.rev(alpha)
  end

  H.eq(rev(), head(), 'detached HEAD: the hash in .git/HEAD')
  H.sh({ 'git', '-C', alpha.path, 'checkout', '-q', '-b', 'topic' })
  H.commit(alpha.path, 'topic commit')
  H.eq(rev(), head(), 'on a branch: the commit the branch names')
  H.sh({ 'git', '-C', alpha.path, 'pack-refs', '--all' })
  H.eq(rev(), head(), 'and when the branch is in packed-refs')
end)
