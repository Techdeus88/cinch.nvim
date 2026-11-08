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
    title:find('cinch', 1, true) ~= nil and title:find('plugins  triggers  stats  profile  log', 1, true) ~= nil,
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

  -- A row: the status light, the name, its load time and bar, then how it loads,
  -- each kind on a chip of its own color.
  local icons = require('cinch.features.ui.plugins').icons
  ---@param l integer
  ---@return table<string, true> the groups on that line of the list
  local function groups(l)
    local res = {}
    local marks = api.nvim_buf_get_extmarks(
      api.nvim_win_get_buf(w.list),
      -1,
      { l - 1, 0 },
      { l - 1, -1 },
      { details = true }
    )
    for _, m in ipairs(marks) do
      res[m[4].hl_group or m[4].line_hl_group or ''] = true
    end
    return res
  end
  local alpha_at = assert(line_of(w.list, ' alpha%.nvim '))
  local alpha_row = lines(w.list)[alpha_at]
  H.eq(alpha_row:find('● alpha.nvim (', 1, true) ~= nil, true, 'the lit light left of the name, then its load time')
  H.eq(alpha_row:find(icons.later .. ' later', 1, true) ~= nil, true, 'later: its icon and name')
  H.eq(groups(alpha_at).CinchKindLater, true, 'on a chip of the later color')
  H.eq(alpha_row:find('\u{e0b6}', 1, true), nil, 'square, with no rounded ends')
  local delta_at = assert(line_of(w.list, ' delta%.nvim '))
  H.eq(lines(w.list)[delta_at]:find(icons.cmd .. ' cmd .* DeltaGo') ~= nil, true, 'a trigger: its chip, then its value')
  H.eq(groups(delta_at).CinchKindCmd, true, 'in the command color')
  local gamma_at = assert(line_of(w.list, ' gamma '))
  H.eq(
    lines(w.list)[gamma_at]:find(icons.dep .. ' dep .* delta%.nvim') ~= nil,
    true,
    'a dependency: dep, then who needs it'
  )
  H.eq(groups(gamma_at).CinchDepName, true, 'its name in the dependency style')
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
  -- Long paths wrap under themselves; read them whole.
  local function whole_pane()
    return (table.concat(lines(w.pane), '\n'):gsub('\n' .. (' '):rep(11), ''))
  end
  H.eq(whole_pane():find('ui%.lua:%d+') ~= nil, true, 'and where its spec is')
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
  local pane = whole_pane()
  H.eq(pane:find('dir +[^\n]*/pack/core/opt/alpha%.nvim\n') ~= nil, true, 'its folder')
  H.eq(pane:find('url +file://[^\n]*alpha%.nvim\n') ~= nil, true, 'its url')
  H.eq(line_of(w.pane, '^ commit +' .. H.plugin('alpha.nvim').rev:sub(1, 7)) ~= nil, true, 'the commit on disk')
  H.eq(line_of(w.pane, '^ readme +README%.md') ~= nil, true, 'its readme')
  H.wait(function()
    return line_of(w.pane, '^ branch +main') ~= nil
  end, 'the branch it follows, once vim.pack.get has answered')

  -- Select two, and l loads both; the selection is done with after.
  ---@return integer rows with the selection shade
  local function shaded()
    local marks = api.nvim_buf_get_extmarks(api.nvim_win_get_buf(w.list), -1, 0, -1, { details = true })
    return #vim.tbl_filter(function(m)
      return m[4].line_hl_group == 'CinchMarked'
    end, marks)
  end
  go(w.list, ' alpha%.nvim ')
  H.press('<S-CR>')
  H.eq(shaded(), 1, '<S-CR> shades the plugin row it selects')
  go(w.list, ' delta%.nvim ')
  H.press('<S-CR>')
  H.eq(shaded(), 2, 'and the next')
  H.press('l')
  H.eq(H.plugin('delta.nvim').state, 'loaded', 'l loads every selected plugin')
  H.eq(shaded(), 0, 'and lets go of them')

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
  H.eq(api.nvim_win_get_config(w.pane).hide, true, 'profile uses the whole width')
  H.eq(line_of(w.list, '^ in order') ~= nil and line_of(w.list, '^ ▾ cinch ') ~= nil, true, 'then profile')
  H.eq(line_of(w.list, '^ profile'), nil, 'its name only on the frame')
  local start_at, done_at = line_of(w.list, '^   CinchStart '), line_of(w.list, '^   CinchDone ')
  local enter_at = line_of(w.list, '^   VimEnter ')
  H.eq(start_at ~= nil and done_at ~= nil and enter_at ~= nil, true, 'the moments of startup')
  H.eq(start_at < done_at and done_at < enter_at, true, 'in the order they happened')
  H.eq(lines(w.list)[done_at]:find('(+', 1, true) ~= nil, true, 'each with the time since the one before')
  H.eq(line_of(w.list, '^ ▾ plugin files at startup ') ~= nil, true, 'with the files sourced at startup')
  H.eq(line_of(w.list, '^   ▾ .*alpha%.nvim  later') ~= nil, true, 'a later plugin under later')
  H.eq(line_of(w.list, '^     ▾ packadd ') ~= nil, true, 'the steps of its load')
  H.eq(line_of(w.list, '^         plugin/alpha%.lua ') ~= nil, true, 'holding the files they sourced')
  H.press('<C-s>')
  H.eq(line_of(w.list, ' by time') ~= nil, true, '<C-s> sorts by time')
  H.press('<C-s>')
  H.eq(line_of(w.list, ' in order') ~= nil, true, 'and back to order')
  vim.ui.input = function(_, cb)
    cb('100000')
  end
  H.press('<C-f>')
  vim.wait(20)
  H.eq(line_of(w.list, 'alpha%.nvim') == nil and line_of(w.list, ' over ') ~= nil, true, '<C-f> hides what took less')
  vim.ui.input = function(_, cb)
    cb('')
  end
  H.press('<C-f>')
  vim.wait(20)
  H.eq(line_of(w.list, 'alpha%.nvim') ~= nil, true, 'empty shows it all again')
  go(w.list, '^ ▾ later ')
  H.press('<CR>')
  local later_alpha = '^   ▾ .*alpha%.nvim  later'
  H.eq(line_of(w.list, '^ ▸ later ') ~= nil and line_of(w.list, later_alpha) == nil, true, '<CR> folds a node')
  H.press('<CR>')
  H.eq(line_of(w.list, later_alpha) ~= nil, true, 'and opens it')
  H.eq(line_of(w.list, '^ ▾ builds and vim%.pack ') ~= nil, true, 'then builds and vim.pack runs')
  H.eq(line_of(w.list, '^     update beta%.nvim ') ~= nil, true, 'an update, by its plugin')
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
