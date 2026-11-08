-- require() has to return now, so a running build fails it, its own or a dependency's.
-- It does not queue a load: the plugin loads on a require after the build.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local waits = 0
require('cinch.events').on('LoadWait', function()
  waits = waits + 1
end)

require('cinch').setup({
  confirm = false,
  spec = {
    {
      { H.src('modly'), cmd = 'ModlyGo', build = 'sleep 0.5' },
      { H.src('twomods'), cmd = 'TwoGo', deps = { 'modly' } },
    },
  },
})

H.after_startup(function()
  local modly, two = H.plugin('modly'), H.plugin('twomods')
  H.eq(modly.activity, 'building', 'its build runs')

  local ok, err = pcall(require, 'modly')
  H.eq(ok, false, 'require during the build fails')
  H.eq(err:find("`modly` provides 'modly' but is still building", 1, true) ~= nil, true, err)

  ok, err = pcall(require, 'two')
  H.eq(ok, false, 'so does a plugin that needs it')
  H.eq(err:find('needs `modly`, which is still building', 1, true) ~= nil, true, err)

  H.eq({ modly.state, two.state, waits }, { 'pending', 'pending', 0 }, 'nothing loaded or queued')

  H.wait(function()
    return modly.activity == nil
  end, 'the build')
  H.eq(modly.state, 'pending', 'the build ending loads nothing')
  H.eq(require('two'), {}, 'after it, require works')
  H.eq({ modly.state, two.state }, { 'loaded', 'loaded' }, 'and loads both')
end)
