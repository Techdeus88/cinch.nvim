-- A plugin that is off: its name dim but upright, an `off` chip where how it loads would
-- go, and why, the way its spec says it.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = {
    {
      { H.src('alpha.nvim'), enabled = false },
      {
        H.src('beta.nvim'),
        cond = function()
          return false
        end,
      },
      { H.src('gamma'), cond = false },
    },
  },
})

H.after_startup(function()
  local ui = require('cinch.features.ui')
  ui.open('plugins')
  local buf = vim.api.nvim_win_get_buf(ui.windows().list)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  ---@param name string
  ---@return integer? row 0-based
  local function row_of(name)
    for i, l in ipairs(lines) do
      if l:find(' ' .. name .. ' ', 1, true) then
        return i - 1
      end
    end
  end
  local off = require('cinch.features.ui.rows').glyph('off') .. ' off'
  for name, why in pairs({
    ['alpha.nvim'] = 'enabled = false',
    ['beta.nvim'] = 'cond() returned false',
    gamma = 'cond = false',
  }) do
    local row = row_of(name)
    H.eq(row ~= nil, true, name .. ' has a row')
    ---@cast row integer
    local line = lines[row + 1]
    H.eq(
      line:find(' ✕ ' .. name .. ' ' .. off .. ' ' .. why, 1, true) ~= nil,
      true,
      name .. ': an X, the off chip, then ' .. why
    )
  end

  -- The name's own group: dim like a comment, not italic.
  local row = row_of('alpha.nvim')
  local col = lines[row + 1]:find('alpha.nvim', 1, true) - 1
  local groups = {}
  for _, m in
    ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { row, col }, { row, col }, { details = true, overlap = true }))
  do
    groups[#groups + 1] = m[4].hl_group
  end
  H.eq(vim.list_contains(groups, 'CinchOffName'), true, 'the name in CinchOffName')
  H.eq(vim.api.nvim_get_hl(0, { name = 'CinchOffName' }).italic, nil, 'which is upright')
end)
