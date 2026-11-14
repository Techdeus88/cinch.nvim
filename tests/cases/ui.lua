-- features/ui: the header, the two panes and the footer, sizes, views, folding, filtering,
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
    { bd.width, bd.height, bd.zindex < api.nvim_win_get_config(w.header).zindex, vim.wo[w.backdrop].winblend },
    { vim.o.columns, vim.o.lines - vim.o.cmdheight, true, 60 },
    'a backdrop over the editor, under the window'
  )
  local lines_h = vim.o.lines - vim.o.cmdheight
  --- The cells the four windows take, borders included: { width, height }.
  local function size()
    local head, foot = api.nvim_win_get_config(w.header), api.nvim_win_get_config(w.footer)
    return { head.width + 2, foot.row + foot.height + 2 - head.row }
  end
  H.eq(size(), { math.floor(vim.o.columns * 0.75), math.floor(lines_h * 0.75) }, 'four windows at 75%')
  local head_cfg, list_cfg = api.nvim_win_get_config(w.header), api.nvim_win_get_config(w.list)
  local pane_cfg, foot_cfg = api.nvim_win_get_config(w.pane), api.nvim_win_get_config(w.footer)
  H.eq(
    { list_cfg.row, pane_cfg.row, foot_cfg.row, head_cfg.height, foot_cfg.height },
    { head_cfg.row + 4, list_cfg.row + list_cfg.height + 2, pane_cfg.row + pane_cfg.height + 2, 2, 1 },
    'the header on top, two lines, then the list, the pane under it, and the footer, one line'
  )
  H.eq(api.nvim_get_current_win(), w.list, 'the cursor is in the list')
  H.eq(api.nvim_win_get_config(w.pane).hide, false, 'the pane shows')
  H.eq(pane_cfg.col, list_cfg.col, 'the pane under the list, in an 80-column editor')
  local title = lines(w.header)[1]
  H.eq(
    title:find('^ %d+ plugins') ~= nil and title:find('plugins  triggers  stats  profile  log $') ~= nil,
    true,
    'the counts on the left of the header, the tabs on the right'
  )
  H.eq(vim.fn.strdisplaywidth(title), head_cfg.width, 'all of it in view, in an 80-column editor')
  local layout_ = require('cinch.features.ui.layout')
  --- The header's second line, `width` cells, with `op` under way.
  local function row2(width, op)
    local chunks = layout_.header(width, { views = ui.views, view = 'plugins', op = op })[2]
    return table.concat(vim.tbl_map(function(c)
      return c[1]
    end, chunks))
  end
  local by = { loaded = 0, waiting = 0, disabled = 0, failed = 0 }
  for _, p in ipairs(require('cinch.state').yours()) do
    local k = (p.state == 'pending' or p.state == 'registered') and 'waiting' or p.state
    by[k] = (by[k] or 0) + 1
  end
  local kinds = { { '●', by.loaded, 'loaded' }, { '○', by.waiting, 'waiting' } }
  vim.list_extend(kinds, { { '✗', by.failed, 'failed' }, { '✕', by.disabled, 'disabled' } })
  local labeled, bare = {}, {}
  for _, c in ipairs(kinds) do
    if c[2] > 0 then
      labeled[#labeled + 1] = ('%s %d %s'):format(c[1], c[2], c[3])
      bare[#bare + 1] = ('%s %d'):format(c[1], c[2])
    end
  end
  H.eq(#labeled < 4, true, 'some state has none, so this checks that it is left out')
  local wide = row2(148)
  local absent = true
  for _, c in ipairs(kinds) do
    absent = absent and (c[2] > 0 or not wide:find(c[1], 1, true))
  end
  labeled, bare = ' ' .. table.concat(labeled, '  ') .. ' ', ' ' .. table.concat(bare, '  ') .. ' '
  H.eq(
    vim.startswith(wide, labeled) and absent,
    true,
    'the second line: the count in each state with its label, none left out: ' .. wide
  )
  H.eq(lines(w.header)[2]:find('Checking plugins', 1, true) ~= nil, true, 'then the check that opening started')

  -- Short of room for what is under way, the labels go, then the counts.
  local check = { kind = 'check', total = 6, done = 0, status = {} }
  local need = vim.fn.strdisplaywidth('Checking plugins (0/6) 0% ') + 6 + 2
  local function tier(width)
    local r = row2(width, check)
    return {
      vim.startswith(r, labeled),
      vim.startswith(r, bare),
      r:find('●', 1, true) ~= nil,
      r:find('Checking') ~= nil,
    }
  end
  local lw, bw = vim.fn.strdisplaywidth(labeled), vim.fn.strdisplaywidth(bare)
  H.eq(tier(lw + need), { true, false, true, true }, 'room for all of it')
  H.eq(tier(lw + need - 1), { false, true, true, true }, 'a cell short: the labels go')
  H.eq(tier(bw + need - 1), { false, false, false, true }, 'shorter still: the counts make way')
  local one = require('cinch.state').yours()[1]
  local was = one.state
  one.state = 'failed'
  local failed_row = row2(148)
  one.state = was
  H.eq(failed_row:find(' ✗ 1 failed ', 1, true) ~= nil, true, 'a failed plugin is counted: ' .. failed_row)

  -- In a wide header the name sits in the middle, on a banner, and the keys sit on a
  -- banner in the middle of the footer.
  local layout = require('cinch.features.ui.layout')
  local shape = { opts = ui.opts, view = 'plugins', views = ui.views, help = false, split = true }
  local head = layout.header(148, shape)[1]
  local before, banner_at, total = 0, nil, 0
  for i, c in ipairs(head) do
    if c[2] == 'CinchBanner' and vim.trim(c[1]) == 'cinch' then
      banner_at = i
    end
  end
  assert(banner_at, 'the name is on a banner')
  local first = banner_at - (head[banner_at - 1][2] == 'CinchBannerCap' and 1 or 0)
  local last = banner_at + (head[banner_at + 1][2] == 'CinchBannerCap' and 1 or 0)
  local name_w = 0
  for i, c in ipairs(head) do
    local w_ = vim.fn.strdisplaywidth(c[1])
    total = total + w_
    if i < first then
      before = before + w_
    elseif i <= last then
      name_w = name_w + w_
    end
  end
  H.eq(total, 148, 'the header line fills its window')
  H.eq(math.abs(before - (total - before - name_w)) <= 1, true, 'with the name in the middle')
  local foot = layout.footer(148, { { '/', 'filter' }, { 'q', 'close' } })
  local function parts(group)
    return vim.tbl_map(
      function(c)
        return vim.trim(c[1])
      end,
      vim.tbl_filter(function(c)
        return c[2] == group
      end, foot)
    )
  end
  H.eq(parts('CinchFooterKey'), { '/', 'q' }, 'each key on its own inset')
  H.eq(parts('CinchBanner'), { 'filter', 'close' }, 'with what it does beside it, on the banner')
  local pad = vim.fn.strdisplaywidth(foot[1][1])
  local keys_w = 0
  for i = 2, #foot do
    keys_w = keys_w + vim.fn.strdisplaywidth(foot[i][1])
  end
  H.eq(math.abs(pad - (148 - pad - keys_w)) <= 1, true, 'in the middle of the footer')
  local narrow = layout.footer(40, require('cinch.features.ui.keys').hints.plugins)
  local narrow_text = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, narrow))
  H.eq(vim.fn.strdisplaywidth(narrow_text) <= 40, true, 'a narrow footer fits')
  H.eq(
    { narrow_text:find(' ? ', 1, true) ~= nil, narrow_text:find(' close ', 1, true) ~= nil },
    { true, true },
    'and keeps ? and q'
  )

  local u = require('cinch.features.updates')
  H.eq(u.checking, true, 'opening starts an update check')
  H.wait(function()
    return not u.checking
  end, 'the check')
  vim.wait(50)
  H.eq(
    lines(w.list)[line_of(w.list, ' beta%.nvim ')]:find('beta.nvim 1 commit', 1, true) ~= nil,
    true,
    'commits behind'
  )

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
  H.eq(groups(alpha_at).CinchKindLaterText, true, 'in the later color, with no shade behind it')
  H.eq(groups(alpha_at).CinchKindLater, nil, 'and no chip')
  H.eq(alpha_row:find('\u{e0b6}', 1, true), nil, 'square, with no rounded ends')
  local delta_at = assert(line_of(w.list, ' delta%.nvim '))
  H.eq(lines(w.list)[delta_at]:find(icons.cmd .. ' cmd.* DeltaGo') ~= nil, true, 'a trigger: its chip, then its value')
  H.eq(groups(delta_at).CinchKindCmdText, true, 'in the command color')
  local gamma_at = assert(line_of(w.list, ' gamma '))
  H.eq(
    lines(w.list)[gamma_at]:find(icons.dep .. ' dep.* delta%.nvim') ~= nil,
    true,
    'a dependency: dep, then who needs it'
  )
  H.eq(groups(gamma_at).CinchDepName, true, 'its name in the dependency style')
  go(w.list, ' gamma ')
  H.eq(line_of(w.pane, '^ load +' .. icons.dep .. ' before dependents$') ~= nil, true, 'its pane: it loads before them')
  H.eq(line_of(w.pane, '^ needed by +delta%.nvim') ~= nil, true, 'and which they are')
  H.eq(table.concat(lines(w.list), '\n'):find('by later', 1, true), nil, 'no "by later"')

  -- Working plugins sit on top, and the cursor moves freely while their spinner turns.
  local state = require('cinch.state')
  state.activity(H.plugin('beta.nvim'), 'building')
  vim.wait(50)
  local working = line_of(w.list, '▾ working 1')
  H.eq(working ~= nil and working < line_of(w.list, ' alpha%.nvim '), true, 'working comes first, under its title')
  H.eq(lines(w.list)[working + 1]:find('beta%.nvim .*building…') ~= nil, true, 'with what it is doing')
  H.eq(line_of(w.list, '▾ loaded'), nil, 'the states the header counts have no title')
  go(w.list, '▾ working')
  H.press('<CR>')
  H.eq(line_of(w.list, '▸ working 1') ~= nil and line_of(w.list, 'building…') == nil, true, 'it folds')
  H.press('<CR>')
  go(w.list, ' alpha%.nvim ')
  vim.wait(250)
  H.eq(
    api.nvim_win_get_cursor(w.list)[1],
    line_of(w.list, ' alpha%.nvim '),
    'the spinner leaves the cursor where it is'
  )
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

  go(w.list, ' floaty ')
  H.press('u')
  H.eq(line_of(w.list, ' floaty .*all good to go') ~= nil, true, 'u with no update says so on the row')
  H.eq(table.concat(H.header(), '\n'):find('all good to go', 1, true), nil, 'not in the header')
  H.press('-')
  H.eq(size(), { math.floor(vim.o.columns * 0.75), math.floor(lines_h * 0.95) }, '- makes it 95% tall')
  H.press('-')
  H.eq(size(), { math.floor(vim.o.columns * 0.75), math.floor(lines_h * 0.75) }, '- again goes back')
  -- Wide enough for the pane beside the list: 150 columns at 75%.
  local cols = vim.o.columns
  vim.o.columns = 200
  vim.wait(20)
  local function widths()
    return { api.nvim_win_get_config(w.list).width + 2, api.nvim_win_get_config(w.pane).width + 2 }
  end
  H.eq(widths(), { 105, 45 }, 'the list and the pane 70/30')
  H.press('=')
  H.eq(widths(), { 75, 75 }, '= makes them 50/50')
  H.press('=')
  H.eq(widths(), { 105, 45 }, '= again goes back')
  vim.o.columns = cols
  vim.wait(20)

  go(w.list, '▾ Updates')
  H.press('<CR>')
  H.eq(line_of(w.list, '▸ Updates') ~= nil and line_of(w.list, ' beta%.nvim ') == nil, true, '<CR> folds a section')
  H.press('<CR>')
  H.eq(line_of(w.list, ' beta%.nvim ') ~= nil, true, 'and opens it again')

  -- cinch takes the text itself: no input prompt of Neovim's or a plugin's.
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.input = function()
    error('vim.ui.input was called')
  end
  ---@return string
  local function footer()
    return lines(w.footer)[1]
  end
  -- Queued, then read by cinch key by key.
  local typing = {}
  api.nvim_feedkeys(vim.keycode('ab<BS>c<CR>'), 't', false)
  ui.input({
    prompt = 'filter: ',
    change = function()
      typing[#typing + 1] = footer()
    end,
    done = function(text)
      typing[#typing + 1] = text
    end,
  })
  H.eq(typing[#typing], 'ac', 'cinch reads what you type, key by key')
  H.eq(table.concat(typing, '|'):find('filter: ab▏', 1, true) ~= nil, true, 'and shows it in the footer as you type')
  H.press('/del<CR>')
  H.eq(line_of(w.list, ' alpha%.nvim ') == nil and line_of(w.list, ' delta%.nvim ') ~= nil, true, '/ filters by name')
  H.eq(footer():find('filter:', 1, true), nil, 'and the prompt leaves the footer')
  go(w.list, ' delta%.nvim ')
  H.press('l')
  H.eq(H.plugin('delta.nvim').state, 'loaded', 'l loads the plugin under the cursor')
  H.press('/<C-u><CR>')
  H.eq(line_of(w.list, ' alpha%.nvim ') ~= nil, true, 'an empty filter clears it')
  H.press('/zzz<Esc>')
  H.eq(line_of(w.list, ' alpha%.nvim ') ~= nil, true, '<Esc> gives the filter up')

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
  H.eq(line_of(w.list, '^ profile'), nil, 'its name only in the header')
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
  H.press('<C-f>100000<CR>')
  H.eq(line_of(w.list, 'alpha%.nvim') == nil and line_of(w.list, ' over ') ~= nil, true, '<C-f> hides what took less')
  H.press('<C-f><C-u><CR>')
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
  H.eq(floats(), 5, 'backdrop, header, list, pane and footer')
  H.press('q')
  vim.wait(30)
  H.eq(floats(), 0, 'q closes all five')
end)
