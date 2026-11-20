-- The public pieces: cinch.updates(), stats() and messages(), the User CinchUpdates and
-- CinchMessage autocmds, and cinch.components for a statusline, winbar or dashboard.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local alpha_src, alpha_dir = H.own('alpha.nvim')

local cinch = require('cinch')
cinch.setup({ confirm = false, spec = { { { alpha_src }, { H.src('beta.nvim') } } } })

H.after_startup(function()
  local c = require('cinch.components')
  local u = require('cinch.features.updates')
  H.wait(function()
    return not u.checking
  end, 'any check')

  H.eq(cinch.updates().count, 0, 'no updates before a check finds one')
  H.eq({ c.updates_text(), c.updates() }, { '', '' }, 'and the component shows nothing')

  local seen = {}
  vim.api.nvim_create_autocmd('User', {
    pattern = { 'CinchUpdates', 'CinchMessage' },
    callback = function(ev)
      seen[ev.match] = ev.data
    end,
  })
  H.commit(alpha_dir, 'feat: newer')
  u.check()
  H.wait(function()
    return not u.checking
  end, 'the check')
  local ups = cinch.updates()
  H.eq({ ups.count, ups.plugins['alpha.nvim'] ~= nil }, { 1, true }, 'cinch.updates() has what it found')
  ups.plugins['alpha.nvim'] = nil
  H.eq(cinch.updates().count, 1, 'a copy: changing it changes nothing')
  H.eq(c.updates_text(), '↑ 1 update', 'the component says how many')
  H.eq(seen.CinchUpdates and seen.CinchUpdates.count, 1, 'User CinchUpdates fires with the count')
  local bar = c.updates()
  H.eq(bar:find('%@v:lua.cinch_open_updates@', 1, true) ~= nil, true, 'clickable in a statusline')
  H.eq(vim.api.nvim_eval_statusline(bar, {}).str, '↑ 1 update', 'and it draws as its text')

  -- A click asks on the rows, like :Cinch update.
  cinch.opts.confirm = true
  c.open_updates()
  vim.wait(50)
  local w = require('cinch.features.ui').windows()
  local list = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w.list), 0, -1, false), '\n')
  H.eq(list:find('Update alpha.nvim Yes (y) or No (n)', 1, true) ~= nil, true, 'opening asks on the row')
  H.press('n')

  local stats = assert(cinch.stats({ history = true }))
  H.eq(
    { stats.plugins.total, type(stats.history), stats.startup.vimenter ~= nil },
    { 2, 'table', true },
    'cinch.stats(): counts, startup times, and past sessions when asked'
  )
  H.eq(cinch.stats().history, nil, 'which it reads only when asked')
  H.eq(c.startup_text():find('^startup [%d.]+m?s') ~= nil, true, 'the startup time: ' .. c.startup_text())

  require('cinch.events').report('careful now', vim.log.levels.WARN)
  local warns = cinch.messages({ level = vim.log.levels.WARN })
  H.eq(warns[#warns].msg, 'careful now', 'cinch.messages() reads the log, filtered by level')
  H.eq(#cinch.messages() >= #warns, true, 'and all of it without a filter')
  warns[#warns].msg = 'changed'
  local again = cinch.messages({ level = vim.log.levels.WARN })
  H.eq(again[#again].msg, 'careful now', 'a copy: changing it changes nothing')
  H.eq(seen.CinchMessage and seen.CinchMessage.msg, 'careful now', 'User CinchMessage fires with it')
end)
