-- A shell build killed by a signal exits with code 0 and a signal: it still failed.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch, events = require('cinch'), require('cinch.events')

local built = {}
events.on('Build', function(d)
  built[#built + 1] = d
end)
cinch.setup({
  confirm = false,
  features = {},
  spec = { { { H.src('alpha.nvim'), cmd = 'AlphaCmd', build = 'kill -9 $$' } } },
})

H.after_startup(function()
  H.wait(function()
    return #built == 1
  end, 'the install build')
  H.eq(built[1].ok, false, 'a build killed by a signal failed')
  H.eq(built[1].err, 'killed by signal 9', 'and says why')
  H.eq(H.noted('build of `alpha.nvim` failed'), true, 'and is reported')
end)
