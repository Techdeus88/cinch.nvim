-- The window's colors come from the colorscheme's hues: a colorscheme that keeps its
-- diagnostics gray, as Ashen does, and its hues in other groups still colors the window.
-- Its own text colors are used as they are; an underline's is lightened to read. A group
-- you set yourself is left alone, and each way of loading keeps its own color.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({ confirm = false, spec = {} })

H.after_startup(function()
  local canvas = require('cinch.features.ui.canvas')
  local set = vim.api.nvim_set_hl
  vim.o.termguicolors = true
  local function fg(group)
    return vim.api.nvim_get_hl(0, { name = group, link = false }).fg
  end

  -- Gray diagnostics and titles; the hues elsewhere.
  vim.cmd('hi clear')
  set(0, 'Normal', { fg = 0xb4b4b4, bg = 0x121212 })
  set(0, 'DiagnosticOk', { fg = 0xd5d5d5 })
  set(0, 'DiagnosticUnderlineOk', { sp = 0x1e6f54, underdotted = true })
  set(0, 'DiagnosticInfo', { fg = 0xd5d5d5 })
  set(0, 'DiagnosticUnderlineInfo', { sp = 0x4a8b8b, underdotted = true })
  set(0, 'DiagnosticError', { fg = 0xc53030 })
  set(0, 'FloatTitle', { fg = 0xe5e5e5 })
  set(0, 'Title', { fg = 0xb14242 })
  set(0, 'Label', { fg = 0xe5e5e5 })
  set(0, 'Type', { fg = 0xc4693d })
  set(0, 'Constant', { fg = 0xc4693d })
  set(0, 'PreProc', { fg = 0xb14242 })
  canvas.define_colors(true)

  H.eq(fg('CinchTitle'), 0xb14242, 'the title takes the hue of Title, not the gray FloatTitle')
  H.eq(vim.api.nvim_get_hl(0, { name = 'CinchBanner' }).bg, 0xb14242, 'and so does the banner')
  H.eq(fg('CinchFailed'), 0xc53030, 'a text color of the colorscheme is used as it is')
  H.eq(fg('CinchActive'), 0x4a8b8b, 'gray info: the hue of its underline')
  local loaded = assert(fg('CinchLoaded'))
  H.eq(loaded ~= 0x1e6f54 and loaded ~= 0xd5d5d5, true, 'gray ok: its underline green, lightened')
  local g = bit.band(bit.rshift(loaded, 8), 255)
  H.eq(g > bit.band(bit.rshift(loaded, 16), 255) and g > bit.band(loaded, 255), true, 'and still green')
  H.eq(fg('CinchPillFill'), loaded, 'the bars in the same color')
  H.eq(fg(canvas.kind_hl('now') .. 'Text'), loaded, 'and the now chips')

  -- Filetype and key chips both find orange first: the second takes another hue.
  local ft, keys = fg(canvas.kind_hl('ft') .. 'Text'), fg(canvas.kind_hl('keys') .. 'Text')
  H.eq({ ft, keys }, { 0xc4693d, 0xb14242 }, 'each way of loading keeps its own color')

  -- One you set yourself stays, across another define.
  set(0, 'CinchLoaded', { fg = 0x123456 })
  canvas.define_colors(true)
  H.eq(fg('CinchLoaded'), 0x123456, 'your own CinchLoaded is kept')

  -- A colorscheme with colored diagnostics: its colors, as before.
  vim.cmd('hi clear')
  set(0, 'Normal', { fg = 0xc0caf5, bg = 0x1a1b26 })
  set(0, 'DiagnosticOk', { fg = 0x73daca })
  set(0, 'FloatTitle', { fg = 0x7aa2f7 })
  canvas.define_colors(true)
  H.eq({ fg('CinchLoaded'), fg('CinchTitle') }, { 0x73daca, 0x7aa2f7 }, 'colored diagnostics are used as they are')
end)
