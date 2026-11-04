-- The cinch window: a bordered frame over the editor, 75% of it, 95% with `=`.
-- Inside, the Plugins view is two panes: the list, which has the cursor, and the
-- detail pane, which follows it. Stats and Log use the whole width. The title and
-- tabs sit in the top border and the keys in the bottom one. At startup this file
-- only declares `:Cinch open`; drawing code and subscriptions wait for the first open.

local events = require('cinch.events')
local state = require('cinch.state')

local api, uv = vim.api, vim.uv

local M = {}

---@class cinch.ui.Opts
---@field size? number share of the editor, default 0.75
---@field wide? number share after `=`, default 0.95
---@field split? number the list's share of the width in the Plugins view, default 0.58
---@field border? string|string[] default: 'winborder', or rounded when that is empty

---@type cinch.ui.Opts
M.opts = { size = 0.75, wide = 0.95, split = 0.58 }

M.views = { 'plugins', 'stats', 'log' }

local ui = {
  frame = nil, ---@type integer? window
  list = nil, ---@type integer? window
  pane = nil, ---@type integer? window
  view = 'plugins',
  wide = false,
  help = false,
  selected = nil, ---@type string? plugin under the cursor
  canvas = nil, ---@type cinch.ui.Canvas? what the list shows
  queued = false,
  subscribed = false,
  timer = nil, ---@type uv.uv_timer_t?
  ---@type cinch.ui.Ctx
  ctx = { folded = {}, tick = 0, info = {}, spec_lines = {} },
}

local ns = api.nvim_create_namespace('cinch_ui')

local function canvas()
  return require('cinch.features.ui.canvas')
end
local function plugins()
  return require('cinch.features.ui.plugins')
end
local function dashboard()
  return require('cinch.features.ui.dashboard')
end
---@return table?
local function updates()
  return package.loaded['cinch.features.updates']
end

---@param win? integer
---@return boolean
local function valid(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

---@return boolean
function M.is_open()
  return valid(ui.list)
end

-- Layout ------------------------------------------------------------------------

local border_line = { rounded = '─', single = '─', double = '═', bold = '━', solid = ' ', shadow = ' ' }

---@return string|string[]
local function border()
  return M.opts.border or (vim.o.winborder ~= '' and vim.o.winborder or 'rounded')
end

--- The title row: name and counts on the left, the tabs on the right, the border's
--- own line between them.
---@param width integer
---@return { [1]: string, [2]: string }[]
local function title(width)
  local cv = canvas()
  local stats = package.loaded['cinch.features.stats']
  local startup = stats and (stats.marks.uienter or stats.marks.vimenter)
  local left = {
    { ' cinch ', 'CinchTitle' },
    { ('· %d plugins%s '):format(#state.list, startup and (' · startup ' .. cv.ms(startup)) or ''), 'CinchMuted' },
  }
  local tabs = {}
  for _, v in ipairs(M.views) do
    tabs[#tabs + 1] = { ' ' .. v .. ' ', v == ui.view and not ui.help and 'CinchTab' or 'CinchMuted' }
  end
  local used = 0
  for _, ch in ipairs(vim.list_extend(vim.list_slice(left), tabs)) do
    used = used + cv.cells(ch[1])
  end
  local b = border()
  local line = type(b) == 'string' and border_line[b] or '─'
  local fill = math.max(1, width - used - 2)
  return vim.list_extend(vim.list_extend(left, { { line:rep(fill), 'FloatBorder' } }), tabs)
end

local hints = {
  plugins = ' j/k move  <CR> fold  / filter  l load  b build  u update  U all  c check  gf spec'
    .. '  ? help  = size  q close ',
  stats = ' <Tab> next view  = size  q close ',
  log = ' / filter  G newest  <Tab> next view  = size  q close ',
  help = ' any key goes back ',
}

---@param width integer
---@return { [1]: string, [2]: string }[]
local function footer(width)
  local text = hints[ui.help and 'help' or ui.view]
  if ui.ctx.install then
    text = " installing · keys you press now run when it's done · q hides this "
  end
  return { { canvas().fit(text, math.min(canvas().cells(text), width - 2)), 'CinchMuted' } }
end

---@return table<string, vim.api.keyset.win_config>
local function layout()
  local share = ui.wide and M.opts.wide or M.opts.size
  local lines = vim.o.lines - vim.o.cmdheight
  local w = math.max(40, math.floor(vim.o.columns * share))
  local h = math.max(10, math.floor(lines * share))
  local row = math.max(0, math.floor((lines - h) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - w) / 2) - 1)
  local split = ui.view == 'plugins' and not ui.help
  local list_w = split and math.floor(w * M.opts.split) or w
  local frame = { relative = 'editor', row = row, col = col, width = w, height = h, zindex = 50, focusable = false }
  frame.border = border()
  -- Neovim allows a title and footer only on a float with a border.
  if frame.border ~= 'none' then
    frame.title, frame.title_pos = title(w), 'left'
    frame.footer, frame.footer_pos = footer(w), 'left'
  end
  return {
    frame = frame,
    list = { relative = 'editor', row = row + 1, col = col + 1, width = list_w, height = h, zindex = 51 },
    pane = {
      relative = 'editor',
      row = row + 1,
      col = col + 1 + list_w,
      width = math.max(1, w - list_w - 1),
      height = h,
      zindex = 51,
      focusable = false,
      hide = not split,
      border = { '', '', '', '', '', '', '', { '│', 'CinchRule' } },
    },
  }
end

-- Drawing -----------------------------------------------------------------------

---@param win integer
---@param c cinch.ui.Canvas
local function paint(win, c)
  local buf = api.nvim_win_get_buf(win)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, c.lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(c.hls) do
    pcall(api.nvim_buf_set_extmark, buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
end

--- The line of a plugin's spec in its file: the first line naming its repo.
---@param p cinch.Plugin
local function find_spec_line(p)
  if ui.ctx.spec_lines[p.name] or not (p.origin and p.origin.file) then
    return
  end
  local ok, lines = pcall(vim.fn.readfile, p.origin.file)
  if not ok then
    return
  end
  local repo = p.src:gsub('%.git$', ''):match('[^/:]+/[^/]+$') or p.name
  for i, line in ipairs(lines) do
    if line:find(repo, 1, true) or line:find(p.name, 1, true) then
      ui.ctx.spec_lines[p.name] = i
      return
    end
  end
end

local function draw_pane()
  if not (valid(ui.pane) and ui.view == 'plugins' and not ui.help) then
    return
  end
  local p = ui.selected and state.plugins[ui.selected]
  if p then
    find_spec_line(p)
  end
  paint(ui.pane, plugins().pane(ui.selected, api.nvim_win_get_width(ui.pane), ui.ctx))
end

local function help_canvas(width)
  local cv = canvas()
  local c = cv.new(width)
  local rows = {
    { 'j / k', 'move between plugins; the pane follows' },
    { '<CR>', 'fold or open the section under the cursor' },
    { '/', 'filter by name, or the log by text; empty clears it' },
    { 'l', 'load the plugin now' },
    { 'b', 'run its build again' },
    { 'u', 'apply its pending update' },
    { 'U', 'apply every pending update' },
    { 'c', 'check for updates in the background' },
    { 'gf', 'open the spec file at the plugin' },
    { 'r', 'read what vim.pack knows again' },
    { '<Tab> <S-Tab>', 'next or previous view' },
    { '=', 'switch between 75% and 95% of the editor' },
    { 'q Q <Esc>', 'close' },
  }
  c:add({ { ' keys', 'CinchSection' } })
  c:blank()
  for _, r in ipairs(rows) do
    c:add({ { '   ' .. cv.fit(r[1], 16), 'CinchKey' }, { r[2] } })
  end
  return c
end

local function render()
  if not M.is_open() then
    return
  end
  local cfg = layout()
  api.nvim_win_set_config(ui.frame, cfg.frame)
  api.nvim_win_set_config(ui.list, cfg.list)
  api.nvim_win_set_config(ui.pane, cfg.pane)
  local width = api.nvim_win_get_width(ui.list)
  local c
  if ui.help then
    c = help_canvas(width)
  elseif ui.view == 'plugins' then
    c = plugins().list(width, ui.ctx)
  elseif ui.view == 'stats' then
    c = dashboard().stats(width)
  else
    c = dashboard().log(width, ui.ctx)
  end
  ui.canvas = c
  paint(ui.list, c)
  -- Keep the cursor on the same plugin when rows move.
  if ui.view == 'plugins' and ui.selected then
    for l, name in pairs(c.rows) do
      if name == ui.selected then
        api.nvim_win_set_cursor(ui.list, { l, 0 })
        break
      end
    end
  end
  draw_pane()
end

--- Redraw on the next tick: a burst of events draws once.
local function redraw()
  if ui.queued or not M.is_open() then
    return
  end
  ui.queued = true
  vim.schedule(function()
    ui.queued = false
    render()
  end)
end

--- The spinner turns while something is happening, and stops when nothing is.
local function animate()
  local busy = ui.ctx.install ~= nil
  for _, p in ipairs(state.list) do
    busy = busy or p.activity ~= nil or p.state == 'loading'
  end
  if busy and M.is_open() and not ui.timer then
    ui.timer = uv.new_timer()
    ui.timer:start(
      100,
      100,
      vim.schedule_wrap(function()
        ui.ctx.tick = ui.ctx.tick + 1
        render()
      end)
    )
  elseif ui.timer and not (busy and M.is_open()) then
    ui.timer:stop()
    ui.timer:close()
    ui.timer = nil
  end
end

-- vim.pack details ------------------------------------------------------------------

--- What vim.pack knows about the selected plugin, read once it stays selected a moment.
local function fetch_info()
  local name = ui.selected
  vim.defer_fn(function()
    if name ~= ui.selected or ui.ctx.info[name] or not M.is_open() then
      return
    end
    local p = state.plugins[name]
    local pack = require('cinch.pack')
    if not (p and p.path) then
      return
    elseif not pack.idle() then
      ui.ctx.info[name] = 'vim.pack is busy; r reads again'
    else
      local ok, data = pack.get({ name }, { offline = true })
      ui.ctx.info[name] = ok and type(data) == 'table' and data[1] or tostring(data)
    end
    draw_pane()
  end, 150)
end

--- The cursor moved: select the plugin under it and show it in the pane.
local function on_cursor()
  local c = ui.canvas
  if not (c and M.is_open()) or ui.view ~= 'plugins' or ui.help then
    return
  end
  local name = c.rows[api.nvim_win_get_cursor(ui.list)[1]]
  if name and name ~= ui.selected then
    ui.selected = name
    draw_pane()
    fetch_info()
  end
end

-- Keys --------------------------------------------------------------------------

---@param fn fun(p: cinch.Plugin)
---@return fun()
local function on_plugin(fn)
  return function()
    local p = ui.selected and state.plugins[ui.selected]
    if p and ui.view == 'plugins' then
      fn(p)
      redraw()
    end
  end
end

---@param step integer
---@return fun()
local function cycle(step)
  return function()
    local i = 1
    for j, v in ipairs(M.views) do
      if v == ui.view then
        i = j
      end
    end
    M.open(M.views[(i - 1 + step) % #M.views + 1])
  end
end

local function fold()
  local line = api.nvim_win_get_cursor(ui.list)[1]
  local key = ui.canvas and ui.canvas.sections[line]
  if key then
    ui.ctx.folded[key] = not ui.ctx.folded[key] or nil
    render()
    api.nvim_win_set_cursor(ui.list, { math.min(line, api.nvim_buf_line_count(api.nvim_win_get_buf(ui.list))), 0 })
  end
end

local function filter()
  vim.ui.input({ prompt = 'filter: ', default = ui.ctx.filter }, function(text)
    ui.ctx.filter = text and text ~= '' and text or nil
    vim.schedule(render)
  end)
end

local function goto_spec()
  local p = ui.selected and state.plugins[ui.selected]
  if not (p and p.origin and p.origin.file) then
    return
  end
  find_spec_line(p)
  local line = ui.ctx.spec_lines[p.name]
  M.close()
  vim.cmd.edit(vim.fn.fnameescape(p.origin.file))
  if line then
    api.nvim_win_set_cursor(0, { line, 0 })
  end
end

---@type table<string, { [1]: fun(), [2]: string }>
local keys = {
  ['<Tab>'] = { cycle(1), 'Next view' },
  ['<S-Tab>'] = { cycle(-1), 'Previous view' },
  ['='] = {
    function()
      ui.wide = not ui.wide
      render()
    end,
    'Switch between 75% and 95% of the editor',
  },
  ['<CR>'] = { fold, 'Fold or open the section under the cursor' },
  ['/'] = { filter, 'Filter' },
  ['?'] = {
    function()
      ui.help = not ui.help
      render()
    end,
    'Keys',
  },
  gf = { goto_spec, 'Open the spec file at the plugin' },
  G = {
    function()
      api.nvim_win_set_cursor(ui.list, { api.nvim_buf_line_count(api.nvim_win_get_buf(ui.list)), 0 })
    end,
    'Newest',
  },
  l = {
    on_plugin(function(p)
      require('cinch').load(p.name)
    end),
    'Load the plugin',
  },
  b = {
    on_plugin(function(p)
      require('cinch').build(p.name)
    end),
    'Run its build',
  },
  u = {
    on_plugin(function(p)
      local u = updates()
      if u and u.results[p.name] then
        u.apply({ p.name })
      else
        events.report(('no pending update for `%s`; c checks'):format(p.name))
      end
    end),
    'Apply its update',
  },
  U = {
    function()
      local u = updates()
      if u then
        u.apply()
      end
    end,
    'Apply every update',
  },
  c = {
    function()
      local u = updates()
      if u then
        u.check(nil, { notify = true })
        redraw()
      end
    end,
    'Check for updates',
  },
  r = {
    function()
      ui.ctx.info = {}
      fetch_info()
      render()
    end,
    'Read again',
  },
  q = {
    function()
      M.close()
    end,
    'Close',
  },
}
keys.Q = keys.q
keys['<Esc>'] = keys.q

-- Window ------------------------------------------------------------------------

--- Subscribed on the first open, never at startup.
local function subscribe()
  if ui.subscribed then
    return
  end
  ui.subscribed = true
  for _, name in ipairs({ 'State', 'Activity', 'Load', 'LoadError', 'Build', 'Updates', 'Message', 'Later' }) do
    if events.names[name] then
      events.on(name, function()
        redraw()
        animate()
      end)
    end
  end
  events.on('Pack', function(d)
    -- What vim.pack knew about it is out of date.
    ui.ctx.info[d.name] = nil
    redraw()
  end)
end

---@param focus boolean
---@param cfg vim.api.keyset.win_config
---@return integer win
local function float(focus, cfg)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  cfg.style = 'minimal'
  local win = api.nvim_open_win(buf, focus, cfg)
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = 'Normal:NormalFloat'
  return win
end

--- Open the window, or switch an open one to `view`.
---@param view? 'plugins'|'stats'|'log'
function M.open(view)
  if view and vim.list_contains(M.views, view) then
    ui.view = view
  end
  ui.help = false
  if M.is_open() then
    api.nvim_set_current_win(ui.list)
    render()
    if ui.view == 'log' then
      keys.G[1]()
    end
    return
  end
  for group, link in pairs(canvas().highlights) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
  subscribe()

  local cfg = layout()
  ui.frame = float(false, cfg.frame)
  ui.pane = float(false, cfg.pane)
  ui.list = float(true, cfg.list)
  local buf = api.nvim_win_get_buf(ui.list)
  vim.bo[buf].filetype = 'cinch'
  vim.wo[ui.list].cursorline = true
  for lhs, def in pairs(keys) do
    vim.keymap.set('n', lhs, def[1], { buffer = buf, nowait = true, desc = 'cinch: ' .. def[2] })
  end

  local group = api.nvim_create_augroup('cinch_ui', { clear = true })
  api.nvim_create_autocmd('CursorMoved', { group = group, buffer = buf, callback = on_cursor })
  api.nvim_create_autocmd('VimResized', { group = group, callback = render })
  -- Leaving the list, or closing any of the three, closes them all.
  api.nvim_create_autocmd({ 'BufLeave', 'BufWipeout' }, {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(M.close)
    end,
  })

  render()
  if ui.view == 'plugins' then
    -- Start on the first plugin, not on a section title.
    for l = 1, #ui.canvas.lines do
      if ui.canvas.rows[l] then
        api.nvim_win_set_cursor(ui.list, { l, 0 })
        break
      end
    end
    on_cursor()
  elseif ui.view == 'log' then
    keys.G[1]()
  end
  animate()
  -- Opening checks for updates when the last check is stale, in the background.
  local u = updates()
  if u and not u.checking and not u.fresh() then
    u.check()
  end
end

function M.close()
  for _, k in ipairs({ 'list', 'pane', 'frame' }) do
    if valid(ui[k]) then
      pcall(api.nvim_win_close, ui[k], true)
    end
    ui[k] = nil
  end
  ui.canvas = nil
  pcall(api.nvim_del_augroup_by_name, 'cinch_ui')
  animate()
end

-- `:Cinch open [view]`, and plain `:Cinch`, found by command.lua.
M.commands = {
  open = {
    run = function(args)
      M.open(args[1])
    end,
    complete = function()
      return M.views
    end,
  },
}

---@param opts? cinch.ui.Opts
function M.setup(opts)
  M.opts = vim.tbl_extend('force', M.opts, opts or {})
end

return M
