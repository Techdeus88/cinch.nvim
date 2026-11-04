-- phases: 2
-- A plugin already on disk gets a new dependency that is not. On a start that holds
-- missing plugins back for the UI, the plugin waits with its dependency instead of
-- loading during init.lua without it.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')
cinch.ui_coming = function()
  return true
end

local alpha = { H.src('alpha.nvim'), load = 'now' }
if H.phase == 2 then
  alpha.deps = { 'beta.nvim' }
end
cinch.setup({ confirm = false, spec = { { alpha, H.phase == 2 and { H.src('beta.nvim') } or nil } } })
local at_init = H.plugin('alpha.nvim').state

H.after_startup(function()
  if H.phase == 1 then
    vim.api.nvim_exec_autocmds('UIEnter', {})
    H.wait(function()
      return H.plugin('alpha.nvim').state == 'loaded'
    end, 'alpha on its first start')
    return
  end
  H.eq(at_init, 'registered', 'alpha waits with its new dependency')
  vim.api.nvim_exec_autocmds('UIEnter', {})
  H.wait(function()
    return H.plugin('alpha.nvim').state == 'loaded'
  end, 'alpha, after the install')
  H.eq(H.plugin('beta.nvim').state, 'loaded', 'with beta installed and loaded first')
  H.eq(H.plugin('alpha.nvim').err, nil, 'and no error')
end)
