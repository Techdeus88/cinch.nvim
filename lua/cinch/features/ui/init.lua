-- The cinch window: four bordered windows over the editor, 75% of it, 95% of its height
-- with `-`. The header's two lines hold the counts, the name, the tabs and what is under way;
-- the footer holds the keys. Between them the
-- Plugins view is two panes, 70/30 or 50/50 with `=`: the list, which has the cursor, and
-- the detail pane, which follows it. Stats, Profile and Log use the whole width. At startup
-- this file only declares `:Cinch open`; drawing code and subscriptions wait for the first open.
-- Every message cinch has shows here, never on the command line: one about a plugin's build
-- on its row, the rest in the middle of the header's second line. A warning or an error
-- opens the window; anything else waits in the header for the next open, and in the Log.

local events = require('cinch.events')
local state = require('cinch.state')

local api, uv = vim.api, vim.uv

local M = {}

---@class cinch.ui.Opts
---@field size? number share of the editor, default 0.75
---@field tall? number share of the editor's height after `-`, default 0.95
---@field split? number the list's share of the width beside the pane, default 0.7; 0.5 after `=`
---@field side_by_side? integer window width from which the pane sits beside the list; default 130, room for a whole row
---@field border? string|string[] default: 'winborder', or rounded when that is empty
---@field open_on_install? boolean open the window when plugins install, default true
---@field colorscheme? string applied the moment a plugin that ships it is on disk, on a first start
---@field rounded? boolean rounded ends on chips, drawn with Nerd Font glyphs; default true
---@field icons? table<string, string> your own Nerd Font icons: now, later, event, ft, cmd, keys, dep, trigger, off
---@field backdrop? integer|false how much the editor shows through the dark backdrop, 0-100; default 60, false: none

---@type cinch.ui.Opts
M.opts = { size = 0.75, tall = 0.95, split = 0.7, side_by_side = 130, backdrop = 60 }

M.views = { 'plugins', 'triggers', 'stats', 'profile', 'log' }

-- Views with the details pane, and the field of `ui` that holds what the cursor is on.
local paned = { plugins = 'selected', triggers = 'trigger' }

local ui = {
  backdrop = nil, ---@type integer? window
  header = nil, ---@type integer? window
  footer = nil, ---@type integer? window
  pane_of = nil, ---@type string? the plugin the pane shows, to scroll it back up for another
  released = false, -- focus may stay in an editor window: plugins load there on a first start
  list = nil, ---@type integer? window
  pane = nil, ---@type integer? window
  view = 'plugins',
  tall = false, -- `-`: the tall height
  even = false, -- `=`: the list and the pane 50/50
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
  input = nil, ---@type string? the prompt and the text being typed, for the footer
  ---@type cinch.ui.Ctx
  ctx = { folded = {}, tick = 0, info = {}, spec_lines = {} },
}

local ns = api.nvim_create_namespace('cinch_ui')

--- A note on a plugin's row: how its last build went. A `sticky` one, a failure, stays
--- until the next build; the rest go after a moment.
---@type table<string, { text: string, hl: string, sticky?: boolean }>
M.notes = {}

-- How long a message stays in the header once on screen, in ms, by whether it is a
-- warning or an error.
local notice_ms = { [false] = 4000, [true] = 10000 }

--- One of the window's files, loaded on first use: canvas, plugins, layout, triggers, dashboard, profile, keys.
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

--- The window ids of the backdrop, the header, the list, the pane and the footer, while open.
---@return { backdrop?: integer, header?: integer, list?: integer, pane?: integer, footer?: integer }
function M.windows()
  return { backdrop = ui.backdrop, header = ui.header, list = ui.list, pane = ui.pane, footer = ui.footer }
end

-- Layout ------------------------------------------------------------------------

--- The footer: the keys of the view, what the selection can do, or the text being typed.
---@return string|cinch.ui.Hint[]
local function footer_text()
  if ui.input then
    return ' ' .. ui.input .. ' '
  end
  local marked = vim.tbl_count(ui.ctx.marked or {})
  if ui.view == 'plugins' and marked > 0 and not ui.help then
    return {
      { ('%d selected'):format(marked) },
      { 'l', 'load' },
      { 'b', 'build' },
      { 'u', 'update' },
      { 'c', 'check' },
      { 'd', 'delete' },
      { '<Esc>', 'lets go' },
    }
  end
  local holding = ui.ctx.op and ui.ctx.op.kind ~= 'check' and ui.ctx.op.kind ~= 'delete'
  return part('keys').hints[holding and 'install' or ui.help and 'help' or ui.view]
end

--- The window's configs for what it shows now.
---@return cinch.ui.Shape
local function shape()
  return {
    opts = M.opts,
    tall = ui.tall,
    even = ui.even,
    split = paned[ui.view] ~= nil and not ui.help,
    view = ui.view,
    views = M.views,
    help = ui.help,
    op = ui.ctx.op,
    notice = ui.ctx.notice,
  }
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
  for l, group in pairs(c.line_hls) do
    pcall(api.nvim_buf_set_extmark, buf, ns, l - 1, 0, { line_hl_group = group })
  end
end

--- Paint the lines of the header or the footer, made from its width.
---@param win integer
---@param make fun(width: integer): { [1]: string, [2]?: string }[][]
local function paint_bar(win, make)
  local width = api.nvim_win_get_width(win)
  local c = part('canvas').new(width)
  for _, line in ipairs(make(width)) do
    c:add(line)
  end
  paint(win, c)
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
  -- A message's moment starts when it is first on screen, so one that waited for
  -- the window to open still gets it.
  local notice = ui.ctx.notice
  if notice and not notice.shown then
    notice.shown = true
    vim.defer_fn(function()
      if ui.ctx.notice == notice then
        ui.ctx.notice = nil
        render()
      end
    end, notice_ms[notice.level >= vim.log.levels.WARN])
  end
  local s = shape()
  local layout = part('layout')
  local cfg = layout.configs(s)
  if valid(ui.backdrop) then
    api.nvim_win_set_config(ui.backdrop, cfg.backdrop)
  end
  for _, k in ipairs({ 'header', 'list', 'pane', 'footer' }) do
    api.nvim_win_set_config(ui[k], cfg[k])
  end
  paint_bar(ui.header, function(width)
    return layout.header(width, s)
  end)
  paint_bar(ui.footer, function(width)
    return { layout.footer(width, footer_text()) }
  end)
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
  elseif ui.view == 'profile' then
    c = part('profile').list(width, ui.ctx)
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
  -- vim.pack.add and vim.pack.update wait in vim.wait, which runs callbacks but does not redraw.
  if ui.ctx.op and (ui.ctx.op.kind == 'install' or ui.ctx.op.kind == 'update') then
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
  local busy = ui.ctx.op ~= nil
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

--- What vim.pack has on disk that no spec names, for the Updates section.
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

--- Ask yes or no about plugins on their own rows; y and n answer, and closing is a no.
---@param req { verb: string, names: string[], done: fun(yes: boolean) }
---@return boolean asked false when none of them has a row to ask on
function M.ask(req)
  M.answer(false)
  local names = {}
  for _, name in ipairs(req.names) do
    names[name] = true
  end
  ---@return integer?
  local function first()
    for l = 1, ui.canvas and #ui.canvas.lines or 0 do
      if names[ui.canvas.rows[l]] then
        return l
      end
    end
  end
  ui.ctx.ask = { verb = req.verb, names = names, done = req.done }
  read_orphans()
  M.open('plugins')
  local line = first()
  if not line then
    -- Folded away or filtered out.
    ui.ctx.folded, ui.ctx.filter = {}, nil
    render()
    line = first()
  end
  if not line then
    ui.ctx.ask = nil
    render()
    return false
  end
  api.nvim_win_set_cursor(ui.list, { line, 0 })
  on_cursor()
  return true
end

--- Answer what the rows ask.
---@param yes boolean
function M.answer(yes)
  local ask = ui.ctx.ask
  if not ask then
    return
  end
  ui.ctx.ask, ui.ctx.marked = nil, {}
  render()
  -- Not from inside the key: an install opens and focuses windows of its own.
  vim.schedule(function()
    ask.done(yes)
  end)
end

local keycodes = { cr = vim.keycode('<CR>'), esc = vim.keycode('<Esc>'), bs = vim.keycode('<BS>') }

--- Take a line of text in the window: the prompt and what you type show in the
--- footer. <CR> ends it, <Esc> gives it up, <C-u> empties it.
---@param req { prompt: string, text?: string, change?: fun(text: string), done: fun(text?: string) }
function M.input(req)
  local text = req.text or '' ---@type string?
  while text do
    ui.input = req.prompt .. text .. '▏'
    render()
    vim.cmd.redraw()
    local ok, ch = pcall(vim.fn.getcharstr)
    if not ok or ch == keycodes.esc then
      text = nil
      break
    elseif ch == keycodes.cr or ch == '\n' then
      break
    elseif ch == keycodes.bs or ch == '\b' or ch == '\127' then
      text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
    elseif ch == '\21' then
      text = ''
    elseif ch:byte() >= 32 and ch:byte() ~= 128 then
      text = text .. ch
    end
    if req.change then
      req.change(text)
    end
  end
  ui.input = nil
  req.done(text)
  render()
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
      ask = M.ask,
      answer = M.answer,
      input = M.input,
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
---@param view? 'plugins'|'triggers'|'stats'|'profile'|'log'
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

  local cfg = part('layout').configs(shape())
  -- Blending needs 'termguicolors'; without it the backdrop would hide the editor.
  if M.opts.backdrop and vim.o.termguicolors then
    ui.backdrop = float(false, cfg.backdrop)
    vim.wo[ui.backdrop].winhighlight = 'Normal:CinchBackdrop'
    vim.wo[ui.backdrop].winblend = M.opts.backdrop
  end
  ui.header = float(false, cfg.header)
  ui.footer = float(false, cfg.footer)
  ui.pane = float(false, cfg.pane)
  ui.list = float(true, cfg.list)
  local buf = api.nvim_win_get_buf(ui.list)
  vim.bo[buf].filetype = 'cinch'
  vim.wo[ui.list].cursorline = true
  -- A plugin that opens a buffer "in the current window" must not take over ours.
  for _, win in ipairs({ ui.header, ui.footer, ui.pane, ui.list, ui.backdrop }) do
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
  -- Closing any of them closes them all. Leaving the list does not: plugins
  -- move focus as they load (dashboards, pickers, input prompts), and that must
  -- not close the window.
  for _, win in ipairs({ ui.header, ui.footer, ui.pane, ui.list }) do
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
  if u and not u.checking and not u.fresh() and not (ui.ctx.op and ui.ctx.op.kind == 'install') then
    u.check()
  end
end

function M.close()
  local ask = ui.ctx.ask
  ui.ctx.ask = nil
  if ask then
    vim.schedule(function()
      ask.done(false)
    end)
  end
  for _, k in ipairs({ 'list', 'pane', 'header', 'footer', 'backdrop' }) do
    local win = ui[k] --[[@as integer?]]
    if valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
    ui[k] = nil
  end
  ui.canvas, ui.canvas_of, ui.pane_of, ui.released, ui.trigger = nil, nil, nil, false, nil
  ui.ctx.marked = {}
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

-- Install, check, update, delete -------------------------------------------------

--- What ops.lua needs from the window.
---@type cinch.ui.OpHost
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

--- A handler that loads ops.lua the first time its event fires.
---@param fn 'start'|'progress'|'finish'
---@param kind? cinch.OpKind
---@return fun(d: table)
local function on_op(fn, kind)
  return function(d)
    host.opts = M.opts
    local ops = require('cinch.features.ui.ops')
    if kind then
      ops[fn](host, kind, d)
    else
      ops[fn](host, d)
    end
  end
end

--- The first line of a message, without Lua's `file.lua:12:` prefixes.
---@param msg string
---@return string
local function first_line(msg)
  for _, line in ipairs(vim.split(msg, '\n')) do
    line = vim.trim((line:gsub('%S+%.lua:%d+: ', '')))
    if line ~= '' and line ~= 'vim.pack:' then
      return line
    end
  end
  return ''
end

-- A warning or an error came while Neovim started: the window opens once it is up.
local open_after_start = false

--- Show a Report: on its plugin's row when the Plugins view has one for it, else in
--- the header. A warning or an error opens the window.
---@param d { msg: string, level: integer, plugin?: string }
local function on_report(d)
  d.handled = true
  local op = ui.ctx.op
  -- An operation's ending already says it.
  if op and op.message == d.msg then
    return
  end
  local on_row = d.plugin and state.plugins[d.plugin] and ui.view == 'plugins' and not ui.help
  if not on_row then
    ui.ctx.notice = { text = first_line(d.msg), level = d.level }
  end
  if d.level < vim.log.levels.WARN or M.is_open() then
    return redraw()
  end
  if vim.v.vim_did_enter == 0 then
    open_after_start = true
  else
    vim.schedule(function()
      if not M.is_open() then
        M.open('plugins')
      end
    end)
  end
end

---@param p cinch.Plugin
---@param note? { text: string, hl: string, sticky?: boolean }
local function set_note(p, note)
  M.notes[p.name] = note
  if note and not note.sticky then
    vim.defer_fn(function()
      if M.notes[p.name] == note then
        M.notes[p.name] = nil
        redraw()
      end
    end, notice_ms[false])
  end
end

---@param opts? cinch.ui.Opts
function M.setup(opts)
  M.opts = vim.tbl_extend('force', M.opts, opts or {})
  -- Before the message feature's, so it only logs what shows here.
  events.on('Report', on_report, { priority = 10 })
  -- A build says how it went on its row: a failure until the next build.
  events.on('Build', function(d)
    local note
    if not d.ok then
      local why = first_line(tostring(d.err or ''))
      note = { text = why == '' and 'build failed' or 'build failed: ' .. why, hl = 'CinchFailed', sticky = true }
    elseif M.is_open() then
      note = { text = 'built in ' .. require('cinch.ops').duration(d.ms), hl = 'CinchLoaded' }
    end
    set_note(d.plugin, note)
  end, { priority = 10 })
  events.on('Activity', function(d)
    if d.to == 'building' then
      M.notes[d.plugin.name] = nil
    end
  end)
  if vim.v.vim_did_enter == 0 then
    api.nvim_create_autocmd('VimEnter', {
      once = true,
      callback = vim.schedule_wrap(function()
        if open_after_start and not M.is_open() then
          M.open('plugins')
        end
      end),
    })
  end
  -- These fire only when something runs, so listening from startup costs nothing.
  for kind, names in pairs({
    install = { 'Installing', 'Installed' },
    check = { 'Checking', 'Checked' },
    update = { 'Updating', 'Updated' },
    delete = { 'Deleting', 'Deleted' },
  }) do
    events.on(names[1], on_op('start', kind))
    events.on(names[2], on_op('finish', kind))
  end
  local progress = on_op('progress')
  events.on('Progress', function(d)
    if d.build then
      -- Its row shows it.
      d.handled = true
    else
      progress(d)
    end
  end)
  -- After startup there is a window to ask in.
  events.on('Ask', function(d)
    if not d.handled and vim.v.vim_did_enter == 1 then
      d.handled = M.ask(d)
    end
  end)
end

return M
