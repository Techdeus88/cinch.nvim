-- The window's geometry: the frame over the editor, the list, the pane beside it (or
-- under it when narrow), and the backdrop. Given what the window shows, it returns the
-- config of each window; it reads no window state and draws nothing.

local canvas = require('cinch.features.ui.canvas')
local state = require('cinch.state')

local M = {}

local border_line = { rounded = '─', single = '─', double = '═', bold = '━', solid = ' ', shadow = ' ' }

---@class cinch.ui.Shape what the layout depends on
---@field opts cinch.ui.Opts
---@field view string the view on show
---@field views string[] the view names, in tab order
---@field help boolean the ? screen is up
---@field wide boolean the wide share, after `=`
---@field split boolean the pane is on show, beside or under the list
---@field footer string the keys for the bottom border

--- The border style: yours, else winborder, else rounded.
---@param opts cinch.ui.Opts
---@return string|string[]
function M.border(opts)
  return opts.border or (vim.o.winborder ~= '' and vim.o.winborder or 'rounded')
end

---@param chunks { [1]: string, [2]: string }[]
---@return integer
local function cells(chunks)
  local n = 0
  for _, ch in ipairs(chunks) do
    n = n + canvas.cells(ch[1])
  end
  return n
end

--- `text` on the filled banner color, with rounded ends when it can, at most `room` cells.
---@param text string
---@param room integer
---@return { [1]: string, [2]: string }[]
local function banner(text, room)
  local inner = math.max(1, math.min(canvas.cells(text) + 2, room - canvas.chip_width(0)))
  return canvas.chip(text, 'CinchBanner', inner)
end

--- The title row: the counts on the left, the name on a banner in the middle, the
--- tabs on the right, the border's own line between them.
---@param width integer
---@param s cinch.ui.Shape
---@return { [1]: string, [2]: string }[]
local function title(width, s)
  local stats = package.loaded['cinch.features.stats']
  local startup = stats and (stats.marks.uienter or stats.marks.vimenter)
  local left = {
    {
      (' %d plugins%s '):format(#state.yours(), startup and (' · startup ' .. canvas.ms(startup)) or ''),
      'CinchMuted',
    },
  }
  local tabs = {}
  for _, v in ipairs(s.views) do
    tabs[#tabs + 1] = { ' ' .. v .. ' ', v == s.view and not s.help and 'CinchTab' or 'CinchMuted' }
  end
  local name = banner('cinch', width)
  local inner = width - 2
  local b = M.border(s.opts)
  local line = type(b) == 'string' and border_line[b] or '─'
  -- The name centered on the whole border; the line on either side takes up the rest.
  local at = math.floor((inner - cells(name)) / 2)
  local before = math.max(1, at - cells(left))
  local after = math.max(1, inner - cells(left) - before - cells(name) - cells(tabs))
  local out = vim.list_extend(left, { { line:rep(before), 'FloatBorder' } })
  vim.list_extend(out, name)
  vim.list_extend(out, { { line:rep(after), 'FloatBorder' } })
  return vim.list_extend(out, tabs)
end

--- The keys, on a banner centered in the bottom border.
---@param width integer
---@param text string
---@return { [1]: string, [2]: string }[]
local function footer(width, text)
  return banner(vim.trim(text), width - 2)
end

--- The configs of the backdrop, the frame, the list and the pane, for `s`.
---@param s cinch.ui.Shape
---@return table<string, vim.api.keyset.win_config>
function M.configs(s)
  local share = s.wide and s.opts.wide or s.opts.size
  local lines = vim.o.lines - vim.o.cmdheight
  local w = math.max(40, math.floor(vim.o.columns * share))
  local h = math.max(10, math.floor(lines * share))
  local row = math.max(0, math.floor((lines - h) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - w) / 2) - 1)
  local frame = { relative = 'editor', row = row, col = col, width = w, height = h, zindex = 50, focusable = false }
  frame.border = M.border(s.opts)
  -- Neovim allows a title and footer only on a float with a border.
  if frame.border ~= 'none' then
    frame.title, frame.title_pos = title(w, s), 'left'
    frame.footer, frame.footer_pos = footer(w, s.footer), 'center'
  end
  local list = { relative = 'editor', row = row + 1, col = col + 1, width = w, height = h, zindex = 51 }
  -- Focusable, so the mouse wheel scrolls it.
  local pane = { relative = 'editor', zindex = 51, hide = not s.split }
  if w >= s.opts.side_by_side then
    -- Wide enough: the pane beside the list, a rule between them.
    list.width = s.split and math.floor(w * s.opts.split) or w
    pane.row, pane.col = row + 1, col + 1 + list.width
    pane.width, pane.height = math.max(1, w - list.width - 1), h
    pane.border = { '', '', '', '', '', '', '', { '│', 'CinchRule' } }
  else
    -- Too narrow for two columns: the pane under the list, a rule between them.
    list.height = s.split and math.max(3, math.floor(h * 0.55)) or h
    pane.row, pane.col = row + 1 + list.height, col + 1
    pane.width, pane.height = w, math.max(1, h - list.height - 1)
    pane.border = { '', { '─', 'CinchRule' }, '', '', '', '', '', '' }
  end
  -- Under the frame, over everything else: the editor dimmed behind the window.
  local backdrop = {
    relative = 'editor',
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = lines,
    zindex = 49,
    focusable = false,
  }
  return { backdrop = backdrop, frame = frame, list = list, pane = pane }
end

return M
