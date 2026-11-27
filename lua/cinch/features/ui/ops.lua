-- Install, check, update and delete in the window: rows that change in place, then a line
-- in the header that says how it ended. While an install, a check or an update runs, the
-- middle of the header has its overall progress, `Installing plugins (18/48) ━━━━`, and
-- each plugin's row how far it is. A plugin that installs has a row in the installing
-- section, which moves to its place in the list as it lands. An install and an update
-- open the window; a check never does, and a delete only gets the ending.
-- ui/init.lua listens for the events and loads this file the first time one fires.

local canvas = require('cinch.features.ui.canvas')
local state = require('cinch.state')
local summary = require('cinch.ops').summary

local M = {}

-- What the progress line says for each operation; a delete only shows its ending.
local doing = { install = 'Installing plugins', check = 'Checking plugins', update = 'Updating plugins' }
local graph_min, graph_max = 6, 20

--- The operation in at most `room` cells: `Installing plugins (18/48) ━━━━`, or how it
--- ended; and whether its words had to be cut to fit. Which plugin is where is on the rows.
---@param op cinch.ui.Op
---@param room integer
---@return { [1]: string, [2]?: string }[] line, boolean cut
function M.line(op, room)
  if op.message or not doing[op.kind] then
    local text = op.message or ''
    return canvas.clip({ { text, 'CinchTitle' } }, room), canvas.cells(text) > room
  end
  local left = ('%s (%d/%d) '):format(doing[op.kind], op.done, op.total)
  -- The words give way first, so the graph stays in view.
  local fits = room - graph_min
  local cut = canvas.cells(left) > fits
  if cut then
    left = canvas.fit(left, fits - 1) .. ' '
  end
  local graph = math.max(0, math.min(graph_max, room - canvas.cells(left)))
  return canvas.clip(vim.list_extend({ { left, 'CinchTitle' } }, canvas.pill(op.done, op.total, graph)), room), cut
end

---@class cinch.ui.OpHost what an operation needs from the window
---@field ui table its state: ctx, colors_done
---@field opts cinch.ui.Opts
---@field open fun(view?: string)
---@field is_open fun(): boolean
---@field render fun()
---@field redraw fun()
---@field animate fun()
---@field focus fun(to: 'editor'|'list')

---@param path string a plugin's folder
---@param name string
---@return boolean
local function ships_colors(path, name)
  -- Not glob(): on Windows `{vim,lua}` only expands in a pattern that also has `*?[`.
  local base = vim.fs.joinpath(path, 'colors', name)
  return vim.uv.fs_stat(base .. '.lua') ~= nil or vim.uv.fs_stat(base .. '.vim') ~= nil
end

--- Apply `opts.colorscheme` once a plugin that ships it is on disk: on the
--- runtimepath at once, so the rest of the install already shows in your colors.
---@param w cinch.ui.OpHost
function M.colorscheme(w)
  local ui, name = w.ui, w.opts.colorscheme
  if not name or ui.colors_done or vim.g.colors_name then
    return
  end
  local dir = require('cinch.pack').dir
  local op = ui.ctx.op
  for _, p in ipairs(state.list) do
    local status = op and op.kind == 'install' and op.status[p.name]
    local path = p.path or vim.fs.joinpath(dir, p.name)
    if status ~= 'cloning' and ships_colors(path, name) then
      pcall(vim.cmd.packadd, { vim.fn.escape(p.name, ' '), bang = true })
      ui.colors_done = pcall(vim.cmd.colorscheme, name)
      return
    end
  end
end

-- Progress titles: which operation each belongs to, and whether it moves the count.
-- An online update downloads first, for every plugin; only applying counts.
local titles = {
  { '^Installing', 'install', true },
  { '^Applying updates', 'update', true },
  { '^Downloading updates', 'update', false },
  { '^Computing updates', 'update', false },
  { '^Checking plugins', 'check', true },
}

---@param w cinch.ui.OpHost
---@param kind cinch.OpKind
---@param d { names: string[] }
function M.start(w, kind, d)
  -- An install during init.lua has no screen to draw on; the message feature shows it.
  if kind == 'delete' or (kind == 'install' and vim.v.vim_did_enter == 0) then
    return
  end
  -- A check in the background never takes the header from one still running.
  local running = w.ui.ctx.op
  if kind == 'check' and running and not running.message then
    return
  end
  local op = { kind = kind, total = #d.names, done = 0, status = {} }
  if kind == 'install' then
    for _, name in ipairs(d.names) do
      op.status[name] = 'cloning'
    end
  end
  w.ui.ctx.op = op
  if kind == 'install' then
    M.colorscheme(w)
  end
  local opens = kind ~= 'check' and w.opts.open_on_install ~= false and vim.v.vim_did_enter == 1
  if kind == 'install' and opens then
    w.open('plugins')
  elseif opens and not w.is_open() then
    w.open('plugins')
  elseif w.is_open() then
    w.render()
  end
  w.animate()
  -- Install and update hold the loop: on screen before vim.pack starts.
  if kind ~= 'check' and w.is_open() then
    vim.cmd.redraw()
  end
end

---@param w cinch.ui.OpHost
---@param d { title: string, name?: string, done?: integer, handled?: boolean }
function M.progress(w, d)
  -- The window shows it, and the command line never does once Neovim is up; while it
  -- starts, the message feature holds it for then.
  d.handled = w.is_open() or vim.v.vim_did_enter == 1
  local op = w.ui.ctx.op
  local kind, counts
  for _, t in ipairs(titles) do
    if d.title:find(t[1]) then
      kind, counts = t[2], t[3]
      break
    end
  end
  if not (op and op.kind == kind) then
    return
  end
  if kind == 'install' then
    if d.name and op.status[d.name] == 'cloning' then
      op.status[d.name] = 'installed'
      op.done = op.done + 1
      M.colorscheme(w)
    end
  elseif counts and d.done then
    op.done = math.min(d.done, op.total)
  end
  w.redraw()
end

--- The install's ending: the outcome, then focus goes to your editor while plugins load.
---@param w cinch.ui.OpHost
---@param op table
---@param d { names: string[], failed: string[], ms: number }
local function installed(w, op, d)
  for _, name in ipairs(d.names) do
    op.status[name] = vim.list_contains(d.failed, name) and 'failed' or 'installed'
  end
  w.render()
  -- Plugins load next. Give focus back to your editor first, so one that opens a
  -- buffer or a window as it loads (a dashboard, say) does it there.
  w.focus('editor')
  local editor = vim.api.nvim_get_current_win()
  -- A moment to read it, then the same rows settle into the Plugins view.
  vim.defer_fn(function()
    if w.ui.ctx.op == op then
      w.ui.ctx.op = nil
    end
    M.colorscheme(w)
    w.render()
    w.animate()
    -- Back to the list, unless a plugin moved focus somewhere else meanwhile.
    if w.is_open() and vim.api.nvim_get_current_win() == editor then
      w.focus('list')
    end
  end, 1200)
end

---@param w cinch.ui.OpHost
---@param kind cinch.OpKind
---@param d table the Installed, Checked, Updated or Deleted payload
function M.finish(w, kind, d)
  local op = w.ui.ctx.op
  -- A delete has no start in the window; it takes over from an ending still on show.
  if kind == 'delete' and (not op or op.message) then
    op = { kind = 'delete', total = #d.names, done = #d.names, status = {} }
    w.ui.ctx.op = op
  end
  if not (op and op.kind == kind) then
    return
  end
  op.done = op.total
  op.message = summary(kind, d)
  if kind == 'install' then
    return installed(w, op, d)
  end
  w.redraw()
  vim.defer_fn(function()
    if w.ui.ctx.op == op then
      w.ui.ctx.op = nil
      w.redraw()
      w.animate()
    end
  end, 1200)
end

return M
