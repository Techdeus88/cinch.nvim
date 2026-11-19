-- features/stats.lua: stats.zero = 'init' counts from vim.g.start; without it, the process start.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

vim.g.start = vim.uv.hrtime() - 500e6 -- as if init.lua began 500 ms ago
require('cinch').setup({ confirm = false, spec = {}, stats = { zero = 'init' } })

H.after_startup(function()
  local stats = require('cinch.features.stats')
  H.eq(stats.source, 'init', 'start time from vim.g.start')
  H.eq(stats.marks.setup >= 500 and stats.marks.setup < 2000, true, 'setup counted from vim.g.start')
end)
