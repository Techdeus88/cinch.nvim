-- spec.lua: a second spec of a plugin whose install failed gets another try, not a
-- "started loading" warning; one that failed to load still applies on restart.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local spec, state = require('cinch.spec'), require('cinch.state')
local function reg(list)
  return spec.register(spec.collect({ list }, { file = 'init.lua' }))
end

reg({ { 'owner/broken', cmd = 'One' }, { 'owner/crashed' } })
local broken, crashed = state.plugins.broken, state.plugins.crashed
broken.err = 'not installed'
state.set(broken, 'failed', 'install')
state.set(crashed, 'pending')
state.set(crashed, 'loading')
state.set(crashed, 'failed', 'load')

H.after_startup(function()
  local added = reg({ { 'owner/broken', cmd = 'Two' }, { 'owner/crashed', cmd = 'Two' } })
  H.eq(broken.state, 'registered', 'a failed install is registered again')
  H.eq({ broken.err, added[1] == broken }, { nil, true }, 'and goes back through the install')
  H.eq(crashed.state, 'failed', 'a failed load stays failed')
  H.eq(H.noted('`crashed` already started loading'), true, 'with the restart message')
  H.eq(H.noted('`broken` already started loading'), false, 'and none for the failed install')
end)
