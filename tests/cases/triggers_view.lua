-- features/ui/triggers.lua: the Triggers view. The list has a row per trigger by
-- kind, waiting ones first, a dot per plugin; then the schedule. The pane explains
-- the trigger under the cursor and lists what it loads, and `l` loads what waits.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local api = vim.api

require('cinch').setup({
  confirm = false,
  spec = {
    {
      { H.src('alpha.nvim'), cmd = 'AlphaCmd', event = 'BufReadPre' },
      { H.src('beta.nvim'), event = 'User BetaGo' },
      { H.src('gamma'), ft = 'cnc' },
      { H.src('delta.nvim'), keys = { { 'gD', mode = { 'n', 'x' } } }, deps = { 'gamma', H.src('cmdy') } },
      { H.src('early'), load = 'now' },
      { H.src('twomods'), load = 'now_if_args' },
    },
  },
})

---@param lines string[]
---@param pat string
---@return integer?
local function at(lines, pat)
  for i, l in ipairs(lines) do
    if l:find(pat) then
      return i
    end
  end
end

H.after_startup(function()
  api.nvim_exec_autocmds('User', { pattern = 'BetaGo' })
  require('cinch').load('delta.nvim')
  local view = require('cinch.features.ui.triggers')
  local ctx = { folded = {}, tick = 0, info = {}, spec_lines = {} }

  local c = view.list(100, ctx)
  local lines = c.lines
  local ev, ft, cmd, keys, sched =
    at(lines, ' events 2'),
    at(lines, ' filetypes 1'),
    at(lines, ' commands 1'),
    at(lines, ' keys 1'),
    at(lines, ' schedule 3')
  H.eq(
    { ev ~= nil, ft ~= nil, cmd ~= nil, keys ~= nil, sched ~= nil },
    { true, true, true, true, true },
    'a section per kind'
  )
  H.eq(
    ev < ft and ft < cmd and cmd < keys and keys < sched,
    true,
    'events, filetypes, commands, keys, then the schedule'
  )
  H.eq(lines[ev + 1]:find('○ BufReadPre ○ 1 waiting') ~= nil, true, 'waiting first: a light, a dot per plugin')
  H.eq(lines[ev + 2]:find('● User BetaGo ● fired at') ~= nil, true, 'then fired, with when')
  H.eq(lines[ft + 1]:find('◌ cnc ● never fired') ~= nil, true, 'one its plugins outran')
  H.eq(lines[cmd + 1]:find(':AlphaCmd ○ 1 waiting') ~= nil, true, 'a command, as you type it')
  H.eq(lines[keys + 1]:find('gD n x ● never fired') ~= nil, true, 'a key, with its modes')
  H.eq(c.rows[cmd + 1], 'cmd AlphaCmd', 'each row knows its trigger')

  -- The pane: what it is, when it fires, what it loads.
  local pane = table.concat(view.pane('cmd AlphaCmd', 80).lines, '\n')
  H.eq(pane:find('cmd :AlphaCmd') ~= nil, true, 'the trigger')
  H.eq(pane:find('runs +When you run :AlphaCmd%.') ~= nil, true, 'when it fires, in words')
  H.eq(pane:find('help +:h user%-commands') ~= nil, true, 'and where to read more')
  H.eq(pane:find('○ alpha%.nvim  waiting\n +also .*BufReadPre') ~= nil, true, 'its plugin, and what else loads it')
  local event = table.concat(view.pane('event BufReadPre', 80).lines, '\n')
  H.eq(event:find('When a file starts loading into a buffer') ~= nil, true, 'a known event, explained')
  local never = table.concat(view.pane('ft FileType cnc', 80).lines, '\n')
  H.eq(never:find('note +It never fired') ~= nil, true, 'one that never fired says so')
  H.eq(never:find('● gamma %([%d.]+m?s%)  loaded dep of delta%.nvim') ~= nil, true, 'and how its plugin loaded')
  local now = table.concat(view.pane('queue now', 80).lines, '\n')
  H.eq(
    now:find('During startup') ~= nil and now:find('took +[%d.]+m?s of your startup') ~= nil,
    true,
    'now, and its cost'
  )
  local later = table.concat(view.pane('queue later', 80).lines, '\n')
  H.eq(later:find('twomods now_if_args') ~= nil, true, 'now_if_args, in the queue it became')
  local deps = table.concat(view.pane('queue dep', 80).lines, '\n')
  H.eq(deps:find('cmdy') ~= nil, true, 'dependencies')

  -- In the window: the pane follows the cursor, and l loads what waits.
  vim.cmd('Cinch open triggers')
  local w = require('cinch.features.ui').windows()
  local list = api.nvim_buf_get_lines(api.nvim_win_get_buf(w.list), 0, -1, false)
  api.nvim_win_set_cursor(w.list, { assert(at(list, ':AlphaCmd')), 0 })
  api.nvim_exec_autocmds('CursorMoved', { buffer = api.nvim_win_get_buf(w.list) })
  vim.wait(20)
  local shown = api.nvim_buf_get_lines(api.nvim_win_get_buf(w.pane), 0, -1, false)
  H.eq(shown[1]:find('cmd :AlphaCmd', 1, true) ~= nil, true, 'the pane follows the cursor')
  H.press('l')
  H.eq(H.plugin('alpha.nvim').state, 'loaded', 'l loads what waits on the trigger')

  local folded = view.list(100, { folded = { ['triggers:event'] = true }, tick = 0, info = {}, spec_lines = {} })
  H.eq(table.concat(folded.lines, '\n'):find('BetaGo', 1, true), nil, 'a section folds')
end)
