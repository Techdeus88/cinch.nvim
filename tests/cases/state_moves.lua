-- state.lua: the allowed moves, failed_in, Register, State and Activity events.
-- Records here are partial on purpose: state.lua only reads name and state.
---@diagnostic disable: missing-fields
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local events, state = require('cinch.events'), require('cinch.state')

H.after_startup(function()
  local log = {}
  events.on('Register', function(d)
    log[#log + 1] = 'register ' .. d.plugin.name
  end)
  events.on('State', function(d)
    log[#log + 1] = d.from .. '>' .. d.to
  end)
  events.on('Activity', function(d)
    log[#log + 1] = 'activity ' .. tostring(d.to)
  end)

  local p = state.add({ name = 'x' } --[[@as cinch.Plugin]])
  state.set(p, 'pending')
  state.activity(p, 'updating')
  state.activity(p, nil)
  state.set(p, 'loading', 'event X')
  state.set(p, 'failed')
  H.eq(log, {
    'register x',
    'registered>pending',
    'activity updating',
    'activity nil',
    'pending>loading',
    'loading>failed',
  }, 'events in order')
  H.eq(p.failed_in, 'load', 'failed while loading')
  H.eq(p.reason, 'event X', 'reason kept')
  H.eq(state.set(p, 'failed'), false, 'the same state is no move')
  H.eq(pcall(state.set, p, 'loaded'), false, 'an illegal move raises')
  H.eq(pcall(state.add, { name = 'x' }), false, 'a name registered twice raises')

  local q = state.add({ name = 'y' } --[[@as cinch.Plugin]])
  state.set(q, 'failed')
  H.eq(q.failed_in, 'install', 'failed before loading')
  state.set(q, 'registered')
  state.set(q, 'disabled', 'cond')
  H.eq(state.can(q, 'pending'), false, 'disabled goes back through registered')
  H.eq(state.can(q, 'registered'), true, 'which it may')
  H.eq(#state.list, 2, 'list in declaration order')
end)
