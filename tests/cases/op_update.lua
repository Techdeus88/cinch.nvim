-- Updates in the window: applying shows a header with the progress and a line that
-- says how it ended, here and in messages, with a restart only when a loaded plugin
-- moved. `:Cinch update!` opens the window; a restore from the lockfile is not framed.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local alpha_src, alpha_dir = H.own('alpha.nvim')
local beta_src, beta_dir = H.own('beta.nvim')
local gamma_src, gamma_dir = H.own('gamma')

require('cinch').setup({
  confirm = false,
  spec = { { { alpha_src, load = 'now' }, { beta_src, cmd = 'BetaGo' }, { gamma_src, cmd = 'GammaGo' } } },
})

H.after_startup(function()
  local u, ui, events = require('cinch.features.updates'), require('cinch.features.ui'), require('cinch.events')
  local function check()
    u.check()
    H.wait(function()
      return not u.checking
    end, 'the check')
  end
  local function lines()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ui.windows().list), 0, -1, false)
  end
  local seen = {}
  events.on('Updating', function()
    seen.updating = ui.is_open() and lines()[1]
  end, { priority = 90 })

  local rows = require('cinch.features.ui.rows')
  local alpha = H.plugin('alpha.nvim')
  alpha.activity = 'updating'
  H.eq(rows.section_of(alpha), 'loaded', 'an updating plugin stays in its section')
  H.eq(rows.message(alpha), 'updating…', 'saying what it is doing')
  alpha.activity = nil

  H.commit(alpha_dir, 'feat: one')
  H.commit(beta_dir, 'feat: two')
  vim.cmd('Cinch')
  check()
  vim.wait(1300)

  -- U: everything pending, a loaded plugin among them.
  vim.api.nvim_feedkeys('U', 'x', false)
  H.eq(seen.updating:find('^ Updating plugins %(0/2%)') ~= nil, true, 'the header: ' .. tostring(seen.updating))
  vim.wait(50)
  local ended = 'Updated 2 of 2 plugins in [%d.]+m?s · restart to use them'
  H.eq(lines()[1]:find('^ ' .. ended) ~= nil, true, 'how it ended: ' .. lines()[1])
  H.eq(H.noted(ended), true, 'and in messages')
  vim.wait(1300)
  H.eq(table.concat(lines(), '\n'):find('Updated', 1, true), nil, 'the ending goes after a moment')

  -- u on a plugin that is not loaded: no restart.
  H.commit(beta_dir, 'feat: three')
  check()
  u.apply({ 'beta.nvim' })
  H.eq(H.noted('Updated 1 of 1 plugin in [%d.]+m?s$'), true, 'no restart for a plugin not loaded')

  -- A plugin vim.pack does not know fails, and is counted.
  u.apply({ 'beta.nvim', 'nope' })
  H.eq(H.noted('Updated 0 of 2 plugins in [%d.]+m?s · 2 failed'), true, 'failures are counted')

  -- :Cinch update! opens the window.
  vim.wait(1300)
  ui.close()
  H.commit(gamma_dir, 'feat: four')
  seen.updating = nil
  vim.cmd('Cinch update! gamma')
  H.eq(seen.updating ~= nil and seen.updating:find('Updating plugins', 1, true) ~= nil, true, 'it opens the window')
  H.eq(H.noted('Updated 1 of 1 plugin'), true, 'and says how it ended')

  -- A restore from the lockfile is not framed.
  seen.updating = 'none'
  require('cinch').update({ 'gamma' }, { force = true, target = 'lockfile' })
  H.eq(seen.updating, 'none', 'no header for a restore')
end)
