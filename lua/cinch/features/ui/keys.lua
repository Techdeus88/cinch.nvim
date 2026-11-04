-- The cinch window's keys: what each one does, and the ? screen made from the same
-- list, so the two never disagree. ui/init.lua hands in what the keys act on, and
-- loads this file on the window's first open.

local events = require('cinch.events')
local state = require('cinch.state')

local api = vim.api

local M = {}

---@class cinch.ui.Window what the keys need from the window
---@field ui table its state: view, wide, help, selected, canvas, list, ctx
---@field views string[]
---@field render fun()
---@field redraw fun()
---@field fetch_info fun()
---@field read_orphans fun()
---@field scroll_pane fun(down: boolean)
---@field find_spec_line fun(p: cinch.Plugin)
---@field newest fun() put the cursor on the last line
---@field open fun(view?: string)
---@field close fun()
---@field in_editor fun(fn: fun()) run fn from the editor window cinch was opened from

---@class cinch.ui.Key
---@field [1] string[] the keys
---@field [2] fun() what they do
---@field [3] string what they do, in words, for ? and the mapping's desc

--- The keys of each view, for the frame's bottom border.
M.hints = {
  plugins = ' / filter  l load  b build  u update  d delete  <C-d> <C-u> details  ? keys  q close ',
  stats = ' <Tab> next view  = size  ? keys  q close ',
  log = ' / filter  G newest  <Tab> next view  ? keys  q close ',
  help = ' ? goes back  q close ',
  install = " installing · keys you press now run when it's done · q hides this ",
}

---@return table?
local function updates()
  return package.loaded['cinch.features.updates']
end

--- Every key of the window.
---@param w cinch.ui.Window
---@return cinch.ui.Key[]
function M.make(w)
  local ui = w.ui

  --- A key that acts on the plugin under the cursor, in the Plugins view.
  ---@param fn fun(p: cinch.Plugin)
  local function on_plugin(fn)
    return function()
      local p = ui.selected and state.plugins[ui.selected]
      if p and ui.view == 'plugins' then
        -- From your editor window: a plugin that loads now and opens a buffer
        -- opens it there.
        w.in_editor(function()
          fn(p)
        end)
        w.redraw()
      end
    end
  end

  ---@param step integer
  local function cycle(step)
    return function()
      local i = 1
      for j, v in ipairs(w.views) do
        if v == ui.view then
          i = j
        end
      end
      w.open(w.views[(i - 1 + step) % #w.views + 1])
    end
  end

  local function fold()
    local line = api.nvim_win_get_cursor(ui.list)[1]
    local key = ui.canvas and ui.canvas.sections[line]
    if key then
      ui.ctx.folded[key] = not ui.ctx.folded[key] or nil
      w.render()
      api.nvim_win_set_cursor(ui.list, { math.min(line, api.nvim_buf_line_count(api.nvim_win_get_buf(ui.list))), 0 })
    end
  end

  local function filter()
    vim.ui.input({ prompt = 'filter: ', default = ui.ctx.filter }, function(text)
      ui.ctx.filter = text and text ~= '' and text or nil
      vim.schedule(w.render)
    end)
  end

  --- Delete the plugin under the cursor from disk, once you confirm. One your specs
  --- list is in use, so it goes with force and installs again on the next start.
  local function delete()
    local name = ui.view == 'plugins' and ui.selected
    if not name then
      return
    end
    local p = state.plugins[name]
    local orphan = vim.iter(ui.ctx.orphans or {}):any(function(o) ---@param o cinch.Orphan
      return o.name == name
    end)
    if not (p or orphan) then
      return
    end
    local question = p
        and ('`%s` is in your specs, so it installs again on the next start. Delete it from disk anyway?'):format(name)
      or ('Delete `%s` from disk?'):format(name)
    if vim.fn.confirm(question, '&Yes\n&No', 2) ~= 1 then
      return
    end
    w.in_editor(function()
      require('cinch').del({ name }, { force = p ~= nil })
    end)
    w.redraw()
  end

  local function goto_spec()
    local p = ui.selected and state.plugins[ui.selected]
    if not (p and p.origin and p.origin.file) then
      return
    end
    w.find_spec_line(p)
    local line = ui.ctx.spec_lines[p.name]
    w.close()
    vim.cmd.edit(vim.fn.fnameescape(p.origin.file))
    if line then
      api.nvim_win_set_cursor(0, { line, 0 })
    end
  end

  return {
    {
      { '<CR>' },
      fold,
      'fold or open the section under the cursor',
    },
    { { '/' }, filter, 'filter by name, or the log by text; empty clears it' },
    {
      { 'l' },
      on_plugin(function(p)
        require('cinch').load(p.name)
      end),
      'load the plugin now',
    },
    {
      { 'b' },
      on_plugin(function(p)
        require('cinch').build(p.name)
      end),
      'run its build again',
    },
    {
      { 'u' },
      on_plugin(function(p)
        local u = updates()
        if u and u.results[p.name] then
          u.apply({ p.name })
        else
          events.report(('no pending update for `%s`; c checks'):format(p.name))
        end
      end),
      'apply its pending update',
    },
    {
      { 'U' },
      function()
        local u = updates()
        if u then
          w.in_editor(u.apply)
        end
      end,
      'apply every pending update',
    },
    {
      { 'c' },
      function()
        local u = updates()
        if u then
          u.check(nil, { notify = true })
          w.redraw()
        end
      end,
      'check for updates in the background',
    },
    { { 'd' }, delete, 'delete the plugin from disk, once you confirm' },
    {
      { '<C-d>' },
      function()
        w.scroll_pane(true)
      end,
      'scroll the details pane down',
    },
    {
      { '<C-u>' },
      function()
        w.scroll_pane(false)
      end,
      'scroll the details pane up',
    },
    { { 'gf' }, goto_spec, 'open the spec file at the plugin' },
    {
      { 'gx' },
      on_plugin(function(p)
        vim.ui.open(p.src)
      end),
      'open its url',
    },
    {
      { 'r' },
      function()
        ui.ctx.info = {}
        w.read_orphans()
        w.fetch_info()
        w.render()
      end,
      'read what vim.pack knows again',
    },
    { { 'G' }, w.newest, 'jump to the newest log entry' },
    {
      { '?' },
      function()
        ui.help = not ui.help
        w.render()
      end,
      'show these keys',
    },
    { { '<Tab>' }, cycle(1), 'next view' },
    { { '<S-Tab>' }, cycle(-1), 'previous view' },
    {
      { '=' },
      function()
        ui.wide = not ui.wide
        w.render()
      end,
      'switch between 75% and 95% of the editor',
    },
    { { 'q', 'Q', '<Esc>' }, w.close, 'close' },
  }
end

--- Map every key on the list's buffer.
---@param buf integer
---@param keys cinch.ui.Key[]
function M.map(buf, keys)
  for _, k in ipairs(keys) do
    for _, lhs in ipairs(k[1]) do
      vim.keymap.set('n', lhs, k[2], { buffer = buf, nowait = true, desc = 'cinch: ' .. k[3] })
    end
  end
end

--- The ? screen, made from the same list the keys are mapped from.
---@param width integer
---@param keys cinch.ui.Key[]
---@return cinch.ui.Canvas
function M.help(width, keys)
  local canvas = require('cinch.features.ui.canvas')
  local c = canvas.new(width)
  c:add({ { ' keys', 'CinchSection' } })
  c:blank()
  c:add({ { '   ' .. canvas.fit('j k', 16), 'CinchKey' }, { 'move between plugins; the pane follows' } })
  for _, k in ipairs(keys) do
    c:add({ { '   ' .. canvas.fit(table.concat(k[1], ' '), 16), 'CinchKey' }, { k[3] } })
  end
  return c
end

return M
