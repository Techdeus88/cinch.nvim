-- features/ui: start_tall and start_even open the window as `-` and `=` leave it, and
-- the keys still switch back.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local api = vim.api

require('cinch').setup({
  confirm = false,
  spec = { { { H.src('alpha.nvim') } } },
  ui = { start_tall = true, start_even = true },
})

H.after_startup(function()
  -- Wide enough for the pane beside the list: 150 columns at 75%.
  vim.o.columns = 200
  vim.cmd('Cinch')
  local w = require('cinch.features.ui').windows()
  local lines_h = vim.o.lines - vim.o.cmdheight
  local function height()
    local head, foot = api.nvim_win_get_config(w.header), api.nvim_win_get_config(w.footer)
    return foot.row + foot.height + 2 - head.row
  end
  local function widths()
    return { api.nvim_win_get_config(w.list).width + 2, api.nvim_win_get_config(w.pane).width + 2 }
  end
  H.eq(height(), math.floor(lines_h * 0.95), 'start_tall opens it 95% tall')
  H.eq(widths(), { 75, 75 }, 'start_even opens the list and the pane 50/50')
  H.press('-')
  H.eq(height(), math.floor(lines_h * 0.75), '- goes back to 75%')
  H.press('=')
  H.eq(widths(), { 105, 45 }, '= goes back to 70/30')
end)
