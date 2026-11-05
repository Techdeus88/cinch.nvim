-- Startup is measured from when the process began. macOS, Linux and Windows give that
-- from the OS; anywhere the OS read fails, stats falls back to CPU time and says so.
-- This case fails on a platform that falls back, so CI catches a broken read.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({ confirm = false, spec = {} })

H.after_startup(function()
  local stats = require('cinch.features.stats')
  H.eq(stats.source, 'os', 'the OS gave the process start time')
  local ms = stats.now()
  H.eq(ms > 0 and ms < 60000, true, 'Neovim has been up for seconds, not a day (' .. ms .. ' ms)')
end)
