-- A shell build that cannot start fails like any other build: its plugin is not left
-- building, and what waits on it goes on.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch, events = require('cinch'), require('cinch.events')

local built = {}
events.on('Build', function(d)
  built[#built + 1] = d.ok
end)
cinch.setup({
  confirm = false,
  features = {},
  spec = { { { H.src('alpha.nvim'), cmd = 'AlphaCmd', build = 'true' } } },
})

H.after_startup(function()
  local alpha = H.plugin('alpha.nvim')
  H.wait(function()
    return #built == 1 and alpha.activity == nil
  end, 'the install build')
  -- No sh to run.
  local path = vim.env.PATH
  vim.env.PATH = '/no/such/dir'
  local ok = pcall(cinch.build, { 'alpha.nvim' })
  vim.env.PATH = path
  H.eq(ok, true, 'build() does not raise')
  H.wait(function()
    return #built == 2
  end, 'the build to end')
  H.eq({ built[2], alpha.activity }, { false }, 'it failed, and the plugin is not left building')
  H.eq(H.noted('build of `alpha.nvim` failed'), true, 'and says so')
  vim.cmd('AlphaCmd')
  H.eq(alpha.state, 'loaded', 'what waits on it still loads')
end)
