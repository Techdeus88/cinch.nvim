-- The cinch window: a float over the editor, 75% of it, 95% with `=`.
-- It draws what views.lua renders, redraws while open when cinch's state
-- changes, and turns keys into calls on cinch and its features. At startup this
-- file only declares `:Cinch open`; views and subscriptions wait for the first open.

local events = require('cinch.events')
local state = require('cinch.state')

local api = vim.api

local M = {}

---@class cinch.ui.Opts
---@field size? number share of the editor, default 0.75
---@field wide? number share after `=`, default 0.95
---@field border? string|string[] default: 'winborder', or rounded when that is empty

---@type cinch.ui.Opts
M.opts = { size = 0.75, wide = 0.95 }

local ui = {
  buf = nil, ---@type integer?
  win = nil, ---@type integer?
  view = 'plugins',
  wide = false,
  ---@type table<string, true>
  expanded = {},
  ---@type table<string, vim.pack.PlugData|string>
  info = {},
  canvas = nil, ---@type cinch.ui.Canvas?
  queued = false,
  subscribed = false,
}

local ns = api.nvim_create_namespace('cinch_ui')

local function views()
  return require('cinch.features.ui.views')
end

---@return boolean
local function is_open()
  return ui.win ~= nil and api.nvim_win_is_valid(ui.win)
end

---@return vim.api.keyset.win_config
local function geometry()
  local share = ui.wide and M.opts.wide or M.opts.size
  local lines = vim.o.lines - vim.o.cmdheight
  local w, h = math.floor(vim.o.columns * share), math.floor(lines * share)
  return {
    relative = 'editor',
    width = w,
    height = h,
    row = math.floor((lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
  }
end

--- The plugin under the cursor: its row, or the row its details hang under.
---@return cinch.Plugin?
local function cursor_plugin()
  local c = ui.canvas
  if not (c and is_open()) then
    return
  end
  for l = api.nvim_win_get_cursor(ui.win)[1], 1, -1 do
    if c.rows[l] then
      return state.plugins[c.rows[l]]
    end
    -- Details end at a blank line; above it is another section.
    if c.lines[l] == '' then
      return
    end
  end
end

local function render()
  if not is_open() then
    return
  end
  local keep = cursor_plugin()
  local c = views().render(ui.view, api.nvim_win_get_width(ui.win), { expanded = ui.expanded, info = ui.info })
  ui.canvas = c
  vim.bo[ui.buf].modifiable = true
  api.nvim_buf_set_lines(ui.buf, 0, -1, false, c.lines)
  vim.bo[ui.buf].modifiable = false
  api.nvim_buf_clear_namespace(ui.buf, ns, 0, -1)
  for _, h in ipairs(c.hls) do
    pcall(api.nvim_buf_set_extmark, ui.buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  -- Stay on the same plugin when rows move.
  if keep then
    for l, name in pairs(c.rows) do
      if name == keep.name then
        api.nvim_win_set_cursor(ui.win, { l, 0 })
        break
      end
    end
  end
end

--- Redraw on the next tick: a burst of events, like an install batch, draws once.
local function redraw()
  if ui.queued or not is_open() then
    return
  end
  ui.queued = true
  vim.schedule(function()
    ui.queued = false
    render()
  end)
end

--- What vim.pack knows about a plugin, read once per plugin until it changes on disk.
---@param p cinch.Plugin
local function fetch_info(p)
  local pack = require('cinch.pack')
  if not p.path then
    ui.info[p.name] = 'not on disk'
  elseif not pack.idle() then
    ui.info[p.name] = 'vim.pack is busy; r refreshes'
  else
    local ok, data = pack.get({ p.name }, { offline = true })
    ui.info[p.name] = ok and type(data) == 'table' and data[1] or tostring(data)
  end
end

---@return table?
local function updates()
  return package.loaded['cinch.features.updates']
end

-- Keys ------------------------------------------------------------------------

---@param fn fun(p: cinch.Plugin)
---@return fun()
local function on_plugin(fn)
  return function()
    local p = cursor_plugin()
    if p then
      fn(p)
      redraw()
    end
  end
end

--- Move `step` views along: plugins, stats, log, and round again.
---@param step integer
---@return fun()
local function cycle(step)
  return function()
    local tabs = views().tabs
    local i = 1
    for j, t in ipairs(tabs) do
      if t == ui.view then
        i = j
      end
    end
    M.open(tabs[(i - 1 + step) % #tabs + 1])
  end
end

---@type table<string, { [1]: fun(), [2]: string }>
local keys = {
  ['<Tab>'] = { cycle(1), 'Next view' },
  ['<S-Tab>'] = { cycle(-1), 'Previous view' },
  ['='] = {
    function()
      ui.wide = not ui.wide
      api.nvim_win_set_config(ui.win, geometry())
      render()
    end,
    'Switch between 75% and 95% of the editor',
  },
  ['<CR>'] = {
    on_plugin(function(p)
      ui.expanded[p.name] = not ui.expanded[p.name] or nil
      if ui.expanded[p.name] and not ui.info[p.name] then
        fetch_info(p)
      end
    end),
    'Show or hide the details and spec of the plugin under the cursor',
  },
  l = {
    on_plugin(function(p)
      require('cinch').load(p.name)
    end),
    'Load the plugin under the cursor',
  },
  b = {
    on_plugin(function(p)
      require('cinch').build(p.name)
    end),
    'Run the build of the plugin under the cursor',
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
    'Apply the update of the plugin under the cursor',
  },
  U = {
    function()
      local u = updates()
      if u then
        u.apply()
      end
    end,
    'Apply every pending update',
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
      ui.info = {}
      for name in pairs(ui.expanded) do
        local p = state.plugins[name]
        if p then
          fetch_info(p)
        end
      end
      render()
    end,
    'Refresh',
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

-- Window ----------------------------------------------------------------------

--- Subscribed on the first open, never at startup: a listener on State would
--- make every state change during startup build a payload for a closed window.
local function subscribe()
  if ui.subscribed then
    return
  end
  ui.subscribed = true
  for _, name in ipairs({ 'State', 'Activity', 'Load', 'LoadError', 'Build', 'Updates', 'Message' }) do
    if events.names[name] then
      events.on(name, redraw)
    end
  end
  events.on('Pack', function(d)
    -- What vim.pack knew about it is out of date.
    ui.info[d.name] = nil
    if ui.expanded[d.name] and d.plugin then
      vim.schedule(function()
        fetch_info(d.plugin)
      end)
    end
    redraw()
  end)
end

--- Open the window, or switch an open one to `view`.
---@param view? 'plugins'|'stats'|'log'
function M.open(view)
  if view and vim.list_contains(views().tabs, view) then
    ui.view = view
  end
  if is_open() then
    api.nvim_set_current_win(ui.win)
    return render()
  end
  for group, link in pairs(views().highlights) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
  subscribe()

  ui.buf = api.nvim_create_buf(false, true)
  vim.bo[ui.buf].filetype = 'cinch'
  vim.bo[ui.buf].bufhidden = 'wipe'
  local cfg = geometry()
  cfg.style = 'minimal'
  cfg.border = M.opts.border or (vim.o.winborder == '' and 'rounded' or nil)
  ui.win = api.nvim_open_win(ui.buf, true, cfg)
  vim.wo[ui.win].cursorline = true
  vim.wo[ui.win].wrap = false

  for lhs, def in pairs(keys) do
    vim.keymap.set('n', lhs, def[1], { buffer = ui.buf, nowait = true, desc = 'cinch: ' .. def[2] })
  end
  local group = api.nvim_create_augroup('cinch_ui', { clear = true })
  api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if is_open() then
        api.nvim_win_set_config(ui.win, geometry())
        render()
      end
    end,
  })
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(ui.win),
    once = true,
    callback = function()
      ui.win, ui.buf, ui.canvas = nil, nil, nil
      api.nvim_del_augroup_by_id(group)
    end,
  })

  render()
  -- Opening checks for updates when the last check is stale, in the background.
  local u = updates()
  if u and not u.checking and not u.fresh() then
    u.check()
    redraw()
  end
end

function M.close()
  if is_open() then
    api.nvim_win_close(ui.win, true)
  end
end

-- `:Cinch open [view]`, and plain `:Cinch`, found by command.lua.
M.commands = {
  open = {
    run = function(args)
      M.open(args[1])
    end,
    complete = function()
      return views().tabs
    end,
  },
}

---@param opts? cinch.ui.Opts
function M.setup(opts)
  M.opts = vim.tbl_extend('force', M.opts, opts or {})
end

return M
