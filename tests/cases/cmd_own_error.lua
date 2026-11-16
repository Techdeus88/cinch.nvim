-- A command whose plugin loads fine but which fails on its own, with a missing
-- argument say: its error shows on the command line as Neovim words it, the Log keeps
-- it, and the window stays closed. That error is the command's, not cinch's.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local api = vim.api

require('cinch').setup({ confirm = false, spec = { { { H.src('argy'), cmd = 'ArgyGo' } } } })

local echoed = {}
local echo = api.nvim_echo
---@diagnostic disable-next-line: duplicate-set-field
api.nvim_echo = function(chunks, history, opts)
  echoed[#echoed + 1] = { text = chunks[1][1], err = opts and opts.err }
  return echo(chunks, history, opts)
end

H.after_startup(function()
  local ui = require('cinch.features.ui')
  H.eq(ui.is_open(), false, 'the window starts closed')
  H.press(':ArgyGo<CR>')
  H.eq(H.plugin('argy').state, 'loaded', 'the plugin loads')
  H.eq(echoed[#echoed], { text = 'E471: Argument required: ArgyGo', err = true }, 'its error, on the command line')
  H.eq(ui.is_open(), false, 'the window stays closed')
  local logged = vim.iter(require('cinch.features.messages').log):find(function(l)
    return l.msg == 'E471: Argument required: ArgyGo'
  end)
  H.eq(logged and { logged.level, logged.source }, { vim.log.levels.ERROR, 'command' }, 'and the Log keeps it')

  vim.cmd('ArgyGo yes')
  H.eq(vim.g.argy, 'yes', 'with an argument it runs')
end)
