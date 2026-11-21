-- The window keeps no columns beside its text, even when a plugin that sets up while it
-- is open decorates every window, as statuscol.nvim does on a first start.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({ confirm = false, spec = { { { H.src('alpha.nvim') } } } })

H.after_startup(function()
  local ui = require('cinch.features.ui')
  vim.o.number = true
  ui.open()
  local wins = ui.windows()
  local names = { 'header', 'list', 'pane', 'footer' }
  ---@return table<string, string> each window's columns, where any is on
  local function columns()
    local on = {}
    for _, k in ipairs(names) do
      local wo = vim.wo[wins[k]]
      if wo.number or wo.relativenumber or wo.statuscolumn ~= '' or wo.signcolumn ~= 'no' or wo.foldcolumn ~= '0' then
        on[k] = ('number=%s stc=%q sign=%s fold=%s'):format(wo.number, wo.statuscolumn, wo.signcolumn, wo.foldcolumn)
      end
    end
    return on
  end
  H.eq(columns(), {}, "opened with no columns, though 'number' is on")

  -- A plugin sets up and decorates every open window.
  for _, k in ipairs(names) do
    vim.wo[wins[k]].number = true
    vim.wo[wins[k]].statuscolumn = '%l '
    vim.wo[wins[k]].signcolumn = 'yes'
  end
  ui.open()
  H.eq(columns(), {}, 'the next redraw takes them off again')
end)
