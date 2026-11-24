-- Pieces of cinch for your statusline, winbar or dashboard. Each `*_text` is plain text,
-- for lualine, heirline or a dashboard to color and click their own way; updates() is
-- ready for 'statusline' or 'winbar' as it is, colored and clickable. Nothing here
-- loads until you require it.

local events = require('cinch.events')

local M = {}

-- A color before the window ever opened and gave cinch its own.
vim.api.nvim_set_hl(0, 'CinchUpdate', { link = 'DiagnosticWarn', default = true })

local watching = false

--- Once the updates feature is up: a finished check changes what updates() says, so
--- the statuslines and winbars draw again.
local function watch()
  if watching or not package.loaded['cinch.features.updates'] then
    return
  end
  watching = true
  events.on('Updates', function()
    vim.schedule(function()
      vim.cmd.redrawstatus({ bang = true })
    end)
  end)
end

--- `↑ 3 updates` when updates are ready, else ''.
---@return string
function M.updates_text()
  watch()
  -- Counted in place: a statusline asks on every redraw, and updates() copies every result.
  local u = package.loaded['cinch.features.updates']
  local n = u and vim.tbl_count(u.results) or 0
  if n == 0 then
    return ''
  end
  return ('↑ %d update%s'):format(n, n == 1 and '' or 's')
end

--- updates_text() colored and clickable, for 'statusline' or 'winbar':
--- `vim.o.statusline = "%{%v:lua.require'cinch.components'.updates()%}"`.
---@return string
function M.updates()
  local text = M.updates_text()
  if text == '' then
    return ''
  end
  return '%#CinchUpdate#%@v:lua.cinch_open_updates@' .. text .. '%X%*'
end

--- Open the window on Plugins, where the row of each plugin with an update asks
--- `Update <name> Yes (y) or No (n)`; with `confirm` off they apply at once.
function M.open_updates()
  local ui = package.loaded['cinch.features.ui']
  local u = package.loaded['cinch.features.updates']
  if ui then
    ui.open('plugins')
  end
  if u then
    u.ask()
  end
end

--- `startup 42ms · ui 58ms`: when Neovim started and when its UI came up, as the
--- window's header says; '' before then, or with the stats feature off.
---@return string
function M.startup_text()
  local s = require('cinch').stats()
  local parts = {}
  if s and s.startup.vimenter then
    parts[#parts + 1] = ('startup %s'):format(require('cinch.features.ui.canvas').ms(s.startup.vimenter))
  end
  if s and s.startup.uienter then
    parts[#parts + 1] = ('ui %s'):format(require('cinch.features.ui.canvas').ms(s.startup.uienter))
  end
  return table.concat(parts, ' · ')
end

-- What a click on updates() calls; %@ takes only a global function's name.
_G.cinch_open_updates = function()
  -- Out of the statusline's redraw, which locks the screen.
  vim.schedule(M.open_updates)
end

return M
