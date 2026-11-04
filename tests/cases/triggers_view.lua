-- features/ui/triggers.lua: the Triggers view. Armed triggers first, with who waits;
-- then the ones done with, fired or never fired; then the now and later queues,
-- now_if_args among them, and the plugins that load only with what needs them.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = {
    {
      { H.src('alpha.nvim'), cmd = 'AlphaCmd' },
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
  vim.api.nvim_exec_autocmds('User', { pattern = 'BetaGo' })
  require('cinch').load('delta.nvim')

  local lines =
    require('cinch.features.ui.triggers').view(100, { folded = {}, tick = 0, info = {}, spec_lines = {} }).lines
  local text = table.concat(lines, '\n')
  local armed, done, now, later, deps =
    at(lines, '^ ▾ armed 1'),
    at(lines, '^ ▾ done 3'),
    at(lines, ' now 1'),
    at(lines, ' later 1'),
    at(lines, ' dependencies 1')
  H.eq(
    { armed ~= nil, done ~= nil, now ~= nil, later ~= nil, deps ~= nil },
    { true, true, true, true, true },
    'every section'
  )
  H.eq(armed < done and done < now and now < later and later < deps, true, 'armed first, then done, then the queues')

  H.eq(text:find('cmd AlphaCmd  1 waiting\n +○ alpha%.nvim') ~= nil, true, 'an armed trigger and who waits on it')
  H.eq(
    text:find('event User BetaGo  fired at [%d.]+m?s\n +● beta%.nvim loaded at') ~= nil,
    true,
    'one that fired, when'
  )
  H.eq(
    text:find('ft cnc  never fired\n +● gamma loaded dep of delta%.nvim') ~= nil,
    true,
    'one that never fired, and why'
  )
  H.eq(
    text:find('keys gD %(n, x%)  never fired\n +● delta%.nvim loaded by hand') ~= nil,
    true,
    'a key, with its modes'
  )
  H.eq(text:find('● early loaded at') ~= nil, true, 'the now queue')
  H.eq(text:find('● twomods now_if_args loaded at') ~= nil, true, 'now_if_args, in the queue it became')
  H.eq(
    text:find('dependencies 1  load before what needs them\n +● cmdy loaded dep of delta%.nvim') ~= nil,
    true,
    'deps'
  )

  local folded = require('cinch.features.ui.triggers').view(
    100,
    { folded = { ['triggers:done'] = true }, tick = 0, info = {}, spec_lines = {} }
  ).lines
  H.eq(table.concat(folded, '\n'):find('BetaGo', 1, true), nil, 'a section folds')
end)
