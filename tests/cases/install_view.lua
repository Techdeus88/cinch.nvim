-- The live first start in the window: it opens before vim.pack.add with a row in an
-- installing section for each plugin cloning, each with how far it is, and the overall
-- count and a graph in the header, no plugin's name; each row leaves the section for its
-- place in the list as its plugin lands, and never stops in working on the way;
-- the colorscheme applies as soon as its plugin lands; then the same window settles
-- into the Plugins view.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch, events = require('cinch'), require('cinch.events')

cinch.ui_coming = function()
  return true
end

local seen = { progress = {} }
--- A line with its graph taken out, and whether it had one.
---@param line string
---@return string words, boolean graph
local function words(line)
  local out, n = line:gsub('━', '')
  return vim.trim(out), n > 0
end
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
---@return integer? count the installing section says it holds; nil without one
local function installing_count()
  for _, l in ipairs(list_lines()) do
    local n = l:match('^ ▾ installing (%d+)$')
    if n then
      return tonumber(n)
    end
  end
end
events.on('Progress', function(d)
  if d.name then
    -- The window redraws on the next tick; look after it has.
    vim.schedule(function()
      local text = table.concat(list_lines(), '\n')
      seen.progress[#seen.progress + 1] = {
        name = d.name,
        handled = d.handled,
        header = H.header()[2] or '',
        installing = installing_count(),
        -- Still cloning: its row is in the installing section, with how far it is.
        cloning = text:find(vim.pesc(d.name) .. ' %d+%% ━') ~= nil,
        working = text:find('▾ working', 1, true) ~= nil,
        -- Landed: its own row, the way the Plugins view draws it, not indented under a title.
        row = text:find('\n %S+ ' .. vim.pesc(d.name) .. ' ') ~= nil,
      }
    end)
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
  H.eq(
    { words(seen.first_header) },
    { 'Installing plugins (0/5)', true },
    'the overall count and the graph in the header, nothing else: ' .. seen.first_header
  )
  H.eq(vim.list_contains(seen.first_lines, ' ▾ installing 5'), true, 'a row for each plugin, under its section')
  local first = table.concat(seen.first_lines, '\n')
  H.eq(select(2, first:gsub('\n   %S+ [%w.-]+ 0%% ━', '')), 5, 'every row with how far it is: ' .. first)
  H.eq(#seen.progress >= 3, true, 'progress arrives for each plugin')
  H.eq(seen.progress[1].handled, true, 'and the window takes it over from the command line')
  for _, pr in ipairs(seen.progress) do
    H.eq(
      { cloning = pr.cloning, working = pr.working, row = pr.row },
      { cloning = false, working = false, row = true },
      pr.name .. ' goes from the installing section straight to its own row'
    )
    H.eq(
      { words(pr.header):find('^Installing plugins %(%d/5%)$') ~= nil, select(2, words(pr.header)) },
      { true, true },
      'and the header names no plugin: ' .. pr.header
    )
  end
  H.eq(
    { H.noted('Receiving objects'), H.noted('Cloning into'), H.noted('remote: ') },
    { false, false, false },
    "git's progress, which cinch asked for, never reaches your messages"
  )
  local counts = vim.tbl_map(function(pr)
    return pr.installing or 0
  end, seen.progress)
  H.eq(counts[1] < 5, true, 'the section holds fewer rows once one has landed: ' .. vim.inspect(counts))
  H.eq(seen.colors_at_installed, 'colory', 'the colorscheme applied before the batch ended')
  local done = table.concat(seen.done_lines, '\n')
  H.eq(seen.done_header:find('Installed 4 of 5 plugins', 1, true) ~= nil, true, 'the outcome, when it ends')
  H.eq(done:find('not installed', 1, true) ~= nil, true, 'and which one failed, on its official row')
  H.eq(done:find('▾ installing', 1, true), nil, 'with no installing section left')

  H.wait(function()
    local text = table.concat(list_lines(), '\n')
    return text:find('▾ installing', 1, true) == nil
      and text:find(' alpha%.nvim ') ~= nil
      and (H.header()[2] or ''):find('Install', 1, true) == nil
  end, 'the Plugins view, once the ending has had its moment')
  H.eq(H.header()[2]:find('Install', 1, true), nil, 'the same window, now the Plugins view')

  local ops = require('cinch.features.ui.ops')
  ---@param op table
  ---@param room integer
  local function op_line(op, room)
    return table.concat(vim.tbl_map(function(c)
      return c[1]
    end, ops.line(op, room)))
  end
  local running = op_line({ kind = 'install', total = 48, done = 18, status = {} }, 60)
  H.eq({ words(running) }, { 'Installing plugins (18/48)', true }, 'the count and the graph: ' .. running)
  H.eq(vim.fn.strdisplaywidth(running), 47, 'the graph takes the rest of the room, up to 20 cells')
  local checking = op_line({ kind = 'check', total = 61, done = 3, status = {} }, 60)
  H.eq({ words(checking) }, { 'Checking plugins (3/61)', true }, checking)
  local updating = op_line({ kind = 'update', total = 4, done = 2, status = {} }, 60)
  H.eq({ words(updating) }, { 'Updating plugins (2/4)', true }, updating)
  local op = { kind = 'install', total = 48, done = 18, status = {} }
  local narrow = op_line(op, 20)
  H.eq(
    { narrow:find(' ━━━━━━$') ~= nil, vim.fn.strdisplaywidth(narrow) },
    { true, 20 },
    'the words give way to the graph: ' .. narrow
  )

  for _, room in ipairs({ 10, 5, 3, 0 }) do
    local tiny = op_line(op, room)
    H.eq(vim.fn.strdisplaywidth(tiny) <= room, true, ('%d cells: "%s" overflows'):format(room, tiny))
  end

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
  H.eq({ install.status.a, install.done }, { 'installed', 1 }, 'progress lands the plugin it heard from')
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
