-- features/messages.lua: vim.pack's output is captured while cinch calls it, shown as
-- cinch's own, logged, and released afterwards; other messages pass through.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local echoed = {}
local echo = vim.api.nvim_echo
---@diagnostic disable-next-line: duplicate-set-field
vim.api.nvim_echo = function(chunks, history, opts)
  local text = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, chunks))
  echoed[#echoed + 1] = { source = opts and opts.source, text = text, starting = vim.v.vim_did_enter == 0 }
  return echo(chunks, history, opts)
end
local my_echo, my_notify = vim.api.nvim_echo, vim.notify

require('cinch').setup({ confirm = false, spec = { { { H.src('alpha.nvim') }, { H.src('missing') } } } })

H.after_startup(function()
  local m = require('cinch.features.messages')
  local sources = {}
  for _, e in ipairs(echoed) do
    sources[e.source or 'none'] = true
  end
  H.eq(sources['vim.pack'], nil, "vim.pack's progress never reaches the screen as its own")
  H.eq(sources.cinch, true, "it shows as cinch's")
  local during_init = vim.tbl_filter(function(e)
    return e.starting
  end, echoed)
  H.eq(during_init, {}, 'nothing echoed while init.lua runs, so no Press ENTER prompt')
  local after = table.concat(
    vim.tbl_map(function(e)
      return e.text
    end, echoed),
    '\n'
  )
  H.eq(after:find('not installed', 1, true), nil, 'the install error never reaches the command line')
  H.wait(function()
    return (H.header()[2] or ''):find('not installed: missing', 1, true) ~= nil
  end, 'the install error in the header of the window it opened')
  H.eq({ vim.api.nvim_echo == my_echo, vim.notify == my_notify }, { true, true }, 'both are released after')

  local err
  for _, l in ipairs(m.log) do
    if l.msg:find('^not installed') then
      err = l.msg
    end
  end
  H.eq(err ~= nil and err:find('%.lua:%d+:') == nil, true, 'errors are logged without Lua file:line noise')

  local events = require('cinch.events')
  events.emit('PackOpPre', { op = 'get' })
  vim.notify('vim.pack: Removed plugin: foo', vim.log.levels.INFO)
  vim.notify('warning: redirecting to x', vim.log.levels.WARN)
  vim.notify('not ours')
  events.emit('PackOp', { op = 'get', ok = true, ms = 1 })
  vim.wait(30)
  local notices = vim.tbl_filter(function(l)
    return l.level > vim.log.levels.DEBUG
  end, m.log)
  local tail = vim.tbl_map(function(l)
    return l.source .. ' ' .. l.msg
  end, vim.list_slice(notices, #notices - 1))
  H.eq(tail, { 'vim.pack Removed plugin: foo', 'git warning: redirecting to x' }, 'notices and git warnings are logged')
  H.eq(H.noted('^not ours$'), true, 'everything else passes through')

  local steps = {}
  for _, l in ipairs(m.log) do
    if l.level == vim.log.levels.DEBUG then
      steps[l.source .. ' ' .. l.msg:gsub(' · .*', '')] = l.plugin or true
    end
  end
  H.eq(steps['install installed alpha.nvim'], 'alpha.nvim', 'installs are logged, with their plugin')
  H.eq(steps['state alpha.nvim waits for later, after startup'] ~= nil, true, 'what each plugin waits for')
  H.eq(steps['later loaded alpha.nvim by later'] ~= nil, true, 'loads, by what loaded them')
  H.eq(steps['vim.pack vim.pack.add 2 plugins'] ~= nil, true, 'vim.pack calls')
end)
