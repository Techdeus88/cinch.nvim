-- Drawing helpers for the cinch window. A canvas collects lines, their highlights,
-- and the plugin or section each line belongs to. The text helpers keep columns
-- straight at any width: everything is measured in screen cells, not bytes.

local M = {}

-- Highlight groups, linked to standard ones so every colorscheme styles them.
M.highlights = {
  CinchTitle = 'FloatTitle',
  CinchSection = 'Label',
  CinchName = 'Normal',
  CinchMuted = 'Comment',
  CinchKey = 'Special',
  CinchTab = 'FloatTitle',
  CinchLoaded = 'DiagnosticOk',
  CinchWaiting = 'DiagnosticHint',
  CinchFailed = 'DiagnosticError',
  CinchWarn = 'DiagnosticWarn',
  CinchActive = 'DiagnosticInfo',
  CinchUpdate = 'DiagnosticWarn',
  CinchPillFill = 'DiagnosticOk',
  CinchPillTrack = 'NonText',
  CinchRule = 'FloatBorder',
  CinchNow = 'DiagnosticVirtualTextOk',
  CinchLater = 'DiagnosticVirtualTextInfo',
  CinchTrigger = 'DiagnosticVirtualTextWarn',
  CinchIconNow = 'DiagnosticOk',
  CinchIconLater = 'DiagnosticInfo',
  CinchIconTrigger = 'DiagnosticWarn',
  CinchDep = 'DiagnosticHint',
  CinchTriggerValue = 'Normal',
  CinchLink = 'Underlined',
  CinchCommit = 'Constant',
  CinchBackdrop = 'CinchBackdropDefault',
  CinchMarked = 'Visual',
}

-- Colors and rounded shapes ------------------------------------------------------

-- Nerd Font half circles: the ends of a rounded chip or bar.
local cap_left, cap_right = '\u{e0b6}', '\u{e0b4}'

--- Whether chips and bars get rounded ends. define_colors() decides: it needs
--- 'termguicolors', so it can color the ends, and `rounded` not turned off.
M.rounded = false
--- Whether the chip and bar colors could be worked out from the colorscheme.
M.colored = false

---@param name string
---@param key 'fg'|'bg'
---@return integer?
local function color(name, key)
  return vim.api.nvim_get_hl(0, { name = name, link = false })[key]
end

--- `a` of `fg` over `bg`, both 0xRRGGBB.
---@param fg integer
---@param bg integer
---@param a number
---@return integer
local function blend(fg, bg, a)
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local f, b = bit.band(bit.rshift(fg, shift), 255), bit.band(bit.rshift(bg, shift), 255)
    out = out + bit.lshift(math.floor(f * a + b * (1 - a) + 0.5), shift)
  end
  return out
end

-- Each way a plugin loads has its own color, taken from the first of these groups
-- the colorscheme sets: so `now`, `later`, an event, a filetype, a command, a key and
-- a dependency each read apart at a glance.
local kind_sources = {
  now = { 'DiagnosticOk' },
  later = { 'DiagnosticInfo' },
  event = { 'DiagnosticWarn' },
  ft = { 'Type', 'DiagnosticHint' },
  cmd = { 'Keyword', 'Statement', 'Function' },
  keys = { 'Constant', 'Number', 'Special' },
  dep = { 'DiagnosticHint', 'Comment' },
  trigger = { 'Special', 'DiagnosticWarn' },
}
-- Without colors to blend, the chips link to groups every colorscheme styles.
local kind_links = {
  now = 'DiagnosticVirtualTextOk',
  later = 'DiagnosticVirtualTextInfo',
  event = 'DiagnosticVirtualTextWarn',
  ft = 'DiagnosticVirtualTextHint',
  cmd = 'DiagnosticVirtualTextInfo',
  keys = 'DiagnosticVirtualTextWarn',
  dep = 'DiagnosticVirtualTextHint',
  trigger = 'DiagnosticVirtualTextWarn',
}

--- The chip group and the text group of a kind: 'CinchKindCmd', 'CinchKindCmdText'.
--- A trigger of your own has the `trigger` colors.
---@param kind string now, later, event, ft, cmd, keys, dep, or your own
---@return string chip, string text
function M.kind_hl(kind)
  local k = kind_sources[kind] and kind or 'trigger'
  local name = 'CinchKind' .. k:sub(1, 1):upper() .. k:sub(2)
  return name, name .. 'Text'
end

-- The chips' colors come from the diagnostic colors every colorscheme sets.
local chip_sources = { CinchNow = 'DiagnosticOk', CinchLater = 'DiagnosticInfo', CinchTrigger = 'DiagnosticWarn' }

--- Set the window's highlight groups: links for most, and for the chips and the
--- progress bar colors worked out from the colorscheme, as the mockup tinted them.
--- Runs on every open and every ColorScheme, so a new colorscheme carries over.
---@param rounded boolean
function M.define_colors(rounded)
  local set = vim.api.nvim_set_hl
  set(0, 'CinchBackdropDefault', { bg = 0 })
  for group, link in pairs(M.highlights) do
    set(0, group, { link = link, default = true })
  end
  local base = color('NormalFloat', 'bg') or color('Normal', 'bg')
  M.colored = vim.o.termguicolors and base ~= nil
  -- A plugin that is only a dependency: its name in italics, so it reads as a supporting part.
  set(0, 'CinchDepName', { fg = color('Comment', 'fg'), italic = true })
  -- The trigger that loaded a plugin, among the others it waits on.
  set(0, 'CinchFired', { fg = color('Normal', 'fg'), bold = true, underline = true })
  if not M.colored then
    for kind, link in pairs(kind_links) do
      local chip, text = M.kind_hl(kind)
      set(0, chip, { link = link })
      set(0, chip .. 'Cap', { link = link })
      set(0, text, { link = kind_sources[kind][1] })
    end
    M.rounded = false
    return
  end
  ---@cast base integer
  for kind, sources in pairs(kind_sources) do
    local fg
    for _, source in ipairs(sources) do
      fg = fg or color(source, 'fg')
    end
    fg = fg or color('Normal', 'fg') or 0xffffff
    local chip, text = M.kind_hl(kind)
    local bg = blend(fg, base, 0.2)
    set(0, chip, { fg = fg, bg = bg })
    set(0, chip .. 'Cap', { fg = bg })
    set(0, text, { fg = fg })
  end
  for group, source in pairs(chip_sources) do
    local fg = color(source, 'fg') or color('Normal', 'fg') or 0xffffff
    local bg = blend(fg, base, 0.2)
    set(0, group, { fg = fg, bg = bg })
    -- fg only: the end takes the row's own background, the cursor line's included.
    set(0, group .. 'Cap', { fg = bg })
  end
  -- A link reads as one: underlined, in the color of a directory name.
  set(0, 'CinchLink', { fg = color('Directory', 'fg') or color('Underlined', 'fg'), underline = true })
  -- Every bar, install progress and load times: a thin line in the green of an
  -- installed plugin's ✓, on a faint track of the same green.
  local fill = color('DiagnosticOk', 'fg') or color('String', 'fg') or 0x9ece6a
  set(0, 'CinchPillFill', { fg = fill })
  set(0, 'CinchPillTrack', { fg = blend(fill, base, 0.25) })
  M.rounded = rounded
end

--- A chip: ` now ` on its own color, with rounded ends when it can.
---@param text string
---@param group string CinchNow, CinchLater or CinchTrigger
---@param inner integer cells inside the ends
---@return { [1]: string, [2]: string }[]
function M.chip(text, group, inner)
  local body = { M.fit(' ' .. text .. ' ', inner), group }
  if not M.rounded then
    return { body }
  end
  return { { cap_left, group .. 'Cap' }, body, { cap_right, group .. 'Cap' } }
end

--- Cells a chip takes, ends included.
---@param inner integer
---@return integer
function M.chip_width(inner)
  return inner + (M.rounded and 2 or 0)
end

--- A progress bar `cells` wide, filled for value/max: a thin line, colored up to
--- value/max and faint after it.
---@param value number
---@param max number
---@param cells integer
---@return { [1]: string, [2]: string }[]
function M.pill(value, max, cells)
  local n = max > 0 and math.floor(value / max * cells + 0.5) or 0
  n = math.max(value > 0 and 1 or 0, math.min(cells, n))
  return { { ('━'):rep(n), 'CinchPillFill' }, { ('━'):rep(cells - n), 'CinchPillTrack' } }
end

---@class cinch.ui.Canvas
---@field lines string[]
---@field hls { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] 0-based line, start col, end col, group
---@field rows table<integer, string> 1-based line -> plugin name
---@field sections table<integer, string> 1-based line -> section key
---@field line_hls table<integer, string> 1-based line -> group for the whole line
---@field width integer
local Canvas = {}
Canvas.__index = Canvas

---@param width integer
---@return cinch.ui.Canvas
function M.new(width)
  return setmetatable({ lines = {}, hls = {}, rows = {}, sections = {}, line_hls = {}, width = width }, Canvas)
end

--- Add one line from { text, group? } chunks.
---@param chunks { [1]: string, [2]?: string }[]
---@param at? { plugin?: string, section?: string, line_hl?: string } what the line belongs to, and a shade over it
function Canvas:add(chunks, at)
  local parts, col = {}, 0
  for _, c in ipairs(chunks) do
    local text = c[1] or ''
    if c[2] and #text > 0 then
      self.hls[#self.hls + 1] = { #self.lines, col, col + #text, c[2] }
    end
    parts[#parts + 1] = text
    col = col + #text
  end
  self.lines[#self.lines + 1] = table.concat(parts)
  if at and at.plugin then
    self.rows[#self.lines] = at.plugin
  end
  if at and at.section then
    self.sections[#self.lines] = at.section
  end
  if at and at.line_hl then
    self.line_hls[#self.lines] = at.line_hl
  end
end

function Canvas:blank()
  self.lines[#self.lines + 1] = ''
end

-- Text --------------------------------------------------------------------------

---@param s string
---@return integer cells
function M.cells(s)
  return vim.fn.strdisplaywidth(s)
end

--- Exactly `w` cells: padded, or cut with … when too long.
---@param s string
---@param w integer
---@return string
function M.fit(s, w)
  if w <= 0 then
    return ''
  end
  local n = M.cells(s)
  if n <= w then
    return s .. (' '):rep(w - n)
  end
  local out = vim.fn.strcharpart(s, 0, w - 1)
  while M.cells(out) > w - 1 do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. '…' .. (' '):rep(w - 1 - M.cells(out))
end

--- Chunks cut to `w` cells, the last one ending in … when it is cut.
---@param chunks { [1]: string, [2]?: string }[]
---@param w integer
---@return { [1]: string, [2]?: string }[]
function M.clip(chunks, w)
  local out, used = {}, 0
  for _, c in ipairs(chunks) do
    local n = M.cells(c[1])
    if used + n > w then
      out[#out + 1] = { M.fit(c[1], w - used), c[2] }
      return out
    end
    out[#out + 1], used = c, used + n
  end
  return out
end

--- The longest start of `s` that fits in `w` cells, and the rest. At least one
--- character, so a character wider than `w` still moves the split along.
---@param s string
---@param w integer
---@return string head, string rest
local function cut(s, w)
  local chars, n, used = vim.fn.strchars(s, true), 0, 0
  while n < chars do
    -- A character with what combines with it, so the two never split.
    local c = M.cells(vim.fn.strcharpart(s, n, 1, true))
    if n > 0 and used + c > w then
      break
    end
    n, used = n + 1, used + c
  end
  return vim.fn.strcharpart(s, 0, n, true), vim.fn.strcharpart(s, n, chars, true)
end

--- Split `s` into lines of at most `w` cells, at spaces where it can.
---@param s string
---@param w integer
---@return string[]
function M.wrap(s, w)
  local out, line = {}, ''
  for word in s:gmatch('%S+') do
    while M.cells(word) > w do
      if line ~= '' then
        out[#out + 1], line = line, ''
      end
      out[#out + 1], word = cut(word, w)
    end
    local joined = line == '' and word or (line .. ' ' .. word)
    if M.cells(joined) > w then
      out[#out + 1], line = line, word
    else
      line = joined
    end
  end
  if line ~= '' then
    out[#out + 1] = line
  end
  return out
end

--- Right-aligned in `w` cells.
---@param s string
---@param w integer
---@return string
function M.right(s, w)
  local n = M.cells(s)
  return n >= w and M.fit(s, w) or (' '):rep(w - n) .. s
end

local spark_chars = { '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█' }

---@param values number[]
---@return string
function M.spark(values)
  local max = 0
  for _, v in ipairs(values) do
    max = math.max(max, v)
  end
  local out = {}
  for i, v in ipairs(values) do
    out[i] = spark_chars[math.max(1, math.ceil(v / math.max(max, 1e-9) * #spark_chars))]
  end
  return table.concat(out)
end

M.spinner = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

---@param ms? number
---@return string
function M.ms(ms)
  if not ms then
    return ''
  end
  return ms >= 1000 and ('%.2fs'):format(ms / 1000) or ('%.1fms'):format(ms)
end

---@param t integer os.time()
---@return string
function M.ago(t)
  local s = os.time() - t
  if s < 60 then
    return s .. 's ago'
  end
  return s < 3600 and ('%dm ago'):format(s / 60) or ('%dh ago'):format(s / 3600)
end

--- A value on one line, as Lua: strings quoted, functions as where they are defined.
---@param v any
---@return string
function M.value(v)
  if type(v) == 'function' then
    local info = debug.getinfo(v, 'S')
    return ('<function %s:%d>'):format(vim.fs.basename(info.short_src), info.linedefined)
  end
  if type(v) == 'table' then
    local text = vim.inspect(v, { newline = ' ', indent = '' })
    return (text:gsub('"(<function [^"]+>)"', '%1'))
  end
  return vim.inspect(v)
end

--- A table as dotted keys and one-line values: { a = { b = 1 } } -> { { 'a.b', '1' } }.
--- Lists and empty tables stay whole; nesting deeper than four levels stays whole.
---@param t table
---@return { [1]: string, [2]: string }[]
function M.flatten(t)
  local out = {}
  local function walk(v, prefix, depth)
    if type(v) == 'table' and next(v) ~= nil and not vim.islist(v) and depth < 4 then
      local keys = vim.tbl_keys(v)
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      for _, k in ipairs(keys) do
        walk(v[k], prefix == '' and tostring(k) or (prefix .. '.' .. tostring(k)), depth + 1)
      end
    else
      out[#out + 1] = { prefix, M.value(v) }
    end
  end
  walk(t, '', 0)
  return out
end

--- A path relative to the config dir, or with ~ for the home dir.
---@param path string
---@return string
function M.short_path(path)
  local config = vim.fn.stdpath('config') --[[@as string]]
  if vim.startswith(path, config .. '/') then
    return path:sub(#config + 2)
  end
  return vim.fn.fnamemodify(path, ':~')
end

return M
