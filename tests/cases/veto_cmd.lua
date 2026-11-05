-- A LoadPre veto on a typed command: the command runs once and asks once, is not
-- replayed into its stub, and the stub stays for the next time.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local asked = 0
require('cinch.events').on('LoadPre', function(d)
  if d.plugin.name == 'cmdy' then
    asked = asked + 1
    d.cancel, d.cancel_reason = true, 'not now'
  end
end)

require('cinch').setup({ confirm = false, spec = { { { H.src('cmdy'), cmd = 'CmdyGo' } } } })

H.after_startup(function()
  local ok = pcall(vim.cmd, 'CmdyGo')
  H.eq({ ok, asked, H.plugin('cmdy').state }, { true, 1, 'pending' }, 'a vetoed command: asked once, no replay')
  H.eq(vim.api.nvim_get_commands({}).CmdyGo ~= nil, true, 'its stub stays')
end)
