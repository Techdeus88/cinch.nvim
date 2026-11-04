-- features/ui: the frame and its two panes, sizes, views, folding, filtering,
-- the pane following the cursor, the action keys, gf, and closing.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local api = vim.api

local beta_src, beta_dir = H.own('beta.nvim')
require('cinch').setup({
  confirm = false,
  spec = {
    {
      { H.src('alpha.nvim'), opts = { style = 'night' } },
      { beta_src },
      { H.src('delta.nvim'), cmd = 'DeltaGo', deps = { H.src('gamma') } },
      { H.src('dashy'), cmd = 'DashyGo' },
      { H.src('floaty'), cmd = 'FloatyGo' },
    },
  },
})

---@param win integer
---@return string[]
local function lines(win)
  return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
end

---@param win integer
---@param pat string
---@return integer?
local function line_of(win, pat)
  for i, l in ipairs(lines(win)) do
    if l:find(pat) then
      return i
    end
  end
end

--- Put the cursor on a line of the list, as j/k would, so the pane follows.
---@param win integer
---@param pat string
local function go(win, pat)
  api.nvim_win_set_cursor(win, { assert(line_of(win, pat), pat), 0 })
  api.nvim_exec_autocmds('CursorMoved', { buffer = api.nvim_win_get_buf(win) })
  vim.wait(20)
end

local function floats()
  return #vim.tbl_filter(function(w)
    return api.nvim_win_get_config(w).relative ~= ''
  end, api.nvim_list_wins())
end

H.after_startup(function()
  local ui = require('cinch.features.ui')
  H.eq(package.loaded['cinch.features.ui.plugins'], nil, 'the drawing code waits for the first open')
  H.commit(beta_dir, 'feat: from ui')

  -- The backdrop blends, which needs 'termguicolors'.
  vim.o.termguicolors = true
  vim.cmd('Cinch')
  local w = ui.windows()
  local bd = api.nvim_win_get_config(w.backdrop)
  H.eq(
    { bd.width, bd.height, bd.zindex < api.nvim_win_get_config(w.frame).zindex, vim.wo[w.backdrop].winblend },
    { vim.o.columns, vim.o.lines - vim.o.cmdheight, true, 60 },
    'a backdrop over the editor, under the window'
  )
  local lines_h = vim.o.lines - vim.o.cmdheight
  local frame = api.nvim_win_get_config(w.frame)
  H.eq(
    { frame.width, frame.height },
    { math.floor(vim.o.columns * 0.75), math.floor(lines_h * 0.75) },
    'a frame at 75%'
  )
  H.eq(api.nvim_get_current_win(), w.list, 'the cursor is in the list')
  H.eq(api.nvim_win_get_config(w.pane).hide, false, 'the pane shows')
  local pane_cfg = api.nvim_win_get_config(w.pane)
  H.eq(pane_cfg.row > api.nvim_win_get_config(w.list).row, true, 'under the list, in an 80-column editor')
  local title = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, frame.title))
  H.eq(
    title:find('cinch', 1, true) ~= nil and title:find('plugins  triggers  stats  log', 1, true) ~= nil,
    true,
    'title and tabs'
  )

  local u = require('cinch.features.updates')
  H.eq(u.checking, true, 'opening starts an update check')
  H.wait(function()
    return not u.checking
  end, 'the check')
  vim.wait(50)
  H.eq(lines(w.list)[line_of(w.list, ' beta%.nvim ')]:find('↑1') ~= nil, true, 'pending commits on the row')

  -- A row: the status light, the name, its load time and bar, then how it loads.
  local icons = require('cinch.features.ui.plugins').icons
  local alpha_row = lines(w.list)[line_of(w.list, ' alpha%.nvim ')]
  H.eq(alpha_row:find('● alpha.nvim (', 1, true) ~= nil, true, 'the lit light left of the name, then its load time')
  H.eq(vim.endswith(alpha_row, icons.later .. ' later'), true, 'later is its icon and name, with nothing after it')
  local delta_row = lines(w.list)[line_of(w.list, ' delta%.nvim ')]
  H.eq(
    delta_row:find('○ delta.nvim ' .. icons.cmd .. ' cmd DeltaGo', 1, true) ~= nil,
    true,
    'a trigger: its icon and value'
  )
  local gamma_row = lines(w.list)[line_of(w.list, ' gamma ')]
  H.eq(gamma_row:find('gamma ' .. icons.dep .. ' delta.nvim', 1, true) ~= nil, true, 'a dependency: what needs it')
  go(w.list, ' gamma ')
  H.eq(
    line_of(w.pane, '^ load +' .. icons.dep .. ' before its dependents$') ~= nil,
    true,
    'its pane: it loads before them'
  )
  H.eq(line_of(w.pane, '^ needed by +delta%.nvim') ~= nil, true, 'and which they are')
  H.eq(table.concat(lines(w.list), '\n'):find('by later', 1, true), nil, 'no "by later"')

  -- Working plugins sit on top, and the cursor moves freely while their spinner turns.
  local state = require('cinch.state')
  state.activity(H.plugin('beta.nvim'), 'building')
  vim.wait(50)
  H.eq(line_of(w.list, '▾ working'), 1, 'working comes first')
  H.eq(lines(w.list)[2]:find('beta%.nvim .*building…') ~= nil, true, 'with what it is doing')
  go(w.list, '▾ loaded')
  vim.wait(250)
  H.eq(api.nvim_win_get_cursor(w.list)[1], line_of(w.list, '▾ loaded'), 'the spinner leaves the cursor on a title')
  state.activity(H.plugin('beta.nvim'), nil)
  vim.wait(50)

  go(w.list, ' alpha%.nvim ')
  H.eq(lines(w.pane)[1]:find('alpha', 1, true) ~= nil, true, 'the pane follows the cursor')
  H.eq(line_of(w.pane, "require%('alpha'%)%.setup%(opts%)") ~= nil, true, 'with what config called')
  H.eq(line_of(w.pane, 'style = "night"') ~= nil, true, 'and the opts it got')
  H.eq(line_of(w.pane, 'ui%.lua:%d+') ~= nil, true, 'and where its spec is')
  local function top()
    return vim.fn.getwininfo(w.pane)[1].topline
  end
  H.press('<C-d>')
  H.eq(top() > 1, true, '<C-d> scrolls the pane')
  H.press('<C-u>')
  H.eq(top(), 1, '<C-u> back up')
  H.press('<C-d>')
  go(w.list, ' beta%.nvim ')
  H.eq(top(), 1, 'another plugin starts at its top')
  go(w.list, ' alpha%.nvim ')
  -- Long paths wrap under themselves; read them whole.
  local pane = table.concat(lines(w.pane), '\n'):gsub('\n' .. (' '):rep(11), '')
  H.eq(pane:find('dir +/[^\n]*/pack/core/opt/alpha%.nvim\n') ~= nil, true, 'its folder')
  H.eq(pane:find('url +file://[^\n]*alpha%.nvim\n') ~= nil, true, 'its url')
  H.eq(line_of(w.pane, '^ commit +' .. H.plugin('alpha.nvim').rev:sub(1, 7)) ~= nil, true, 'the commit on disk')
  H.eq(line_of(w.pane, '^ readme +README%.md') ~= nil, true, 'its readme')
  H.wait(function()
    return line_of(w.pane, '^ branch +main') ~= nil
  end, 'the branch it follows, once vim.pack.get has answered')

  H.press('=')
  H.eq(api.nvim_win_get_config(w.frame).width, math.floor(vim.o.columns * 0.95), '= stretches to 95%')
  H.press('=')
  H.eq(api.nvim_win_get_config(w.frame).width, math.floor(vim.o.columns * 0.75), '= again goes back')

  go(w.list, '▾ loaded')
  H.press('<CR>')
  H.eq(line_of(w.list, '▸ loaded') ~= nil and line_of(w.list, ' alpha%.nvim ') == nil, true, '<CR> folds a section')
  H.press('<CR>')
  H.eq(line_of(w.list, ' alpha%.nvim ') ~= nil, true, 'and opens it again')

  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.input = function(_, cb)
    cb('del')
  end
  H.press('/')
  vim.wait(30)
  H.eq(line_of(w.list, ' alpha%.nvim ') == nil and line_of(w.list, ' delta%.nvim ') ~= nil, true, '/ filters by name')
  go(w.list, ' delta%.nvim ')
  H.press('l')
  H.eq(H.plugin('delta.nvim').state, 'loaded', 'l loads the plugin under the cursor')
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.input = function(_, cb)
    cb('')
  end
  H.press('/')
  vim.wait(30)
  H.eq(line_of(w.list, ' alpha%.nvim ') ~= nil, true, 'an empty filter clears it')

  -- Plugins that grab the current window as they load must not close or take over cinch.
  local editor = vim.fn.win_getid(1)
  go(w.list, ' dashy ')
  H.press('l')
  H.eq(ui.is_open(), true, 'a plugin opening a buffer as it loads leaves the window open')
  H.eq(vim.b[api.nvim_win_get_buf(editor)].dashy, true, 'its buffer opened in your editor window')
  H.eq(vim.bo[api.nvim_win_get_buf(w.list)].filetype, 'cinch', 'not in cinch')
  go(w.list, ' floaty ')
  H.press('l')
  H.eq(ui.is_open(), true, 'a plugin opening a focused float leaves the window open')
  api.nvim_win_close(vim.g.floaty_win, true)
  api.nvim_set_current_win(w.list)
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.input = function(_, cb)
    -- An input plugin: a focused float, then the answer.
    local win = api.nvim_open_win(
      api.nvim_create_buf(false, true),
      true,
      { relative = 'editor', row = 1, col = 1, width = 20, height = 1 }
    )
    api.nvim_win_close(win, true)
    cb('')
  end
  H.press('/')
  vim.wait(30)
  H.eq(ui.is_open(), true, 'an input prompt in a float leaves the window open')
  api.nvim_set_current_win(w.list)
  api.nvim_set_current_win(editor)
  vim.wait(30)
  H.eq(api.nvim_get_current_win(), w.list, 'the cursor cannot leave for an editor window')

  go(w.list, ' beta%.nvim ')
  H.press('u')
  H.eq(u.results['beta.nvim'], nil, 'u applies its update')

  H.press('<Tab>')
  H.eq(line_of(w.list, ' commands %d') ~= nil, true, '<Tab> goes to triggers')
  H.eq(api.nvim_win_get_config(w.pane).hide, false, 'with the details pane')
  go(w.list, ':DeltaGo')
  H.eq(lines(w.pane)[1]:find('cmd :DeltaGo', 1, true) ~= nil, true, 'which follows the trigger under the cursor')
  H.eq(line_of(w.pane, 'delta%.nvim') ~= nil, true, 'and shows its plugins')
  H.press('<Tab>')
  H.eq(api.nvim_win_get_config(w.pane).hide, true, 'stats uses the whole width')
  H.eq(line_of(w.list, '^ startup') ~= nil and line_of(w.list, '^ slowest') ~= nil, true, 'then stats')
  H.press('<Tab>')
  H.eq(line_of(w.list, '^ %d%d:%d%d:%d%d ') ~= nil, true, 'then log')
  H.press('<Tab>')
  H.eq(api.nvim_win_get_config(w.pane).hide, false, 'then back to plugins, with the pane')
  H.press('<S-Tab>')
  H.eq(line_of(w.list, '^ %d%d:%d%d:%d%d ') ~= nil, true, '<S-Tab> goes back')
  H.press('?')
  H.eq(line_of(w.list, '^ keys') ~= nil, true, '? shows the keys')
  H.press('?')

  vim.cmd('Cinch open plugins')
  go(w.list, ' alpha%.nvim ')
  H.press('gf')
  vim.wait(30)
  H.eq(ui.is_open(), false, 'gf closes the window')
  H.eq(api.nvim_buf_get_name(0):find('ui%.lua$') ~= nil, true, 'and opens the spec file')
  H.eq(api.nvim_get_current_line():find('alpha.nvim', 1, true) ~= nil, true, 'at the plugin')

  vim.cmd('Cinch open stats')
  H.eq(floats(), 4, 'backdrop, frame, list and pane')
  H.press('q')
  vim.wait(30)
  H.eq(floats(), 0, 'q closes all four')
end)
