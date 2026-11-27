-- Groups in cinch's window: the chip, the pane lines and `/group:` in Plugins, the
-- Groups tab before Triggers, and <C-g> listing Plugins by group.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
vim.opt.rtp:prepend(assert(vim.env.CINCH_GROUPS_ROOT))
local api = vim.api

require('cinch-groups').setup({
  confirm = false,
  features = { 'messages', 'ui' },
  spec = {
    {
      {
        group = 'git',
        cmd = 'AlphaCmd',
        { H.src('alpha.nvim'), deps = { H.src('opy') } },
        { H.src('beta.nvim'), cmd = 'BetaGo' },
      },
      { group = 'lsp', order = 10, ft = 'lua', { H.src('gamma') } },
      { H.src('delta.nvim') },
    },
  },
})

---@param win integer?
---@return string[]
local function lines(win)
  return win and api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false) or {}
end

---@param pattern string
---@return integer?
local function line_of(pattern)
  for i, l in ipairs(lines(require('cinch.features.ui').windows().list)) do
    if l:find(pattern) then
      return i
    end
  end
end

---@param pattern string
---@return boolean
local function pane_has(pattern)
  return vim.iter(lines(require('cinch.features.ui').windows().pane)):any(function(l)
    return l:find(pattern) ~= nil
  end)
end

---@param line integer
local function cursor(line)
  local w = require('cinch.features.ui').windows()
  api.nvim_win_set_cursor(w.list, { line, 0 })
  api.nvim_exec_autocmds('CursorMoved', { buffer = api.nvim_win_get_buf(w.list) })
end

H.after_startup(function()
  -- Wide enough that no row is cut.
  vim.o.columns = 240
  local ui = require('cinch.features.ui')
  ui.open('plugins')
  H.wait(function()
    return line_of('alpha%.nvim.*AlphaCmd') ~= nil
  end, 'the plugins list')
  H.eq(H.header()[1]:find('plugins  groups  triggers', 1, true) ~= nil, true, 'Groups is the tab before Triggers')

  local row = assert(line_of('alpha%.nvim.*AlphaCmd'))
  H.eq(lines(ui.windows().list)[row]:find('\u{f247} git', 1, true) ~= nil, true, 'a row has its group chip')
  local delta = lines(ui.windows().list)[assert(line_of('delta%.nvim'))]
  H.eq(delta:find('\u{f247} [%w_]*groups_ui') ~= nil, true, "an inline spec's chip is its file's group")

  cursor(row)
  H.eq(pane_has('group +git · wraps its spec'), true, 'the pane says its group and how it joined')
  H.eq(pane_has('took .*AlphaCmd'), true, 'and what it took from it')
  cursor(assert(line_of('beta%.nvim')))
  H.eq(pane_has('took'), false, 'one whose own cmd replaces the group one took nothing')

  cursor(assert(line_of('opy')))
  H.eq(pane_has('group +dependencies · dependency'), true, 'a dependency is in dependencies')

  H.press('/group:lsp<CR>')
  H.eq({ line_of('gamma') ~= nil, line_of('alpha%.nvim.*AlphaCmd') }, { true, nil }, '/group:lsp shows only that group')
  H.press('/<C-u><CR>')

  H.press('<C-g>')
  H.eq(line_of('▾ lsp 0/1') ~= nil, true, '<C-g> lists the plugins by group')
  H.eq(line_of('lsp 0/1') < assert(line_of('git 0/2')), true, 'groups in order')
  H.eq(
    { line_of('groups_ui 1/1') ~= nil, line_of('no group') },
    { true, nil },
    'every plugin in a group, none in no group'
  )
  H.press('?')
  H.eq(line_of('<C%-g>.*list by group or by state') ~= nil, true, 'the ? screen has the key')
  H.press('?')
  H.press('<C-g>')
  H.eq(line_of('▾ lsp'), nil, 'and <C-g> again lists them by state')

  ui.open('groups')
  local git = assert(line_of('git'))
  H.eq(lines(ui.windows().list)[git]:find('○ git 100', 1, true) ~= nil, true, 'Groups: a row per group')
  H.eq(lines(ui.windows().list)[git]:find('0/2', 1, true) ~= nil, true, 'with how many have loaded')
  H.eq(line_of('○ lsp 10') < git, true, 'in order')
  cursor(git)
  H.eq({ pane_has('order +100'), pane_has('alpha%.nvim +wraps its spec') }, { true, true }, 'its pane')

  H.press('<CR>')
  H.eq(line_of('beta%.nvim') ~= nil, true, '<CR> opens a group')
  cursor(git)
  H.press('l')
  H.eq({ H.plugin('alpha.nvim').state, H.plugin('beta.nvim').state }, { 'loaded', 'loaded' }, 'l loads the group')
  H.eq(lines(ui.windows().list)[git]:find('● git', 1, true) ~= nil, true, 'and its light comes on')
end)
