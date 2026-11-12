-- The live first start in the window: it opens on Installing, before vim.pack.add,
-- in its install phase; each plugin's row turns installed as its progress arrives;
-- the colorscheme applies as soon as its plugin lands; then the same window settles
-- into the Plugins view.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch, events = require('cinch'), require('cinch.events')

cinch.ui_coming = function()
  return true
end

local seen = { progress = {} }
---@return string[]
local function list_lines()
  local w = require('cinch.features.ui').windows()
  return w.list and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w.list), 0, -1, false) or {}
end

cinch.setup({
  confirm = false,
  ui = { colorscheme = 'colory' },
  spec = {
    {
      { H.src('alpha.nvim') },
      { H.src('colory'), load = 'now' },
      { H.src('beta.nvim') },
      { H.src('missing') },
      { H.src('dashy'), load = 'now' },
    },
  },
})

-- Subscribed after the window's own, so they see what it drew.
events.on('Installing', function()
  seen.open_at_installing = require('cinch.features.ui').is_open()
  seen.first_lines = list_lines()
  seen.first_header = H.header()[2] or ''
end, { priority = 90 })
events.on('Progress', function(d)
  if d.name then
    seen.progress[#seen.progress + 1] = { name = d.name, handled = d.handled }
  end
end, { priority = 90 })
events.on('Installed', function()
  seen.colors_at_installed = vim.g.colors_name
  seen.done_lines = list_lines()
  seen.done_header = H.header()[2] or ''
end, { priority = 90 })

H.after_startup(function()
  H.eq(require('cinch.features.ui').is_open(), false, 'no window before the UI is up')
  vim.api.nvim_exec_autocmds('UIEnter', {})
  H.wait(function()
    return seen.done_lines ~= nil
  end, 'the install')

  H.eq(seen.open_at_installing, true, 'the window is open before vim.pack.add starts')
  H.eq(seen.first_header:find('Installing plugins (0/5)', 1, true) ~= nil, true, 'in its install phase')
  H.eq(seen.first_header:find('0% ', 1, true) ~= nil, true, 'with how far along it is')
  H.eq(seen.first_header:find('━', 1, true) ~= nil, true, 'and the graph, on the same line of the header')
  H.eq(seen.first_lines[1], ' ▾ installing 5', 'the rows at the top of the list')
  H.eq(table.concat(seen.first_lines, '\n'):find('cloning…', 1, true) ~= nil, true, 'every row cloning')
  H.eq(vim.list_contains(seen.first_lines, ' ▾ installing 5'), true, 'the rows under their section header')
  H.eq(#seen.progress >= 3, true, 'progress arrives for each plugin')
  H.eq(seen.progress[1].handled, true, 'and the window takes it over from the command line')
  H.eq(seen.colors_at_installed, 'colory', 'the colorscheme applied before the batch ended')
  local done = table.concat(seen.done_lines, '\n')
  H.eq(seen.done_header:find('Installed 4 of 5 plugins', 1, true) ~= nil, true, 'the outcome, when it ends')
  H.eq(done:find('could not install', 1, true) ~= nil, true, 'and which one failed')

  H.wait(function()
    return table.concat(list_lines(), '\n'):find('▾ loaded', 1, true) ~= nil
  end, 'the Plugins view')
  H.eq(H.header()[2]:find('Install', 1, true), nil, 'the same window, now the Plugins view')

  local ops = require('cinch.features.ui.ops')
  ---@param op table
  ---@param room integer
  local function op_line(op, room)
    return table.concat(vim.tbl_map(function(c)
      return c[1]
    end, ops.line(op, room)))
  end
  local running = op_line({ kind = 'install', total = 48, done = 18, status = {}, current = 'yanky.nvim' }, 60)
  H.eq(running:find('^Installing plugins %(18/48%) %- yanky%.nvim 37%% ━') ~= nil, true, running)
  H.eq(vim.fn.strdisplaywidth(running), 60, 'the graph takes the rest of the room')
  local wide = op_line({ kind = 'install', total = 48, done = 18, status = {}, current = 'yanky.nvim' }, 120)
  H.eq(vim.endswith(wide, ' 37% ' .. ('━'):rep(20)), true, 'up to 20 cells: ' .. wide)
  local op = { kind = 'install', total = 48, done = 18, status = {}, current = 'a-very-long-plugin-name.nvim' }
  local narrow = op_line(op, 35)
  H.eq(
    { narrow:find(' 37%% ━━━━━━$') ~= nil, vim.fn.strdisplaywidth(narrow) },
    { true, 35 },
    'a long name gives way to the percent and graph: ' .. narrow
  )

  local install = { kind = 'install', total = 2, done = 0, status = { a = 'cloning' } }
  local host = {
    ui = { ctx = { op = install } },
    is_open = function()
      return true
    end,
    redraw = function() end,
    opts = {},
  }
  require('cinch.features.ui.ops').progress(host, { title = 'Installing plugins', name = 'a' })
  H.eq({ install.current, install.done }, { 'a', 1 }, 'progress names the plugin it heard from')
  local w = require('cinch.features.ui').windows()
  H.eq(require('cinch.features.ui').is_open(), true, 'a now plugin opening a buffer did not close it')
  H.eq(vim.b[vim.api.nvim_win_get_buf(vim.fn.win_getid(1))].dashy, true, 'that buffer opened in your editor')
  H.eq(vim.api.nvim_get_current_win(), w.list, 'and focus is back on the list')
  H.eq(H.plugin('colory').state, 'loaded', 'and the plugins started')
  H.wait(function()
    local pane = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w.pane), 0, -1, false)
    return table.concat(pane, '\n'):find('\n branch +main') ~= nil
  end, 'the pane reading vim.pack once the plugin it shows has installed')
end)
