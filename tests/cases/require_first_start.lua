-- On a first start the batch waits for the UI, so a require before it fails, and a
-- require after the install loads the plugin.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')
cinch.ui_coming = function()
  return true
end

cinch.setup({ confirm = false, features = {}, spec = { { { H.src('modly'), cmd = 'ModlyGo' } } } })

local ok, err = pcall(require, 'modly')
H.eq(ok, false, 'not on disk yet')
H.eq(err:find("`modly` provides 'modly' but is not installed", 1, true) ~= nil, true, err)
H.eq(H.plugin('modly').state, 'registered', 'and it still waits')

H.after_startup(function()
  vim.api.nvim_exec_autocmds('UIEnter', {})
  H.wait(function()
    return H.plugin('modly').state == 'pending'
  end, 'the install')
  H.eq(require('modly').name, 'modly', 'the install forgot what the first scan saw')
  H.eq(H.plugin('modly').state, 'loaded', 'and it loaded')
end)
