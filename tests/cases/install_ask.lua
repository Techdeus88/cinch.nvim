-- confirm = true after startup: cinch asks on the plugin's row before installing, and
-- vim.pack's own prompt never shows. A no leaves it off disk; a yes installs it.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local api = vim.api
local cinch = require('cinch')

local prompts = 0
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.confirm = function()
  prompts = prompts + 1
  return 1
end

cinch.setup({ confirm = true, spec = {} })

---@param text string
---@return boolean
local function shows(text)
  local w = require('cinch.features.ui').windows()
  local lines = w.list and api.nvim_buf_get_lines(api.nvim_win_get_buf(w.list), 0, -1, false) or {}
  return table.concat(lines, '\n'):find(text, 1, true) ~= nil
end

local function on_disk()
  return vim.uv.fs_stat(vim.fs.joinpath(require('cinch.pack').dir, 'alpha.nvim')) ~= nil
end

H.after_startup(function()
  cinch.add({ { H.src('alpha.nvim'), load = 'now' } })
  H.eq(shows('Install alpha.nvim Yes (y) or No (n)'), true, 'its row asks, in the window')
  H.eq(on_disk(), false, 'and nothing installs before the answer')
  H.press('n')
  H.eq({ on_disk(), H.plugin('alpha.nvim').state }, { false, 'failed' }, 'n: not installed')

  vim.cmd('Cinch install alpha.nvim')
  H.eq(shows('Install alpha.nvim Yes (y) or No (n)'), true, ':Cinch install asks again')
  H.press('y')
  H.wait(function()
    return H.plugin('alpha.nvim').state == 'loaded'
  end, 'alpha to load')
  H.eq(on_disk(), true, 'y installs it')
  H.eq(prompts, 0, "vim.pack's prompt never showed")
end)
