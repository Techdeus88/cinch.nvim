-- setup() options of the wrong type: a message from cinch for each, and the default
-- in its place, never a Lua error.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

---@diagnostic disable: assign-type-mismatch
local ok, err = pcall(cinch.setup, {
  confirm = false,
  budget = 'five',
  build_timeout = false,
  defer = 'yes',
  disable_runtime = 'gzip',
  cmd_prefix = 7,
  stats = 'on',
  spec = { { { H.src('alpha.nvim'), load = 'now' } } },
})

H.after_startup(function()
  H.eq({ ok, err }, { true }, 'setup() does not raise')
  H.eq(H.noted('setup%(%): `budget` should be a number, got string; using 5'), true, 'a wrong type is named')
  H.eq(H.noted('setup%(%): `build_timeout` should be a number, got boolean; using 300'), true, 'each of them')
  H.eq(H.noted('setup%(%): `defer` should be a boolean, got string; using true'), true, 'with its default')
  H.eq(H.noted('setup%(%): `disable_runtime` should be a table, got string; using {}'), true, 'a table too')
  H.eq(H.noted('setup%(%): `cmd_prefix` should be a string, got number; using "Cinch"'), true, 'and a string')
  H.eq(H.noted('setup%(%): `stats` should be a table, got string; using {}'), true, "and a feature's options")
  H.eq(H.noted('`confirm`'), false, 'a right one is not')
  H.eq({ cinch.opts.budget, cinch.opts.build_timeout, cinch.opts.defer }, { 5, 300, true }, 'the defaults are used')
  H.eq(H.plugin('alpha.nvim').state, 'loaded', 'and setup() goes on')
  H.eq(vim.fn.exists(':Cinch'), 2, 'with the default command')
end)
