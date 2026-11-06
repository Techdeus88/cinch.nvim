-- canvas.wrap(): lines of at most `w` display cells, wide and combining characters included.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

H.after_startup(function()
  local canvas = require('cinch.features.ui.canvas')
  H.eq(canvas.wrap('界界', 3), { '界', '界' }, 'a wide word splits by cells, not characters')
  H.eq(canvas.wrap('ab界cd', 3), { 'ab', '界c', 'd' }, 'a wide character that would cross the edge moves down')
  H.eq(canvas.wrap('界 界界', 4), { '界', '界界' }, 'at spaces where it can')
  H.eq(canvas.wrap('界', 1), { '界' }, 'a character wider than the line still ends')
  local e = 'e\u{301}'
  H.eq(canvas.wrap(e .. e, 1), { e, e }, 'a combining mark stays with its character')
  for _, w in ipairs({ 2, 3, 5 }) do
    for _, line in ipairs(canvas.wrap('一二三 四五 ab六七八九 x', w)) do
      H.eq(canvas.cells(line) <= w, true, ('%q fits in %d cells'):format(line, w))
    end
  end
end)
