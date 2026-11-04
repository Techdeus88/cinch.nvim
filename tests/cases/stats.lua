-- phases: 2
-- features/stats.lua: counts, phases, load times, the start time, and history kept across sessions.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = { { { H.src('early'), load = 'now' }, { H.src('beta.nvim') }, { H.src('alpha.nvim'), cmd = 'AlphaCmd' } } },
})

H.after_startup(function()
  local stats = require('cinch.features.stats')
  local s = stats.summary()
  H.eq(s.plugins.total, 3, 'plugins counted')
  H.eq(s.by_when, { now = 1, later = 1, trigger = 1 }, 'by when')
  H.eq(s.loaded_by, { now = 1, later = 1 }, 'by what loaded them')
  for _, phase in ipairs({ 'specs', 'install', 'init', 'now' }) do
    H.eq(type(stats.phases[phase]), 'number', 'phase ' .. phase)
  end
  H.eq(stats.marks.vimenter > 0 and stats.marks.later >= stats.marks.vimenter, true, 'VimEnter, then later done')
  H.eq(stats.source, jit.os == 'Windows' and 'cpu' or 'os', 'start time from the OS')
  H.eq(type(stats.plugins.early.packadd), 'number', 'per-plugin times')
  vim.cmd('Cinch stats')

  local history = stats.history()
  if H.phase == 1 then
    H.eq(#history, 0, 'no history in the first session')
  else
    H.eq(#history, 1, 'the first session was saved at exit')
    H.eq(history[1].plugins, 3, 'with its plugin count')
    H.eq(type(history[1].startup), 'number', 'and startup time')
  end
end)
