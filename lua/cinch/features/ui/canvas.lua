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
  CinchBar = 'DiagnosticInfo',
  CinchBarEmpty = 'NonText',
  CinchRule = 'FloatBorder',
  CinchNow = 'DiagnosticVirtualTextOk',
  CinchLater = 'DiagnosticVirtualTextInfo',
  CinchTrigger = 'DiagnosticVirtualTextWarn',
  CinchIconNow = 'DiagnosticOk',
  CinchIconLater = 'DiagnosticInfo',
  CinchIconTrigger = 'DiagnosticWarn',
  CinchDep = 'DiagnosticHint',
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

-- The chips' colors come from the diagnostic colors every colorscheme sets.
local chip_sources = { CinchNow = 'DiagnosticOk', CinchLater = 'DiagnosticInfo', CinchTrigger = 'DiagnosticWarn' }

--- Set the window's highlight groups: links for most, and for the chips and the
--- progress bar colors worked out from the colorscheme, as the mockup tinted them.
--- Runs on every open and every ColorScheme, so a new colorscheme carries over.
---@param rounded boolean
function M.define_colors(rounded)
  local set = vim.api.nvim_set_hl
  for group, link in pairs(M.highlights) do
    set(0, group, { link = link, default = true })
  end
  local base = color('NormalFloat', 'bg') or color('Normal', 'bg')
  M.colored = vim.o.termguicolors and base ~= nil
  if not M.colored then
    M.rounded = false
    return
  end
  ---@cast base integer
  for group, source in pairs(chip_sources) do
    local fg = color(source, 'fg') or color('Normal', 'fg') or 0xffffff
    local bg = blend(fg, base, 0.2)
    set(0, group, { fg = fg, bg = bg })
    -- fg only: the end takes the row's own background, the cursor line's included.
    set(0, group .. 'Cap', { fg = bg })
  end
  local fill = color('DiagnosticInfo', 'fg') or color('Function', 'fg') or 0x7aa2f7
  local track = blend(fill, base, 0.18)
  set(0, 'CinchPillFill', { bg = fill })
  set(0, 'CinchPillTrack', { bg = track })
  set(0, 'CinchPillFillCap', { fg = fill })
  set(0, 'CinchPillTrackCap', { fg = track })
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

--- A progress bar `cells` wide, filled for value/max: a rounded pill when colors
--- allow, else block characters.
---@param value number
---@param max number
---@param cells integer
---@return { [1]: string, [2]: string }[]
function M.pill(value, max, cells)
  if not M.colored then
    local filled, empty = M.bar(value, max, cells)
    return { { filled, 'CinchBar' }, { empty, 'CinchBarEmpty' } }
  end
  local inner = M.rounded and cells - 2 or cells
  local n = max > 0 and math.floor(value / max * inner + 0.5) or 0
  n = math.max(value > 0 and 1 or 0, math.min(inner, n))
  local out = { { (' '):rep(n), 'CinchPillFill' }, { (' '):rep(inner - n), 'CinchPillTrack' } }
  if M.rounded then
    table.insert(out, 1, { cap_left, n > 0 and 'CinchPillFillCap' or 'CinchPillTrackCap' })
    out[#out + 1] = { cap_right, n < inner and 'CinchPillTrackCap' or 'CinchPillFillCap' }
  end
  return out
end

---@class cinch.ui.Canvas
---@field lines string[]
---@field hls { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] 0-based line, start col, end col, group
---@field rows table<integer, string> 1-based line -> plugin name
---@field sections table<integer, string> 1-based line -> section key
---@field width integer
local Canvas = {}
Canvas.__index = Canvas

---@param width integer
---@return cinch.ui.Canvas
function M.new(width)
  return setmetatable({ lines = {}, hls = {}, rows = {}, sections = {}, width = width }, Canvas)
end

--- Add one line from { text, group? } chunks.
---@param chunks { [1]: string, [2]?: string }[]
---@param at? { plugin?: string, section?: string } what the line belongs to
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
      out[#out + 1] = vim.fn.strcharpart(word, 0, w)
      word = vim.fn.strcharpart(word, w)
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

--- A horizontal bar of `cells`, filled for value/max: returns the filled and empty parts.
---@param value number
---@param max number
---@param cells integer
---@return string filled, string empty
function M.bar(value, max, cells)
  local n = max > 0 and math.floor(value / max * cells + 0.5) or 0
  n = math.max(value > 0 and 1 or 0, math.min(cells, n))
  return ('▇'):rep(n), ('▁'):rep(cells - n)
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
