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
---@field icons? table<string, string> your own Nerd Font icons: now, later, event, ft, cmd, keys, dep, trigger
---@field backdrop? integer|false how much the editor shows through the dark backdrop, 0-100; default 60, false: none

---@type cinch.ui.Opts
M.opts = { size = 0.75, wide = 0.95, split = 0.58, side_by_side = 130, backdrop = 60 }

M.views = { 'plugins', 'triggers', 'stats', 'log' }

-- Views with the details pane, and the field of `ui` that holds what the cursor is on.
local paned = { plugins = 'selected', triggers = 'trigger' }

local ui = {
  backdrop = nil, ---@type integer? window
  frame = nil, ---@type integer? window
  pane_of = nil, ---@type string? the plugin the pane shows, to scroll it back up for another
  released = false, -- focus may stay in an editor window: plugins load there on a first start
  list = nil, ---@type integer? window
  pane = nil, ---@type integer? window
  view = 'plugins',
  wide = false,
  help = false,
  selected = nil, ---@type string? plugin under the cursor
  trigger = nil, ---@type string? trigger under the cursor, in the Triggers view
  canvas = nil, ---@type cinch.ui.Canvas? what the list shows
  canvas_of = nil, ---@type string? the view it was drawn for, nil for the ? screen
  queued = false,
  subscribed = false,
  colors_done = false, -- opts.colorscheme was applied
  editor = nil, ---@type integer? the editor window you opened cinch from
  timer = nil, ---@type uv.uv_timer_t?
  ---@type cinch.ui.Ctx
  ctx = { folded = {}, tick = 0, info = {}, spec_lines = {} },
}

local ns = api.nvim_create_namespace('cinch_ui')

--- One of the window's files, loaded on first use: canvas, plugins, triggers, dashboard, keys.
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

--- The window ids of the backdrop, the frame, the list and the pane, while open.
---@return { backdrop?: integer, frame?: integer, list?: integer, pane?: integer }
function M.windows()
  return { backdrop = ui.backdrop, frame = ui.frame, list = ui.list, pane = ui.pane }
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
    { ('· %d plugins%s '):format(#state.yours(), startup and (' · startup ' .. cv.ms(startup)) or ''), 'CinchMuted' },
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
  local split = paned[ui.view] ~= nil and not ui.help
  local frame = { relative = 'editor', row = row, col = col, width = w, height = h, zindex = 50, focusable = false }
  frame.border = border()
  -- Neovim allows a title and footer only on a float with a border.
  if frame.border ~= 'none' then
    frame.title, frame.title_pos = title(w), 'left'
    frame.footer, frame.footer_pos = footer(w), 'left'
  end
  local list = { relative = 'editor', row = row + 1, col = col + 1, width = w, height = h, zindex = 51 }
  -- Focusable, so the mouse wheel scrolls it.
  local pane = { relative = 'editor', zindex = 51, hide = not split }
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
  -- Under the frame, over everything else: the editor dimmed behind the window.
  local backdrop = {
    relative = 'editor',
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = lines,
    zindex = 49,
    focusable = false,
  }
  return { backdrop = backdrop, frame = frame, list = list, pane = pane }
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
  local field = paned[ui.view]
  if not (valid(ui.pane) and field and not ui.help) then
    return
  end
  local width = api.nvim_win_get_width(ui.pane)
  if ui.view == 'triggers' then
    paint(ui.pane, part('triggers').pane(ui.trigger, width))
  else
    local p = ui.selected and state.plugins[ui.selected]
    if p then
      find_spec_line(p)
    end
    paint(ui.pane, part('plugins').pane(ui.selected, width, ui.ctx))
  end
  -- Something else starts at its top; the same one keeps where you scrolled it.
  local shows = ui.view .. ' ' .. tostring(ui[field])
  if ui.pane_of ~= shows then
    ui.pane_of = shows
    api.nvim_win_set_cursor(ui.pane, { 1, 0 })
  end
end

--- Scroll the pane by half its height, down or up, from the list.
---@param down boolean
local function scroll_pane(down)
  if valid(ui.pane) and not api.nvim_win_get_config(ui.pane).hide then
    api.nvim_win_call(ui.pane, function()
      vim.cmd.normal({ vim.keycode(down and '<C-d>' or '<C-u>'), bang = true })
    end)
  end
end

local function render()
  if not M.is_open() then
    return
  end
  local cfg = layout()
  if valid(ui.backdrop) then
    api.nvim_win_set_config(ui.backdrop, cfg.backdrop)
  end
  api.nvim_win_set_config(ui.frame, cfg.frame)
  api.nvim_win_set_config(ui.list, cfg.list)
  api.nvim_win_set_config(ui.pane, cfg.pane)
  local width = api.nvim_win_get_width(ui.list)
  local c
  if ui.help then
    c = part('keys').help(width, key_list())
  elseif ui.view == 'plugins' then
    c = part('plugins').list(width, ui.ctx)
  elseif ui.view == 'triggers' then
    c = part('triggers').list(width, ui.ctx)
  elseif ui.view == 'stats' then
    c = part('dashboard').stats(width)
  else
    c = part('dashboard').log(width, ui.ctx)
  end
  -- What the cursor is on, a row or a section title, so it stays on it when rows
  -- move. Coming from another view, that is what this view had selected.
  local field = not ui.help and paned[ui.view]
  local at = { row = field and ui[field] }
  if field and ui.canvas_of == ui.view then
    local l = api.nvim_win_get_cursor(ui.list)[1]
    at = { row = ui.canvas.rows[l], section = ui.canvas.sections[l] }
  end
  ui.canvas, ui.canvas_of = c, not ui.help and ui.view or nil
  paint(ui.list, c)
  if field then
    local first
    for l = 1, #c.lines do
      first = first or (c.rows[l] and l)
      if (at.row and c.rows[l] == at.row) or (at.section and c.sections[l] == at.section) then
        api.nvim_win_set_cursor(ui.list, { l, 0 })
        first = nil
        break
      end
    end
    -- Nothing selected in this view yet: the first row, so the pane has something.
    if first and not ui[field] then
      api.nvim_win_set_cursor(ui.list, { first, 0 })
      ui[field] = c.rows[first]
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
--- While vim.pack is busy, an update check say, or the plugin is still installing,
--- it tries again a little later.
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
    if not p then
      return
    elseif not p.path or not pack.idle() then
      if tries < 20 then
        return fetch_info(tries + 1)
      elseif not p.path then
        return
      end
      ui.ctx.info[name] = 'vim.pack is busy; r reads again'
    else
      local ok, data = pack.get({ name }, { offline = true })
      ui.ctx.info[name] = ok and type(data) == 'table' and data[1] or tostring(data)
    end
    draw_pane()
  end, tries == 0 and 150 or 300)
end

--- What vim.pack has on disk that no spec names, for the "not in your specs" section.
--- Read on open and after a delete; skipped while vim.pack is busy.
local function read_orphans()
  local pack = require('cinch.pack')
  if pack.idle() then
    ui.ctx.orphans = pack.orphans()
  end
end

--- The cursor moved: select the plugin under it and show it in the pane.
local function on_cursor()
  local c = ui.canvas
  local field = paned[ui.view]
  if not (c and M.is_open()) or not field or ui.help then
    return
  end
  local id = c.rows[api.nvim_win_get_cursor(ui.list)[1]]
  if id and id ~= ui[field] then
    ui[field] = id
    draw_pane()
    if field == 'selected' then
      fetch_info()
    end
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
      read_orphans = read_orphans,
      scroll_pane = scroll_pane,
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
  for _, name in ipairs({
    'State',
    'Activity',
    'Load',
    'LoadError',
    'Build',
    'BuildOutput',
    'Updates',
    'Message',
    'Later',
  }) do
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
  events.on('PackOp', function(d)
    if d.op == 'del' then
      read_orphans()
      redraw()
    end
  end)
  events.on('Pack', function(d)
    -- What vim.pack knew about it is out of date: read it again if it is on show.
    ui.ctx.info[d.name] = nil
    if d.name == ui.selected then
      fetch_info()
    end
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
---@param view? 'plugins'|'triggers'|'stats'|'log'
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
  read_orphans()
  local from = api.nvim_get_current_win()
  if api.nvim_win_get_config(from).relative == '' then
    ui.editor = from
  end

  local cfg = layout()
  -- Blending needs 'termguicolors'; without it the backdrop would hide the editor.
  if M.opts.backdrop and vim.o.termguicolors then
    ui.backdrop = float(false, cfg.backdrop)
    vim.wo[ui.backdrop].winhighlight = 'Normal:CinchBackdrop'
    vim.wo[ui.backdrop].winblend = M.opts.backdrop
  end
  ui.frame = float(false, cfg.frame)
  ui.pane = float(false, cfg.pane)
  ui.list = float(true, cfg.list)
  local buf = api.nvim_win_get_buf(ui.list)
  vim.bo[buf].filetype = 'cinch'
  vim.wo[ui.list].cursorline = true
  -- A plugin that opens a buffer "in the current window" must not take over ours.
  for _, win in ipairs({ ui.frame, ui.pane, ui.list, ui.backdrop }) do
    vim.wo[win].winfixbuf = true
  end
  part('keys').map(buf, key_list())
  -- The pane, scrolled into with the mouse, closes like the list.
  for _, lhs in ipairs({ 'q', 'Q', '<Esc>' }) do
    vim.keymap.set('n', lhs, M.close, { buffer = api.nvim_win_get_buf(ui.pane), nowait = true, desc = 'cinch: close' })
  end

  local group = api.nvim_create_augroup('cinch_ui', { clear = true })
  api.nvim_create_autocmd('CursorMoved', { group = group, buffer = buf, callback = on_cursor })
  api.nvim_create_autocmd('VimResized', { group = group, callback = render })
  -- The cursor stays in cinch: entering an editor window, with a click or <C-w>,
  -- comes back to the list. Floats are left alone, so a prompt or a picker a
  -- plugin opens keeps focus.
  api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      local win = api.nvim_get_current_win()
      if ui.released or win == ui.list or win == ui.pane or api.nvim_win_get_config(win).relative ~= '' then
        return
      end
      vim.schedule(function()
        if M.is_open() and not ui.released and api.nvim_get_current_win() == win then
          api.nvim_set_current_win(ui.list --[[@as integer]])
        end
      end)
    end,
  })
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
  for _, k in ipairs({ 'list', 'pane', 'frame', 'backdrop' }) do
    local win = ui[k] --[[@as integer?]]
    if valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
    ui[k] = nil
  end
  ui.canvas, ui.canvas_of, ui.pane_of, ui.released, ui.trigger = nil, nil, nil, false, nil
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
    ui.released = to == 'editor'
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
