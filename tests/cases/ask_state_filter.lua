-- phases: 2
-- A state filter on the Plugins list does not hide the rows a question asks on, and
-- Neovim's own prompt never takes over.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local api = vim.api
local phase = tonumber(vim.env.CINCH_PHASE)

local specs = { { H.src('alpha.nvim') } }
if phase == 1 then
  specs[#specs + 1] = { H.src('delta.nvim') }
end
require('cinch').setup({ confirm = false, spec = { specs } })

local prompts = 0
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.confirm = function()
  prompts = prompts + 1
  return 2
end

---@param text string
---@return boolean
local function shows(text)
  local w = require('cinch.features.ui').windows()
  local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(w.list), 0, -1, false)
  return table.concat(lines, '\n'):find(text, 1, true) ~= nil
end

H.after_startup(function()
  if phase == 1 then
    return
  end
  require('cinch').opts.confirm = true
  vim.cmd('Cinch')
  H.press('2')
  vim.cmd('Cinch clean')
  H.eq(shows(' · Delete delta.nvim Yes (y) or No (n)'), true, 'the row asks under a state filter')
  H.press('n')
  H.eq(prompts, 0, "Neovim's own prompt never showed")
end)
