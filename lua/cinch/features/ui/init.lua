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
---@field side_by_side? integer frame width from which the pane sits beside the list; default 130, room for a whole row
---@field border? string|string[] default: 'winborder', or rounded when that is empty
---@field open_on_install? boolean open the window when plugins install, default true
---@field colorscheme? string applied the moment a plugin that ships it is on disk, on a first start
---@field rounded? boolean rounded ends on chips and bars, drawn with Nerd Font glyphs; default true

---@type cinch.ui.Opts
M.opts = { size = 0.75, wide = 0.95, split = 0.58, side_by_side = 130 }

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
  colors_done = false, -- opts.colorscheme was applied
  editor = nil, ---@type integer? the editor window you opened cinch from
  timer = nil, ---@type uv.uv_timer_t?
  ---@type cinch.ui.Ctx
  ctx = { folded = {}, tick = 0, info = {}, spec_lines = {} },
}

local ns = api.nvim_create_namespace('cinch_ui')

--- One of the window's files, loaded on first use: canvas, plugins, dashboard, keys.
---@param name string
local function part(name)
  return require('cinch.features.ui.' .. name)
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

--- Run `fn` from the editor window you opened cinch from, so a plugin that loads
--- and opens a buffer "in the current window" opens it there, not in cinch.
---@param fn fun()
function M.in_editor(fn)
  if valid(ui.editor) then
    api.nvim_win_call(ui.editor --[[@as integer]], fn)
  else
    fn()
  end
end

--- The window ids of the frame, the list and the pane, while open.
---@return { frame?: integer, list?: integer, pane?: integer }
function M.windows()
  return { frame = ui.frame, list = ui.list, pane = ui.pane }
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
  local cv = part('canvas')
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

---@param width integer
---@return { [1]: string, [2]: string }[]
local function footer(width)
  local text = part('keys').hints[ui.ctx.install and 'install' or ui.help and 'help' or ui.view]
  return { { part('canvas').fit(text, math.min(part('canvas').cells(text), width - 2)), 'CinchMuted' } }
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
  local frame = { relative = 'editor', row = row, col = col, width = w, height = h, zindex = 50, focusable = false }
  frame.border = border()
  -- Neovim allows a title and footer only on a float with a border.
  if frame.border ~= 'none' then
    frame.title, frame.title_pos = title(w), 'left'
    frame.footer, frame.footer_pos = footer(w), 'left'
  end
  local list = { relative = 'editor', row = row + 1, col = col + 1, width = w, height = h, zindex = 51 }
  local pane = { relative = 'editor', zindex = 51, focusable = false, hide = not split }
  if w >= M.opts.side_by_side then
    -- Wide enough: the pane beside the list, a rule between them.
    list.width = split and math.floor(w * M.opts.split) or w
    pane.row, pane.col = row + 1, col + 1 + list.width
    pane.width, pane.height = math.max(1, w - list.width - 1), h
    pane.border = { '', '', '', '', '', '', '', { '│', 'CinchRule' } }
  else
    -- Too narrow for two columns: the pane under the list, a rule between them.
    list.height = split and math.max(3, math.floor(h * 0.55)) or h
    pane.row, pane.col = row + 1 + list.height, col + 1
    pane.width, pane.height = w, math.max(1, h - list.height - 1)
    pane.border = { '', { '─', 'CinchRule' }, '', '', '', '', '', '' }
  end
  return { frame = frame, list = list, pane = pane }
end

-- Drawing -----------------------------------------------------------------------

---@type cinch.ui.Key[]? made on the first open, see keys.lua
local keys
local key_list ---@type fun(): cinch.ui.Key[]

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
  paint(ui.pane, part('plugins').pane(ui.selected, api.nvim_win_get_width(ui.pane), ui.ctx))
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
    c = part('keys').help(width, key_list())
  elseif ui.view == 'plugins' then
    c = part('plugins').list(width, ui.ctx)
  elseif ui.view == 'stats' then
    c = part('dashboard').stats(width)
  else
    c = part('dashboard').log(width, ui.ctx)
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
  -- vim.pack.add waits in vim.wait, which runs callbacks but does not redraw.
  if ui.ctx.install then
    vim.cmd.redraw()
  end
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
--- While vim.pack is busy, an update check say, it tries again a little later.
---@param tries? integer
local function fetch_info(tries)
  local name = ui.selected
  if not name then
    return
  end
  tries = tries or 0
  vim.defer_fn(function()
    if name ~= ui.selected or ui.ctx.info[name] or not M.is_open() then
      return
    end
    local p = state.plugins[name]
    local pack = require('cinch.pack')
    if not (p and p.path) then
      return
    elseif not pack.idle() then
      if tries < 20 then
        return fetch_info(tries + 1)
      end
      ui.ctx.info[name] = 'vim.pack is busy; r reads again'
    else
      local ok, data = pack.get({ name }, { offline = true })
      ui.ctx.info[name] = ok and type(data) == 'table' and data[1] or tostring(data)
    end
    draw_pane()
  end, tries == 0 and 150 or 300)
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

--- Put the cursor on the last line: the newest log entry.
local function newest()
  api.nvim_win_set_cursor(ui.list, { api.nvim_buf_line_count(api.nvim_win_get_buf(ui.list)), 0 })
end

key_list = function()
  keys = keys
    or part('keys').make({
      ui = ui,
      views = M.views,
      render = render,
      redraw = redraw,
      fetch_info = fetch_info,
      find_spec_line = find_spec_line,
      newest = newest,
      in_editor = M.in_editor,
      open = M.open,
      close = M.close,
    })
  return keys
end

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
  -- A new colorscheme, yours applied mid-install say: chips and bar follow it.
  api.nvim_create_autocmd('ColorScheme', {
    callback = function()
      part('canvas').define_colors(M.opts.rounded ~= false)
      redraw()
    end,
  })
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
      newest()
    end
    return
  end
  part('canvas').define_colors(M.opts.rounded ~= false)
  subscribe()
  local from = api.nvim_get_current_win()
  if api.nvim_win_get_config(from).relative == '' then
    ui.editor = from
  end

  local cfg = layout()
  ui.frame = float(false, cfg.frame)
  ui.pane = float(false, cfg.pane)
  ui.list = float(true, cfg.list)
  local buf = api.nvim_win_get_buf(ui.list)
  vim.bo[buf].filetype = 'cinch'
  vim.wo[ui.list].cursorline = true
  -- A plugin that opens a buffer "in the current window" must not take over ours.
  for _, win in ipairs({ ui.frame, ui.pane, ui.list }) do
    vim.wo[win].winfixbuf = true
  end
  part('keys').map(buf, key_list())

  local group = api.nvim_create_augroup('cinch_ui', { clear = true })
  api.nvim_create_autocmd('CursorMoved', { group = group, buffer = buf, callback = on_cursor })
  api.nvim_create_autocmd('VimResized', { group = group, callback = render })
  -- Closing any of the three closes them all. Leaving the list does not: plugins
  -- move focus as they load (dashboards, pickers, input prompts), and that must
  -- not close the window.
  for _, win in ipairs({ ui.frame, ui.pane, ui.list }) do
    api.nvim_create_autocmd('WinClosed', {
      group = group,
      pattern = tostring(win),
      once = true,
      callback = function()
        vim.schedule(M.close)
      end,
    })
  end

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
    newest()
  end
  animate()
  -- Opening checks for updates when the last check is stale, in the background;
  -- not while plugins install.
  local u = updates()
  if u and not u.checking and not u.fresh() and not ui.ctx.install then
    u.check()
  end
end

function M.close()
  for _, k in ipairs({ 'list', 'pane', 'frame' }) do
    local win = ui[k] --[[@as integer?]]
    if valid(win) then
      pcall(api.nvim_win_close, win, true)
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

-- First start ------------------------------------------------------------------

--- What install.lua needs from the window.
---@type cinch.ui.InstallHost
local host = {
  ui = ui,
  opts = M.opts,
  open = M.open,
  is_open = M.is_open,
  render = render,
  redraw = redraw,
  animate = animate,
  ---@param to 'editor'|'list'
  focus = function(to)
    local win = to == 'editor' and ui.editor or ui.list
    if valid(win) then
      api.nvim_set_current_win(win --[[@as integer]])
    end
  end,
}

--- A handler that loads install.lua the first time its event fires.
---@param name 'installing'|'progress'|'installed'
---@return fun(d: table)
local function first_start(name)
  return function(d)
    host.opts = M.opts
    require('cinch.features.ui.install')[name](host, d)
  end
end

---@param opts? cinch.ui.Opts
function M.setup(opts)
  M.opts = vim.tbl_extend('force', M.opts, opts or {})
  -- These fire only when plugins install, so listening from startup costs nothing.
  events.on('Installing', first_start('installing'))
  events.on('Installed', first_start('installed'))
  if events.names.Progress then
    events.on('Progress', first_start('progress'))
  end
end

return M
