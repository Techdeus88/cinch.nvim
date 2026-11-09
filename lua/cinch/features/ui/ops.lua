-- Install, check, update and delete in the window, all the same way: a header line
-- with the progress, rows that change in place, then a line that says how it ended.
-- An install also opens the window and lists every plugin with its install status;
-- an update opens it too. A check never opens it, and a delete only gets the ending.
-- ui/init.lua listens for the events and loads this file the first time one fires.

local state = require('cinch.state')
local summary = require('cinch.ops').summary

local M = {}

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
  op.current = d.name or op.current
  if kind == 'install' then
    if d.name and op.status[d.name] == 'cloning' then
      op.status[d.name] = 'installed'
      op.done = op.done + 1
      M.colorscheme(w)
    end
  elseif counts and d.done then
    op.done = math.min(d.done, op.total)
  end
  -- The window shows it, so the command line does not.
  d.handled = w.is_open()
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
