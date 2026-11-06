-- stats = { profile = 'functions' } times every Lua function that runs during startup
-- and plugin loads, grouped by the plugin it is in, and stops once startup is over.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  stats = { profile = 'functions' },
  spec = {
    {
      {
        H.src('beta.nvim'),
        config = function()
          local function busy(n)
            return n > 0 and busy(n - 1) or 0
          end
          for _ = 1, 10 do
            busy(5)
          end
        end,
      },
    },
  },
})

H.after_startup(function()
  local stats = require('cinch.features.stats')
  local funcs
  for _, g in ipairs(stats.profile()) do
    if g.name == 'functions' then
      funcs = g
    end
  end
  H.eq(funcs ~= nil, true, 'a functions group')
  local busy
  for _, owner in ipairs(funcs.children) do
    H.eq(owner.kind, 'owner', 'by where they are')
    for _, f in ipairs(owner.children) do
      if f.label:find('^busy ') then
        busy = f
      end
    end
  end
  H.eq(busy ~= nil, true, 'a function the config called, by its name')
  H.eq(busy.calls, 60, 'with how many times it ran')
  H.eq(busy.total >= busy.ms, true, 'and its time with what it called, at least its own')

  local calls = busy.calls
  local function after() end
  after()
  H.eq(debug.gethook(), nil, 'the hook is off once startup is over')
  H.eq(busy.calls, calls, 'so nothing more is counted')
end)
