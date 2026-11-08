-- A LoadPre veto fails the require with its reason and leaves the plugin pending.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local veto = true
require('cinch.events').on('LoadPre', function(d)
  if veto then
    d.cancel, d.cancel_reason = true, 'not now'
  end
end)

require('cinch').setup({ confirm = false, spec = { { { H.src('modly'), cmd = 'ModlyGo' } } } })

H.after_startup(function()
  local ok, err = pcall(require, 'modly')
  H.eq(ok, false, 'a vetoed load fails the require')
  H.eq(err:find("`modly` provides 'modly' but its load was cancelled: not now", 1, true) ~= nil, true, err)
  H.eq(H.plugin('modly').state, 'pending', 'and it stays pending')

  veto = false
  H.eq(require('modly').name, 'modly', 'with the veto lifted it loads')
end)
