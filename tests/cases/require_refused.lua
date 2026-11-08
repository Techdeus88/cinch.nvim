-- A plugin that cannot load stays as it is, and the require error says why: disabled,
-- not installed, failed, or asked from a fast event, where :packadd cannot run.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = {
    {
      { H.src('alpha.nvim'), enabled = false },
      { H.src('missing') },
      {
        H.src('beta.nvim'),
        cmd = 'BetaGo',
        config = function()
          error('boom')
        end,
      },
      { H.src('delta.nvim'), cmd = 'DeltaGo' },
    },
  },
})

local function refused(mod, text)
  local ok, err = pcall(require, mod)
  H.eq(ok, false, mod .. ' fails')
  if not err:find(text, 1, true) then
    error(('%s: expected %q in %s'):format(mod, text, err), 2)
  end
end

H.after_startup(function()
  local fast
  vim.uv.new_timer():start(0, 0, function()
    fast = { pcall(require, 'delta') }
  end)
  H.wait(function()
    return fast ~= nil
  end, 'the timer')
  H.eq(fast[1], false, 'a fast event cannot load it')
  H.eq(fast[2]:find("`delta.nvim` provides 'delta' but cannot load in a fast event", 1, true) ~= nil, true, fast[2])
  H.eq(H.plugin('delta.nvim').state, 'pending', 'so it stays pending')
  H.eq(require('delta').hit ~= nil, true, 'and loads on the next require')

  refused('alpha', "`alpha.nvim` provides 'alpha' but is disabled")
  H.eq(H.plugin('alpha.nvim').state, 'disabled', 'stays disabled')

  refused('missing', "`missing` provides 'missing' but is not installed")
  H.eq(H.plugin('missing').state, 'failed', 'stays failed')

  refused('beta', "`beta.nvim` provides 'beta' but failed to load")
  refused('beta.nothing', 'no field package.preload')
  H.eq(H.plugin('beta.nvim').state, 'failed', 'a config that raises fails the plugin')
  H.eq(H.noted('boom'), true, 'and is reported')
  H.eq(require('beta').v, 1, 'a later require finds the module on the runtimepath')
end)
