-- An error raised inside a cinch.time() wrapper is reported with the traceback from
-- where it began, not from the wrapper that raised it again; the error itself is unchanged.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

local deep_line = debug.getinfo(1, 'l').currentline + 2
local function deep()
  error('kaboom')
end

cinch.setup({
  confirm = false,
  spec = {
    { H.src('alpha.nvim'), load = 'now', config = cinch.time('alpha config', function()
      deep()
    end) },
  },
})

local runs = {}
cinch.on('Run', function(d)
  runs[#runs + 1] = d
end)
-- Wrapped twice: the traceback still starts at deep().
cinch.later(cinch.time(
  'outer',
  cinch.time('inner', function()
    deep()
  end)
))
-- Not wrapped: its own traceback, never one kept from another error.
local plain_line = debug.getinfo(1, 'l').currentline + 2
cinch.later(function()
  error('kaboom', 0)
end)

local where = 'timed_trace.lua:' .. deep_line

H.after_startup(function()
  H.wait(function()
    return #runs == 2
  end, 'both later functions to run')

  local err = runs[1].err
  H.eq(err:find(where .. ': kaboom', 1, true) ~= nil, true, 'the message, as raised')
  H.eq(err:find('stack traceback:', 1, true) ~= nil, true, 'with a traceback')
  H.eq(err:find(where .. ': in function', 1, true) ~= nil, true, 'that starts in deep()')
  H.eq(select(2, err:gsub('stack traceback:', '')), 1, 'one traceback, not one per wrapper')

  local plain = runs[2].err
  H.eq(
    plain:find('timed_trace.lua:' .. plain_line .. ': in function', 1, true) ~= nil,
    true,
    'an untimed error: its own'
  )
  H.eq(plain:find(where, 1, true), nil, 'and nothing of deep()')

  local alpha = H.plugin('alpha.nvim')
  H.eq(alpha.state, 'failed', 'its config raised')
  H.eq(alpha.err:find(where .. ': in function', 1, true) ~= nil, true, 'a config hook reports where it began too')

  -- Called directly, the error passes through as it was raised.
  local direct = cinch.time('direct', deep)
  local ok, e = pcall(direct)
  local _, want = pcall(deep)
  H.eq(ok, false, 'still raises')
  H.eq(e, want, 'the same error value')
end)
