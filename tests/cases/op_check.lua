-- An update check in the window: it never opens it; while it is open the header shows
-- the progress, rows stay in their section saying they are checking, and a line says
-- how it ended, then goes. Messages get the same line only when you asked for the check.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local alpha_src, alpha_dir = H.own('alpha.nvim')
local beta_src = H.own('beta.nvim')
local gamma_src, gamma_dir = H.own('gamma')

require('cinch').setup({ confirm = false, spec = { { { alpha_src }, { beta_src, cmd = 'BetaGo' }, { gamma_src } } } })

H.after_startup(function()
  local u, ui = require('cinch.features.updates'), require('cinch.features.ui')
  local function idle()
    H.wait(function()
      return not u.checking
    end, 'the check')
  end
  local function lines()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ui.windows().list), 0, -1, false)
  end
  local function text()
    return table.concat(lines(), '\n')
  end
  local counts = {}
  require('cinch.events').on('Progress', function(d)
    if d.title == 'Checking plugins' then
      counts[#counts + 1] = d.done
    end
  end)

  -- Closed: it stays closed, and a check you did not ask for says nothing.
  u.check()
  H.eq(ui.is_open(), false, 'a check never opens the window')
  idle()
  H.eq(H.noted('Checked'), false, 'a background check is quiet')
  H.eq(counts, { 1, 2, 3 }, 'progress counts each plugin')

  vim.cmd('Cinch')
  idle()
  vim.wait(1300)
  H.commit(alpha_dir, 'feat: one')
  vim.fn.rename(gamma_dir, gamma_dir .. '-gone')
  u.check(nil, { notify = true })
  H.wait(function()
    return text():find('checking…', 1, true) ~= nil
  end, 'rows to say they are checking')
  H.eq(H.header()[2]:find(' Checking plugins %(%d/3%)') ~= nil, true, 'the header: ' .. H.header()[2])
  H.eq(text():find('▾ working', 1, true), nil, 'rows stay in their section')
  H.eq(text():find('▾ loaded', 1, true) ~= nil, true, 'loaded is still there')

  idle()
  vim.wait(50)
  local ended = 'Checked 3 plugins in [%d.]+m?s · 1 update · 1 failed'
  H.eq(H.header()[2]:find(' ' .. ended) ~= nil, true, 'how it ended: ' .. H.header()[2])
  H.eq(H.noted(ended), true, 'the same line in your messages')
  H.eq(text():find('checking…', 1, true), nil, 'the rows are done')
  vim.wait(1300)
  H.eq(H.header()[2]:find('Checked', 1, true), nil, 'the ending goes after a moment')
  H.eq(lines()[1], ' ▾ Updates (1)', 'and the list starts with what it found')
end)
