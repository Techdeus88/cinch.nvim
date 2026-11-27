-- The window's geometry: four bordered windows over the editor, the one-line header on
-- top, the list and the pane beside it (or under it when narrow) in the middle, the footer
-- at the bottom, and the backdrop. Given what the window shows, it returns the config of
-- each window and the lines of the header and the footer; it reads no window state.

local canvas = require('cinch.features.ui.canvas')

local M = {}

---@class cinch.ui.Shape what the layout depends on
---@field opts cinch.ui.Opts
---@field view string the view on show
---@field views string[] the view names, in tab order
---@field help boolean the ? screen is up
---@field tall boolean the tall height, after `-`
---@field even boolean the list and the pane share the width evenly, after `=`
---@field split boolean the pane is on show, beside or under the list
---@field op? cinch.ui.Op an install, check, update or delete under way, or just ended
---@field notice? { text: string, level: integer } a message for the footer, when no operation has it
---@field input? string the prompt and the text being typed
---@field marked integer how many plugins are selected

--- The border style: yours, else winborder, else rounded.
---@param opts cinch.ui.Opts
---@return string|string[]
function M.border(opts)
  return opts.border or (vim.o.winborder ~= '' and vim.o.winborder or 'rounded')
end

---@param chunks { [1]: string, [2]?: string }[]
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

--- One line of `width` cells from its left, middle and right: the middle centered on the
--- whole line, or as near as the sides let it; the gaps on either side take up the rest.
---@param width integer
---@param left { [1]: string, [2]?: string }[]
---@param middle { [1]: string, [2]?: string }[]
---@param right { [1]: string, [2]?: string }[]
---@return { [1]: string, [2]?: string }[]
local function spread(width, left, middle, right)
  local room = math.max(0, width - cells(left) - cells(middle) - cells(right))
  local before = room
  if #middle > 0 then
    before = math.max(1, math.min(math.floor((width - cells(middle)) / 2) - cells(left), room - 1))
  end
  local out = vim.list_extend({}, left)
  out[#out + 1] = { (' '):rep(before) }
  vim.list_extend(out, middle)
  out[#out + 1] = { (' '):rep(math.max(0, room - before)) }
  return vim.list_extend(out, right)
end

--- The header's line, `width` cells: when Neovim started and when its UI came up on the
--- left, the name on a banner in the middle, the tabs on the right.
---@param width integer
---@param s cinch.ui.Shape
---@return { [1]: string, [2]?: string }[]
function M.header(width, s)
  local stats = package.loaded['cinch.features.stats']
  local marks = stats and stats.marks or {}
  local tabs = {}
  for _, v in ipairs(s.views) do
    tabs[#tabs + 1] = { ' ' .. v .. ' ', v == s.view and not s.help and 'CinchTab' or 'CinchMuted' }
  end
  -- Short of room, the tabs keep theirs: the ui time goes, then startup, then the name.
  local times = {}
  if marks.vimenter then
    times[#times + 1] = 'startup ' .. canvas.ms(marks.vimenter)
  end
  if marks.uienter then
    times[#times + 1] = 'ui ' .. canvas.ms(marks.uienter)
  end
  local left = {}
  while #times > 0 do
    left = { { ' ' .. table.concat(times, ' · ') .. ' ', 'CinchMuted' } }
    if cells(left) + cells(tabs) < width then
      break
    end
    times[#times], left = nil, {}
  end
  local name = banner('cinch', width)
  if cells(left) + cells(name) + cells(tabs) + 2 > width then
    name = {}
  end
  return spread(width, left, name, tabs)
end

--- The global message, at most `room` cells: an install, check, update or delete in the
--- middle, or else a message that is about no plugin. A plugin's own messages are on its row.
---@param s cinch.ui.Shape
---@param room integer
---@return { [1]: string, [2]?: string }[]?
local function message(s, room)
  if s.op then
    return (require('cinch.features.ui.ops').line(s.op, room))
  end
  if s.notice then
    local levels = vim.log.levels
    local hl = s.notice.level >= levels.ERROR and 'CinchFailed'
      or s.notice.level >= levels.WARN and 'CinchWarn'
      or 'CinchTitle'
    return canvas.clip({ { s.notice.text, hl } }, room)
  end
end

--- The footer's line, `width` cells, centered: the text being typed on a banner, else
--- the global message, else how many plugins are selected. The keys are on the ? screen.
---@param width integer
---@param s cinch.ui.Shape
---@return { [1]: string, [2]?: string }[]
function M.footer(width, s)
  local line = s.input and banner(vim.trim(s.input), width) or message(s, math.max(0, width - 2))
  if not line and s.marked > 0 then
    line = banner(('%d selected'):format(s.marked), width)
  end
  line = line or {}
  return vim.list_extend({ { (' '):rep(math.max(0, math.floor((width - cells(line)) / 2))) } }, line)
end

--- The configs of the backdrop, the header, the list, the pane and the footer, for `s`.
---@param s cinch.ui.Shape
---@return table<string, vim.api.keyset.win_config>
function M.configs(s)
  local border = M.border(s.opts)
  -- Cells a border adds to a window, both sides together.
  local edge = border == 'none' and 0 or 2
  local lines = vim.o.lines - vim.o.cmdheight
  local w = math.max(40, math.floor(vim.o.columns * s.opts.size))
  local h = math.max(12, math.floor(lines * (s.tall and s.opts.tall or s.opts.size)))
  local row = math.max(0, math.floor((lines - h) / 2))
  local col = math.max(0, math.floor((vim.o.columns - w) / 2))

  --- A window whose border box is at `r`, `c`, `width` by `height` cells.
  ---@return vim.api.keyset.win_config
  local function box(r, c, width, height, extra)
    local cfg = { relative = 'editor', row = r, col = c, zindex = 51, border = border }
    cfg.width, cfg.height = math.max(1, width - edge), math.max(1, height - edge)
    return vim.tbl_extend('force', cfg, extra or {})
  end

  -- The header and the footer keep a line each; the list and the pane get the rest.
  local head, bar = 1 + edge, 1 + edge
  local top, middle = row + head, h - head - bar
  local list, pane
  if not s.split then
    list = box(top, col, w, middle)
    pane = box(top, col, w, middle, { hide = true })
  elseif w >= s.opts.side_by_side then
    -- Wide enough: the pane beside the list.
    local lw = math.floor(w * (s.even and 0.5 or s.opts.split))
    list = box(top, col, lw, middle)
    pane = box(top, col + lw, w - lw, middle, { hide = false })
  else
    -- Too narrow for two columns: the pane under the list.
    local lh = math.max(1 + edge, math.floor(middle * 0.55))
    list = box(top, col, w, lh)
    pane = box(top + lh, col, w, middle - lh, { hide = false })
  end
  -- Under the windows, over everything else: the editor dimmed behind them.
  local backdrop = {
    relative = 'editor',
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = lines,
    zindex = 49,
    focusable = false,
  }
  return {
    backdrop = backdrop,
    header = box(row, col, w, head, { focusable = false }),
    list = list,
    pane = pane,
    footer = box(top + middle, col, w, bar, { focusable = false }),
  }
end

return M
