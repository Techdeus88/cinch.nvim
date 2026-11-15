-- setup({ spec = 'plugins' }): one root, given bare.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

H.write('lua/plugins/a.lua', { ("return { { '%s', load = 'now' } }"):format(H.src('alpha.nvim')) })
---@diagnostic disable-next-line: assign-type-mismatch
local ok, err = pcall(require('cinch').setup, { confirm = false, spec = 'plugins' })

H.after_startup(function()
  H.eq({ ok, err }, { true }, 'setup() takes a string')
  H.eq(H.plugin('alpha.nvim').state, 'loaded', 'and reads the specs under it')
end)
