-- The cinch window: four bordered windows over the editor, 75% of it, 95% of its height
-- with `-`. The header's two lines hold startup times, the name and the tabs, then messages;
-- the footer holds the keys. Between them the
-- Plugins view is two panes, 70/30 or 50/50 with `=`: the list, which has the cursor, and
-- the detail pane, which follows it. Stats, Profile and Log use the whole width. At startup
-- this file only declares `:Cinch open`; drawing code and subscriptions wait for the first open.
-- Every message cinch has shows here, never on the command line: one about a plugin on its
-- row, which it takes over until the message is done; a global one (an operation's progress,
-- a message about no plugin) in the middle of the header's second line. A warning or an
-- error opens the window; anything else waits for the next open, and in the Log.

local events = require('cinch.events')
local state = require('cinch.state')

local api, uv = vim.api, vim.uv

local M = {}

---@class cinch.ui.Opts
---@field size? number share of the editor, default 0.75
---@field tall? number share of the editor's height after `-`, default 0.95
---@field start_tall? boolean open at the tall height, as after `-`; default false
---@field split? number the list's share of the width beside the pane, default 0.7; 0.5 after `=`
---@field start_even? boolean open with the list and the pane 50/50, as after `=`; default false
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

-- What extensions add to the window. Kept here, which loads at startup, so adding to
-- it loads no drawing code; the parts read it when they draw.

---@class cinch.ui.View
---@field list fun(width: integer, ctx: cinch.ui.Ctx): cinch.ui.Canvas the list; a row's `plugin` meta is its id
---@field pane? fun(id: string?, width: integer, ctx: cinch.ui.Ctx): cinch.ui.Canvas details of the row at the cursor
---@field hints? cinch.ui.Hint[] its keys, for the footer

---@class cinch.ui.ExtKey
---@field lhs string[]
---@field run fun(id: string?, ctx: cinch.ui.Ctx) given the id of the row under the cursor
---@field desc string for the ? screen
---@field view string the view it works in; elsewhere the key does what it did

---@class cinch.ui.Grouping another way to split the Plugins list into sections
---@field of fun(p: cinch.Plugin): string the section a plugin is in
---@field order fun(keys: string[]): string[] the sections in the order shown
---@field title fun(key: string, list: cinch.Plugin[]): { [1]: string, [2]?: string }[] title, after the fold mark

M.ext = {
  ---@type table<string, cinch.ui.View>
  views = {},
  ---@type cinch.ui.ExtKey[]
  keys = {},
  ---@type table<string, (fun(ctx: cinch.ui.Ctx): cinch.ui.Hint?)[]> view -> footer hints, before `?`
  hints = {},
  ---@type (fun(p: cinch.Plugin): cinch.ui.Item?)[] a chip after how a plugin loads, on its row
  chips = {},
  ---@type (fun(p: cinch.Plugin, kv: fun(key: string, chunks: { [1]: string, [2]?: string }[])))[] pane lines
  pane_lines = {},
  ---@type table<string, fun(p: cinch.Plugin, value: string): boolean> `/<prefix>:<value>` filters
  filters = {},
  ---@type table<string, cinch.ui.Grouping>
  groupings = {},
}

--- Add a view, with its own tab, placed before `opts.before` or last.
---@param name string
---@param view cinch.ui.View
---@param opts? { before?: string }
function M.add_view(name, view, opts)
  M.ext.views[name] = view
  if not vim.list_contains(M.views, name) then
    local at = opts and opts.before and vim.fn.index(M.views, opts.before) or -1
    table.insert(M.views, at >= 0 and at + 1 or #M.views + 1, name)
  end
  if view.pane then
    paned[name] = 'row_' .. name
  end
end

--- Add a key to one view. A key the window already has keeps working in the others.
---@param key cinch.ui.ExtKey
function M.add_key(key)
  table.insert(M.ext.keys, key)
end

--- Add a footer hint to a view; `fn` returns it, or nil to show none.
---@param view string
---@param fn fun(ctx: cinch.ui.Ctx): cinch.ui.Hint?
function M.add_hint(view, fn)
  M.ext.hints[view] = M.ext.hints[view] or {}
  table.insert(M.ext.hints[view], fn)
end

---@param fn fun(p: cinch.Plugin): cinch.ui.Item?
function M.add_chip(fn)
  table.insert(M.ext.chips, fn)
end

---@param fn fun(p: cinch.Plugin, kv: fun(key: string, chunks: { [1]: string, [2]?: string }[]))
function M.add_pane_lines(fn)
  table.insert(M.ext.pane_lines, fn)
end

--- `/<prefix>:<value>` in the Plugins filter shows the plugins `fn` keeps.
---@param prefix string
---@param fn fun(p: cinch.Plugin, value: string): boolean
function M.add_filter(prefix, fn)
  M.ext.filters[prefix] = fn
end

---@param name string
---@param grouping cinch.ui.Grouping
function M.add_grouping(name, grouping)
  M.ext.groupings[name] = grouping
end

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

---@class cinch.ui.Note
---@field text string
---@field hl string
---@field chunks? { [1]: string, [2]: string }[] text with more than one color, in place of `text`
---@field sticky? boolean stays until the next build: a failure
---@field warn? boolean stays as long as a warning in the header

--- A note on a plugin's row: how its last build went, or a message about the plugin.
--- A `sticky` one stays until the next build; the rest go after a moment.
---@type table<string, cinch.ui.Note>
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

-- No columns beside the text. 'minimal' starts a window this way, but a plugin that
-- sets up later may decorate every open window: statuscol.nvim adds its 'statuscolumn',
-- line numbers and all, on a first start while the window is up.
local plain = { number = false, relativenumber = false, statuscolumn = '', signcolumn = 'no', foldcolumn = '0' }

--- Put back what a plugin changed, and only that: setting an option fires OptionSet.
---@param win? integer
local function keep_plain(win)
  if not valid(win) then
    return
  end
  for k, v in pairs(plain) do
    if vim.wo[win][k] ~= v then
      vim.wo[win][k] = v
    end
  end
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
  local which = holding and 'install' or ui.help and 'help' or ui.view
  local base = M.ext.views[which] and M.ext.views[which].hints or part('keys').hints[which] or {}
  local extra = {}
  for _, fn in ipairs(M.ext.hints[which] or {}) do
    extra[#extra + 1] = fn(ui.ctx)
  end
  if #extra == 0 then
    return base
  end
  local out = {}
  for _, h in ipairs(base) do
    if h[1] == '?' then
      vim.list_extend(out, extra)
      extra = {}
    end
    out[#out + 1] = h
  end
  return vim.list_extend(out, extra)
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
local fetch_info ---@type fun(tries?: integer)

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

--- The line of a plugin's spec in its file: the first line naming its repo. Read once:
--- none found is kept as false, so moving the cursor does not read the file again.
---@param p cinch.Plugin
local function find_spec_line(p)
  if ui.ctx.spec_lines[p.name] ~= nil or not (p.origin and p.origin.file) then
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
  ui.ctx.spec_lines[p.name] = false
end

local function draw_pane()
  local field = paned[ui.view]
  if not (valid(ui.pane) and field and not ui.help) then
    return
  end
  local width = api.nvim_win_get_width(ui.pane)
  if M.ext.views[ui.view] then
    paint(ui.pane, M.ext.views[ui.view].pane(ui[field], width, ui.ctx))
  elseif ui.view == 'triggers' then
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

--- While plugins install, the list shows them: the line for the cursor, at the top of
--- the list, the first plugin still installing, or its section's title when folded. Once
--- the last has landed, the first row, until the install's ending is over.
---@param c cinch.ui.Canvas the Plugins list
---@param op? cinch.ui.Op
---@return integer? line nil: no install, so the cursor stays on what it was on
local function install_focus(c, op)
  if not (op and op.kind == 'install') then
    return
  end
  local title, first
  for l = 1, #c.lines do
    local name = c.rows[l]
    if name and op.status[name] == 'cloning' then
      return l
    end
    title = title or (c.sections[l] == 'installing' and l) or nil
    first = first or (name and l) or nil
  end
  return title or first
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
    keep_plain(ui[k])
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
  elseif M.ext.views[ui.view] then
    c = M.ext.views[ui.view].list(width, ui.ctx)
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
  local pin = field == 'selected' and not ui.ctx.ask and install_focus(c, ui.ctx.op)
  if pin then
    api.nvim_win_set_cursor(ui.list, { pin, 0 })
    api.nvim_win_call(ui.list, function()
      vim.fn.winrestview({ topline = 1 })
    end)
    if ui.selected ~= c.rows[pin] then
      ui.selected = c.rows[pin]
      fetch_info()
    end
  elseif field then
    local first
    for l = 1, #c.lines do
      first = first or (c.rows[l] and l)
      if (at.row and c.rows[l] == at.row) or (at.section and c.sections[l] == at.section) then
        api.nvim_win_set_cursor(ui.list, { l, 0 })
        first = nil
        break
      end
    end
    -- The row the cursor was on is gone, hidden by a filter say, or nothing was selected
    -- yet: the row under the cursor, else the first row, so the pane shows what the
    -- cursor is on. On a blank row or a title the cursor stays, so j and k pass them.
    if first and (at.row or not ui[field]) then
      local l = api.nvim_win_get_cursor(ui.list)[1]
      if not c.rows[l] then
        l = first
        api.nvim_win_set_cursor(ui.list, { l, 0 })
      end
      if ui[field] ~= c.rows[l] then
        ui[field] = c.rows[l]
        if field == 'selected' then
          fetch_info()
        end
      end
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

---@type table<string, true> plugins whose branches and tags git is reading now
local reading = {}

--- The selected plugin's branches, the default first, and its tags, once it stays
--- selected a moment. The same git commands vim.pack.get runs, but in the background:
--- vim.pack.get waits for them, 50-80ms a plugin, and keys wait with it. A plugin still
--- installing is tried again a little later.
---@param tries? integer
function fetch_info(tries)
  local name = ui.selected
  if not name then
    return
  end
  tries = tries or 0
  vim.defer_fn(function()
    local p = state.plugins[name]
    if name ~= ui.selected or ui.ctx.info[name] or reading[name] or not M.is_open() or not p then
      return
    elseif not p.path then
      return tries < 20 and fetch_info(tries + 1) or nil
    end
    reading[name] = true
    local out, left = {}, 3
    ---@param key string
    ---@param args string[]
    local function git(key, args)
      vim.system({ 'git', unpack(args) }, { cwd = p.path, text = true }, function(r)
        vim.schedule(function()
          if r.code == 0 then
            out[key] = r.stdout or ''
          elseif key ~= 'head' then
            out.err = out.err or vim.split(vim.trim(r.stderr or ''), '\n')[1]
          end
          left = left - 1
          if left > 0 then
            return
          end
          reading[name] = nil
          local default = vim.trim(out.head or ''):gsub('^origin/', '')
          local branches = {}
          for line in vim.gsplit(out.branches or '', '\n', { trimempty = true }) do
            local branch = line:match('^origin/(.+)$')
            if branch then
              table.insert(branches, branch == default and 1 or #branches + 1, branch)
            end
          end
          ui.ctx.info[name] = out.err
            or { branches = branches, tags = vim.split(out.tags or '', '\n', { trimempty = true }) }
          if name == ui.selected then
            draw_pane()
          end
        end)
      end)
    end
    git('head', { 'rev-parse', '--abbrev-ref', 'origin/HEAD' })
    git('branches', { 'branch', '--remote', '--list', '--format=%(refname:short)', '--', 'origin/**' })
    git('tags', { 'tag', '--list' })
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

---@type { verb: string, names: string[], done: fun(yes: boolean) }[] waiting for the one on show
local queued = {}

--- Ask yes or no about plugins on their own rows; y and n answer, and closing is a no.
--- While a row asks, the next question waits its turn.
---@param req { verb: string, names: string[], done: fun(yes: boolean) }
---@return boolean asked false when none of them has a row to ask on
function M.ask(req)
  if ui.ctx.ask then
    queued[#queued + 1] = req
    return true
  end
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
    ui.ctx.folded, ui.ctx.filter, ui.ctx.show = {}, nil, nil
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
    -- The next question; one with no row left to ask on is a no.
    local req = table.remove(queued, 1)
    while req and not M.ask(req) do
      req.done(false)
      req = table.remove(queued, 1)
    end
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

-- Extension keys go into the list once, when it is first made.
local extended = false

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
      note = M.note,
      ask = M.ask,
      answer = M.answer,
      input = M.input,
    })
  if not extended then
    extended = true
    for _, k in ipairs(M.ext.keys) do
      local function run()
        if not ui.ctx.ask and not ui.help then
          k.run(paned[k.view] and ui[paned[k.view]] or nil, ui.ctx)
          render()
        end
      end
      for _, lhs in ipairs(k.lhs) do
        local own = vim.iter(keys):find(function(e)
          return vim.list_contains(e[1], lhs)
        end)
        if own then
          -- In its view the extension's; elsewhere what it was.
          local before = own[2]
          own[2] = function()
            if ui.view == k.view then
              return run()
            end
            before()
          end
        else
          keys[#keys + 1] = {
            { lhs },
            function()
              if ui.view == k.view then
                run()
              end
            end,
            k.desc,
          }
        end
      end
    end
  end
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
  keep_plain(win)
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = 'Normal:NormalFloat'
  return win
end

--- Open the window, or switch an open one to `view`.
---@param view? string 'plugins', 'groups' or another view in M.views
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
  -- A no to the question on show and to every one waiting.
  local asks = vim.list_extend({ ui.ctx.ask }, queued)
  ui.ctx.ask, queued = nil, {}
  vim.schedule(function()
    for _, ask in ipairs(asks) do
      ask.done(false)
    end
  end)
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

--- Show a Report: on its plugin's row when it is about a plugin (the row keeps it for when
--- the Plugins view shows), else, being global, in the header. A warning or an error opens
--- the window.
---@param d { msg: string, level: integer, plugin?: string, shown?: boolean }
local function on_report(d)
  -- Shown already, on the command line: only the Log keeps it.
  if d.shown then
    return
  end
  d.handled = true
  local op = ui.ctx.op
  -- An operation's ending already says it.
  if op and op.message == d.msg then
    return
  end
  local on_row = d.plugin and state.plugins[d.plugin]
  if not on_row then
    ui.ctx.notice = { text = first_line(d.msg), level = d.level }
  elseif not (M.notes[d.plugin] and M.notes[d.plugin].sticky) then
    -- A failure that stays on the row keeps it.
    local levels = vim.log.levels
    local hl = d.level >= levels.ERROR and 'CinchFailed' or d.level >= levels.WARN and 'CinchWarn' or 'CinchMuted'
    M.note(d.plugin, { text = first_line(d.msg), hl = hl, warn = d.level >= levels.WARN })
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

--- Put a note on a plugin's row, or take it off. `chunks`, text with its groups, stands
--- in for `text` when it has more than one color.
---@param name string
---@param note? cinch.ui.Note
function M.note(name, note)
  M.notes[name] = note
  redraw()
  if note and not note.sticky then
    vim.defer_fn(function()
      if M.notes[name] == note then
        M.notes[name] = nil
        redraw()
      end
    end, notice_ms[note.warn == true])
  end
end

---@param opts? cinch.ui.Opts
function M.setup(opts)
  M.opts = vim.tbl_extend('force', M.opts, opts or {})
  ui.tall, ui.even = M.opts.start_tall == true, M.opts.start_even == true
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
    M.note(d.plugin.name, note)
  end, { priority = 10 })
  events.on('Activity', function(d)
    if d.to == 'building' then
      M.notes[d.plugin.name] = nil
    end
  end)
  -- An update says on its row which commit it moved from and to.
  local before = {} ---@type table<string, string> commit by plugin, as an update starts
  events.on('PackPre', function(d)
    if d.kind == 'update' and d.plugin then
      before[d.name] = require('cinch.pack').rev(d.plugin)
    end
  end)
  events.on('Pack', function(d)
    local from = before[d.name]
    before[d.name] = nil
    local to = d.kind == 'update' and d.plugin and require('cinch.pack').rev(d.plugin)
    if from and to and from ~= to then
      local old, new = from:sub(1, 7), to:sub(1, 7)
      M.note(d.name, {
        text = ('updated %s to %s'):format(old, new),
        hl = 'CinchName',
        chunks = {
          { 'updated ', 'CinchName' },
          { old, 'CinchCommit' },
          { ' to ', 'CinchName' },
          { new, 'CinchCommit' },
        },
      })
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
