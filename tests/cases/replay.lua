-- Replaying what woke a plugin: plugins behind one trigger load in declaration
-- order, a `once` autocmd runs once, a command keeps its exact text, and a key in
-- operator-pending mode keeps its operator and register.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local order = {}
local specs = {}
for i = 1, 8 do
  specs[#specs + 1] = {
    src = H.src('gamma'),
    name = 'shared' .. i,
    event = 'User SharedGo',
    config = function()
      order[#order + 1] = i
    end,
  }
end
vim.list_extend(specs, {
  { H.src('oncy'), event = 'User OncyGo' },
  { H.src('alpha.nvim'), cmd = 'AlphaCmd' },
  { H.src('opy'), keys = { { 'L', mode = 'o' } } },
})
require('cinch').setup({ confirm = false, spec = { specs } })

H.after_startup(function()
  vim.api.nvim_exec_autocmds('User', { pattern = 'SharedGo' })
  H.eq(order, { 1, 2, 3, 4, 5, 6, 7, 8 }, 'one trigger, declaration order')

  vim.api.nvim_exec_autocmds('User', { pattern = 'OncyGo' })
  vim.api.nvim_exec_autocmds('User', { pattern = 'OncyGo' })
  H.eq(vim.g.oncy, 1, 'a once autocmd replays once, and is gone')

  vim.cmd([[AlphaCmd! a\ b c]])
  H.eq(vim.g.alpha_cmd, { args = [[a\ b c]], bang = true, range = 0 }, 'a command keeps its exact text')

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hello world', 'two' })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  H.press('"adL')
  H.eq(H.plugin('opy').state, 'loaded', 'the key loads it')
  H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { '', 'two' }, 'the operator applies to the replayed motion')
  H.eq(vim.fn.getreg('a'), 'hello world', 'into the register you named')
end)
