-- `event = 'VeryLazy'` as a string means what `{ 'VeryLazy' }` does: a plugin that
-- only loads when something asks for it, `lazy = true` say, still loads later.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

cinch.setup({
  confirm = false,
  features = {},
  spec = {
    {
      { H.src('alpha.nvim'), lazy = true, event = 'VeryLazy' },
      { H.src('beta.nvim'), load = 'trigger', event = 'VeryLazy' },
    },
  },
})

H.after_startup(function()
  for _, name in ipairs({ 'alpha.nvim', 'beta.nvim' }) do
    local p = H.plugin(name)
    H.wait(function()
      return p.state == 'loaded'
    end, name .. ' to load later')
    H.eq(p.reason, 'later', name .. ': later loads it')
  end
end)
