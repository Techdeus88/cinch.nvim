-- add() moves a plugin off `later` before the queue reaches it: its trigger loads it,
-- not the queue.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

cinch.setup({ confirm = false, spec = { { { H.src('beta.nvim') }, { H.src('alpha.nvim') } } } })
cinch.add({ { H.src('beta.nvim'), cmd = 'BetaGo' } }, { confirm = false })
local drained = false
cinch.later(function()
  drained = true
end)

H.after_startup(function()
  H.wait(function()
    return drained
  end, 'the later queue')
  local beta = H.plugin('beta.nvim')
  H.eq(H.plugin('alpha.nvim').state, 'loaded', 'a later plugin loads from the queue')
  H.eq({ beta.when, beta.state }, { 'trigger', 'pending' }, 'one moved to a trigger waits for it')
  H.eq(vim.api.nvim_get_commands({}).BetaGo ~= nil, true, 'with its stub armed')
end)
