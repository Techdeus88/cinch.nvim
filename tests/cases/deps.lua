-- Dependencies and the loader: a build anywhere below holds the load back, a
-- dependency that cannot load fails its dependent, completing a waiting command
-- neither recurses nor piles up waits, and an async build that never ends times out.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')
local asked = 0
require('cinch.events').on('LoadPre', function(d)
  if d.plugin.name == 'cmdy' then
    asked = asked + 1
    d.cancel, d.cancel_reason = true, 'not now'
  end
end)

cinch.setup({
  confirm = false,
  build_timeout = 1,
  spec = {
    {
      -- alpha needs beta, which needs gamma, which is still building.
      { H.src('alpha.nvim'), cmd = 'AlphaCmd', deps = { 'beta.nvim' } },
      { H.src('beta.nvim'), cmd = 'BetaGo', deps = { 'gamma' } },
      { H.src('gamma'), cmd = 'GammaGo', build = 'sleep 0.6' },
      -- delta needs a disabled plugin.
      { H.src('early'), enabled = false },
      { H.src('delta.nvim'), cmd = 'DeltaGo', deps = { 'early' } },
      -- Its loads are cancelled, so its command stays a stub.
      { H.src('cmdy'), cmd = 'CmdyGo' },
      -- An async build that never calls done().
      { H.src('twomods'), cmd = 'TwoGo', build = function(_, _) end },
    },
  },
})

H.after_startup(function()
  local alpha, beta, gamma = H.plugin('alpha.nvim'), H.plugin('beta.nvim'), H.plugin('gamma')
  H.eq(gamma.activity, 'building', 'gamma builds')

  -- Completing the command asks for the load; the stub must not ask itself again.
  H.eq(vim.fn.getcompletion('AlphaCmd ', 'cmdline'), {}, 'completion while it waits: nothing')
  H.eq({ vim.fn.getcompletion('CmdyGo ', 'cmdline'), asked }, { {}, 1 }, 'a cancelled load: asked once, no recursion')
  vim.fn.getcompletion('AlphaCmd a', 'cmdline')
  H.eq(alpha.state, 'pending', 'alpha waits for a build two levels down')
  H.eq(beta.state, 'pending', 'and so does beta')
  local waits = vim.tbl_filter(function(l)
    return l.msg:find('alpha%.nvim waits for the build') ~= nil
  end, require('cinch.features.messages').log)
  H.eq(#waits, 1, 'asked twice, it waits once')

  H.wait(function()
    return alpha.state == 'loaded'
  end, 'alpha once the build ends')
  H.eq({ gamma.state, beta.state }, { 'loaded', 'loaded' }, 'with what it needs')
  H.eq(gamma.order < beta.order and beta.order < alpha.order, true, 'deepest first')

  local delta = H.plugin('delta.nvim')
  cinch.load('delta.nvim')
  H.eq(delta.state, 'failed', 'a dependency that cannot load fails its dependent')
  H.eq(delta.err, 'dependency `early` is disabled', 'and says why')
  H.eq(vim.api.nvim_get_commands({}).DeltaGo, nil, 'its trigger is gone, so it does not try again')

  local two = H.plugin('twomods')
  H.wait(function()
    return two.activity == nil
  end, 'the async build to time out', 3000)
  H.eq(H.noted('build of `twomods` failed: did not call done%(%) within 1s'), true, 'it fails after build_timeout')
end)
