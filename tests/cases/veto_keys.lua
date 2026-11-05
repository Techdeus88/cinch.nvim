-- A LoadPre veto on a typed key: the key is not fed back into its stub, so the veto
-- is asked once, and the mapping stays for the next time.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local asked = 0
require('cinch.events').on('LoadPre', function(d)
  if d.plugin.name == 'delta.nvim' then
    asked = asked + 1
    d.cancel, d.cancel_reason = true, 'not now'
  end
end)

require('cinch').setup({ confirm = false, spec = { { { H.src('delta.nvim'), keys = { 'gD' } } } } })

H.after_startup(function()
  vim.api.nvim_feedkeys('gD', 'x', false)
  H.eq({ asked, H.plugin('delta.nvim').state }, { 1, 'pending' }, 'a vetoed key: asked once, not fed back')
  H.eq(vim.fn.maparg('gD', 'n') ~= '', true, 'its mapping stays')
end)
