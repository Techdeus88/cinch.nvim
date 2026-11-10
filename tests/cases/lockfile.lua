-- The lockfile lists a plugin missing on disk, as after a wiped data dir. vim.pack installs it
-- on its first call of the session; cinch makes that call, carrying confirm = false.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local fixture = vim.fs.joinpath(vim.env.CINCH_FIXTURES, 'alpha.nvim')
local rev = H.sh({ 'git', '-C', fixture, 'rev-parse', 'HEAD' })
H.write(
  require('cinch.pack').lockfile(),
  { vim.json.encode({ plugins = { ['alpha.nvim'] = { src = H.src('alpha.nvim'), rev = rev } } }) }
)
local prompts = 0
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.confirm = function()
  prompts = prompts + 1
  return 1
end

require('cinch').setup({ confirm = false, spec = { { { H.src('alpha.nvim') } } } })

H.after_startup(function()
  H.eq(prompts, 0, 'no install prompt with confirm = false')
  H.eq(H.plugin('alpha.nvim').path ~= nil, true, 'installed')
  H.eq(H.plugin('alpha.nvim').state, 'loaded', 'and loaded later')
end)
