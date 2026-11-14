-- cinch.now, cinch.later and cinch.now_if_args: your own functions on the same
-- schedule as plugins. Order, the later queue shared with plugins, errors, the log.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

local order = {}
local function mark(name)
  return function()
    order[#order + 1] = name
  end
end

-- Before setup(): these wait for the startup pass.
cinch.now(function()
  order[#order + 1] = 'now before setup, early is ' .. H.plugin('early').state
end)
cinch.later(mark('later before setup'))

cinch.setup({
  confirm = false,
  spec = { { { H.src('early'), load = 'now' }, { H.src('beta.nvim') } } },
})

-- After setup(): now runs at once; later joins the queue behind beta.nvim.
cinch.now(mark('now after setup'))
cinch.later(function()
  order[#order + 1] = 'later after setup, beta is ' .. H.plugin('beta.nvim').state
end)
cinch.later(function()
  error('broken on purpose')
end)
cinch.later(mark('later after the broken one'))
-- Started without a file argument: now_if_args is later.
cinch.now_if_args(mark('now_if_args'))
-- An add() after setup(), then something that runs the event loop, as a second
-- install does: the later queue still waits for startup to end.
cinch.add({ { H.src('alpha.nvim') } }, { confirm = false })
vim.wait(50)
local beta_at_end_of_init = H.plugin('beta.nvim').state
local at_end_of_init = vim.deepcopy(order)

H.after_startup(function()
  H.wait(function()
    return #order == 6
  end, 'every function to run')
  H.eq(at_end_of_init, { 'now before setup, early is loaded', 'now after setup' }, 'now: during init.lua')
  H.eq(beta_at_end_of_init, 'pending', 'an add() during init.lua does not start the later queue early')
  H.eq(order, {
    'now before setup, early is loaded',
    'now after setup',
    'later before setup',
    'later after setup, beta is loaded',
    'later after the broken one',
    'now_if_args',
  }, 'later: after startup, in call order, behind the plugins armed before them')
  H.eq(H.noted('later function at schedule%.lua:%d+ failed: .*broken on purpose'), true, 'an error says where')

  local steps = vim.tbl_filter(function(l)
    return l.msg:find('^ran your function at schedule%.lua:%d+') ~= nil
  end, require('cinch.features.messages').log)
  H.eq(#steps, 6, 'each one that ran is in the log')
  cinch.now(mark('now after startup'))
  H.eq(order[#order], 'now after startup', 'now after startup runs at once')
end)
