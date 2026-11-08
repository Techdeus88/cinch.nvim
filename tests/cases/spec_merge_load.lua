-- Merged specs in a real session: setup() gets merged opts, a later spec can disable a
-- plugin, and add() merges into a pending or disabled plugin, not a loaded one.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

cinch.setup({
  confirm = false,
  spec = {
    {
      { H.src('alpha.nvim'), load = 'now', opts = { a = 1, nested = { x = 1, y = 1 } } },
      { H.src('alpha.nvim'), opts = { nested = { y = 2 } } },
      { H.src('beta.nvim'), cmd = 'BetaGo' },
      { H.src('beta.nvim'), enabled = false },
      { H.src('delta.nvim'), cmd = 'DeltaOld' },
      { H.src('modly'), cmd = 'ModlyGo' },
      { H.src('twomods'), cmd = 'TwoGo' },
      { H.src('early'), enabled = false },
      { H.src('dup-first'), cmd = 'DupGo' },
    },
  },
})

H.after_startup(function()
  H.eq(vim.g.alpha_opts, { a = 1, nested = { x = 1, y = 2 } }, 'setup() got the merged opts')
  H.eq(H.plugin('alpha.nvim').opts_used, { a = 1, nested = { x = 1, y = 2 } }, 'and the record says so')
  H.eq(H.plugin('beta.nvim').state, 'disabled', 'a later spec can turn it off')
  H.eq(vim.api.nvim_get_commands({}).BetaGo, nil, 'with no stub left behind')

  -- Pending, and armed by its first spec.
  local delta = H.plugin('delta.nvim')
  H.eq(vim.api.nvim_get_commands({}).DeltaOld ~= nil, true, 'the old stub is there')
  H.eq(cinch.add({ { H.src('delta.nvim'), cmd = 'DeltaNew' } }, { confirm = false }), {}, 'no new record')
  H.eq(vim.api.nvim_get_commands({}).DeltaOld, nil, 'its stub goes')
  H.eq(vim.api.nvim_get_commands({}).DeltaNew ~= nil, true, 'and the new one is armed')
  H.eq(delta.state, 'pending', 'still waiting')

  cinch.add({ { H.src('modly'), load = 'now' } }, { confirm = false })
  H.eq(H.plugin('modly').state, 'loaded', 'a pending plugin moved to now loads now')
  H.eq(vim.api.nvim_get_commands({}).ModlyGo, nil, 'and its stub is gone')

  cinch.add({ { H.src('twomods'), enabled = false } }, { confirm = false })
  H.eq(H.plugin('twomods').state, 'disabled', 'a pending plugin can be turned off')
  H.eq(vim.api.nvim_get_commands({}).TwoGo, nil, 'with its stub gone')
  H.eq(pcall(require, 'two'), false, 'and require() leaves it off')

  cinch.add({ { H.src('dup-first'), module = false } }, { confirm = false })
  H.eq(pcall(require, 'dupmod'), false, 'module = false merged after the first scan holds')
  H.eq(H.plugin('dup-first').state, 'pending', 'so require() leaves it waiting')

  -- Disabled: merged, and turned on only if a spec says so.
  local early = H.plugin('early')
  cinch.add({
    {
      H.src('early'),
      after = function()
        vim.g.early_after = true
      end,
    },
  }, { confirm = false })
  H.eq(early.state, 'disabled', 'still off: enabled = false is still in the merged spec')
  local added = cinch.add({ { H.src('early'), enabled = true } }, { confirm = false })
  H.eq(added[1], early, 'turned on, it goes through install again')
  H.wait(function()
    return early.state == 'loaded'
  end, 'early to load')
  H.eq(vim.g.early_after, true, 'with what the spec before it merged in')

  -- Too late.
  local notes = #H.notes
  cinch.add({ { H.src('alpha.nvim'), opts = { late = true } } }, { confirm = false })
  H.eq(H.plugin('alpha.nvim').data.opts.late, nil, 'a loaded plugin keeps its spec')
  H.eq(#H.notes > notes, true, 'and says so')
  H.eq(H.noted('`alpha.nvim` already started loading; this spec applies on restart'), true, 'with the fix')
end)
