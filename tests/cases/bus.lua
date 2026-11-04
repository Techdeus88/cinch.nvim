-- events.lua: priority order, once, cancel, error isolation, typo warnings, User mirrors.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local events = require('cinch.events')

H.after_startup(function()
  local seen = {}
  events.on('LoadPre', function(d)
    seen[#seen + 1] = 'p90'
    d.cancel = true
  end, { priority = 90 })
  events.on('LoadPre', function()
    seen[#seen + 1] = 'p10'
  end, { priority = 10 })
  events.on('LoadPre', function()
    seen[#seen + 1] = 'once'
  end, { once = true })
  local d = events.emit('LoadPre', {})
  events.emit('LoadPre', {})
  H.eq(seen, { 'p10', 'once', 'p90', 'p10', 'p90' }, 'priority order, and once runs once')
  H.eq(d.cancel, true, 'what subscribers set comes back to the emitter')

  local off = events.on('Phase', function()
    error('boom')
  end)
  local after = false
  events.on('Phase', function()
    after = true
  end)
  events.emit('Phase', { name = 'x', ms = 1 })
  H.eq(H.noted('Phase handler failed'), true, 'a failing subscriber is reported')
  H.eq(after, true, 'and the next one still runs')
  off()

  events.on('Typo', function() end)
  H.eq(H.noted('unknown event `Typo`'), true, 'an unknown name warns')
  events.define('Custom')
  local n = #H.notes
  events.on('Custom', function() end)
  H.eq(#H.notes, n, 'a defined name does not')

  local later, pack
  vim.api.nvim_create_autocmd('User', {
    pattern = 'CinchLater',
    callback = function()
      later = true
    end,
  })
  vim.api.nvim_create_autocmd('User', {
    pattern = 'CinchPack',
    callback = function()
      pack = true
    end,
  })
  events.emit('Later')
  events.emit('Pack', {})
  H.eq(later, true, 'public events fire User autocmds')
  H.eq(pack, nil, 'disk events do not')

  H.eq(events.has('Activity'), false, 'has() is false with no subscriber')
end)
