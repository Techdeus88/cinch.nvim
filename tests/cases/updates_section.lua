-- The Updates section: on top only while there are updates, each plugin moved into it
-- with how many commits it is behind, one that is failed or working left where it is.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local alpha_src, alpha_dir = H.own('alpha.nvim')
local beta_src, beta_dir = H.own('beta.nvim')
local gamma_src = H.own('gamma')
local delta_src, delta_dir = H.own('delta.nvim')

require('cinch').setup({
  confirm = false,
  spec = {
    {
      { alpha_src },
      { beta_src, cmd = 'BetaGo' },
      { gamma_src },
      {
        delta_src,
        config = function()
          error('boom')
        end,
      },
    },
  },
})

H.after_startup(function()
  local u = require('cinch.features.updates')
  local view = require('cinch.features.ui.plugins')
  local ctx = { folded = {}, tick = 0, info = {}, spec_lines = {} }
  local function list()
    return view.list(100, ctx).lines
  end
  local function text()
    return table.concat(list(), '\n')
  end

  H.wait(function()
    return not u.checking
  end, 'any check from startup')
  u.results = {}
  H.eq(text():find('Updates', 1, true), nil, 'no section with no updates')
  H.eq(text():find('alpha.nvim', 1, true) ~= nil, true, 'and the plugins are in their usual sections')

  H.commit(alpha_dir, 'feat: one')
  H.commit(alpha_dir, 'fix: two')
  H.commit(beta_dir, 'docs: three')
  H.commit(delta_dir, 'docs: four')
  u.check()
  H.wait(function()
    return not u.checking
  end, 'the check')

  H.eq(list()[1], ' ▾ Updates (2)', 'the section is on top, with how many plugins')
  H.eq(list()[2]:find('alpha.nvim 2 commits', 1, true) ~= nil, true, 'two commits')
  H.eq(list()[3]:find('beta.nvim 1 commit$') ~= nil, true, 'one commit')
  H.eq(
    { list()[2]:find('^   %S') ~= nil, list()[3]:find('^   %S') ~= nil },
    { true, true },
    'its rows sit two cells in'
  )
  H.eq(list()[4], '', 'a blank row parts the section from the rest')
  H.eq(list()[5]:find('^ %S') ~= nil, true, 'whose rows are not indented')
  local all = text()
  H.eq(all:find('u updates it', 1, true), nil, 'no hint in the row')
  H.eq(select(2, all:gsub('alpha%.nvim', '')), 1, 'alpha has one row')
  H.eq(select(2, all:gsub('beta%.nvim', '')), 1, 'beta has one row')
  H.eq(all:find('gamma', 1, true) ~= nil, true, 'a plugin with no updates stays out of it')
  H.eq(all:find('delta.nvim.*↑1') ~= nil, true, 'a failed plugin stays where it is, with its arrow')

  ctx.folded.updates = true
  H.eq(list()[1], ' ▸ Updates (2)', 'it folds')
  H.eq(text():find('alpha.nvim', 1, true), nil, 'hiding its rows')
  ctx.folded.updates = nil

  ctx.filter = 'alpha'
  H.eq(list()[2], ' ▾ Updates (1)', 'the filter applies')
  ctx.filter = 'gamma'
  H.eq(text():find('Updates', 1, true), nil, 'no section when nothing matching has updates')
  ctx.filter = nil

  -- What is on disk in no spec joins the section, and is counted.
  ctx.orphans = { { name = 'stray.nvim', path = '/x/stray.nvim', src = 'file:///x/stray' } }
  H.eq(list()[1], ' ▾ Updates (3)', 'counted with the updates')
  H.eq(list()[4], '   · stray.nvim not in specs', 'after them, saying why')
  H.eq(list()[5], '', 'and the blank row comes after it')
  H.eq(text():find('not in your specs', 1, true), nil, 'no section of its own')
  local stray = view.list(100, ctx)
  H.eq(stray.rows[4], 'stray.nvim', 'its row selects it, for `d` and the pane')
  ctx.filter = 'stray'
  H.eq(list()[2], ' ▾ Updates (1)', 'the filter applies to it')
  ctx.filter = nil
  ctx.orphans = nil

  local c = view.list(100, ctx)
  H.eq(c.sections[1], 'updates', 'the header folds like any section')
  H.eq(c.rows[2], 'alpha.nvim', 'and a row selects its plugin, for `u` and the pane')

  u.apply({ 'alpha.nvim', 'beta.nvim' })
  H.wait(function()
    return u.results['alpha.nvim'] == nil and u.results['beta.nvim'] == nil
  end, 'the updates')
  H.eq(text():find('Updates', 1, true), nil, 'the section goes once they are applied')
  H.eq(text():find('\n\n', 1, true), nil, 'and its blank row with it')
  local back = vim.iter(list()):find(function(l) ---@param l string
    return l:find('alpha.nvim', 1, true) ~= nil
  end)
  H.eq(back:find('^ %S') ~= nil, true, 'alpha is back in the list, not indented')
  H.eq(text():find('alpha.nvim', 1, true) ~= nil, true, 'and they go back to their sections')
end)
