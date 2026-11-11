-- The cinch window's keys: what each one does, and the ? screen made from the same
-- list, so the two never disagree. ui/init.lua hands in what the keys act on, and
-- loads this file on the window's first open.

local events = require('cinch.events')
local state = require('cinch.state')

local api = vim.api

local M = {}

---@class cinch.ui.Window what the keys need from the window
---@field ui table its state: view, tall, even, help, selected, canvas, list, ctx
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
---@field ask fun(req: { verb: string, names: string[], done: fun(yes: boolean) }): boolean
---@field answer fun(yes: boolean)
---@field input fun(req: { prompt: string, text?: string, change?: fun(text: string), done: fun(text?: string) })
---@field in_editor fun(fn: fun()) run fn from the editor window cinch was opened from

---@class cinch.ui.Key
---@field [1] string[] the keys
---@field [2] fun() what they do
---@field [3] string what they do, in words, for ? and the mapping's desc
---@field asked? 'answer'|'no' while a row asks: `answer` still runs, `no` answers no; any other key waits

--- The keys of each view, for the footer.
M.hints = {
  plugins = ' / filter  l load  i install  b build  u update  d delete  s sync  S-CR select  ? keys  q close ',
  triggers = ' <CR> fold  l load what waits  <C-d> <C-u> details  <Tab> next view  ? keys  q close ',
  stats = ' <Tab> next view  - size  ? keys  q close ',
  profile = ' <CR> fold  <C-s> sort  <C-f> hide under ms  / filter  <Tab> next view  ? keys  q close ',
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

  --- What an action in the Plugins view applies to: the plugins you selected, in
  --- declaration order, or else the one under the cursor.
  ---@return string[]
  local function targets()
    if ui.view ~= 'plugins' then
      return {}
    end
    local marked, names = ui.ctx.marked or {}, {}
    if not next(marked) then
      return ui.selected and { ui.selected } or {}
    end
    for _, p in ipairs(state.list) do
      if marked[p.name] then
        names[#names + 1] = p.name
      end
    end
    for _, o in ipairs(ui.ctx.orphans or {}) do
      if marked[o.name] then
        names[#names + 1] = o.name
      end
    end
    return names
  end

  --- An action on the targets, run from your editor window, after which the
  --- selection is done with.
  ---@param fn fun(names: string[])
  local function act(fn)
    return function()
      local names = targets()
      if #names == 0 then
        return
      end
      w.in_editor(function()
        fn(names)
      end)
      ui.ctx.marked = {}
      w.redraw()
    end
  end

  ---@param names string[]
  ---@return string[] those your specs list
  local function in_specs(names)
    return vim.tbl_filter(function(name)
      return state.plugins[name] ~= nil
    end, names)
  end

  --- Select the row under the cursor, or let go of it, then move to the next row.
  local function toggle()
    local line = api.nvim_win_get_cursor(ui.list)[1]
    local name = ui.view == 'plugins' and ui.canvas and ui.canvas.rows[line]
    local p = name and state.plugins[name]
    if not name or (p and p.self) then
      return
    end
    ui.ctx.marked = ui.ctx.marked or {}
    ui.ctx.marked[name] = not ui.ctx.marked[name] or nil
    w.render()
    for l = line + 1, #ui.canvas.lines do
      if ui.canvas.rows[l] then
        api.nvim_win_set_cursor(ui.list, { l, 0 })
        break
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
    ---@param text? string
    local function set(text)
      ui.ctx.filter = text and text ~= '' and text or nil
    end
    -- Applied as you type.
    w.input({ prompt = 'filter: ', text = ui.ctx.filter, change = set, done = set })
  end

  --- Delete the selected plugins, or the one under the cursor, once you confirm. One
  --- your specs list is in use, so it goes with force and installs again on the next start.
  local function delete()
    local names = vim.tbl_filter(function(name)
      return state.plugins[name] ~= nil
        or vim.iter(ui.ctx.orphans or {}):any(function(o) ---@param o cinch.Orphan
          return o.name == name
        end)
    end, targets())
    if #names == 0 then
      return
    end
    local p = state.plugins[names[1]]
    if #names == 1 and p and p.self then
      return require('cinch').del(names)
    end
    local force = #in_specs(names) > 0
    w.ask({
      verb = 'Delete',
      names = names,
      done = function(yes)
        if yes then
          require('cinch').del(names, { force = force })
        end
      end,
    })
  end

  --- Profile: siblings in the order they began, or slowest first.
  local function profile_sort()
    if ui.view == 'profile' then
      ui.ctx.profile_sort = ui.ctx.profile_sort ~= 'time' and 'time' or nil
      w.render()
    end
  end

  --- Profile: hide entries that took less than a number of ms; empty shows them all.
  local function profile_min()
    if ui.view ~= 'profile' then
      return
    end
    local now = ui.ctx.profile_min
    w.input({
      prompt = 'hide entries under (ms): ',
      text = now and tostring(now) or '',
      done = function(text)
        if text then
          local ms = tonumber(text)
          ui.ctx.profile_min = ms and ms > 0 and ms or nil
        end
      end,
    })
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

  ---@type cinch.ui.Key[]
  local list = {
    {
      { '<CR>' },
      fold,
      'fold or open the section under the cursor',
    },
    { { '/' }, filter, 'filter by name, or the log by text; empty clears it' },
    {
      { 'l' },
      function()
        if ui.view == 'triggers' then
          -- Every plugin still waiting on the trigger under the cursor.
          local names = require('cinch.features.ui.triggers').waiting(ui.trigger)
          if #names > 0 then
            w.in_editor(function()
              require('cinch').load(names)
            end)
            w.redraw()
          end
          return
        end
        act(function(names)
          require('cinch').load(in_specs(names))
        end)()
      end,
      'load the plugin now, or the ones selected; in Triggers, what waits on the trigger',
    },
    {
      { 'i' },
      act(function(names)
        require('cinch').install(in_specs(names))
      end),
      'install the plugin, or the ones selected, when not on disk: a failed install, or one you deleted',
    },
    {
      { 'b' },
      act(function(names)
        require('cinch').build(in_specs(names))
      end),
      'run its build again, or theirs',
    },
    {
      { 'u' },
      act(function(names)
        local u = updates()
        local pending = vim.tbl_filter(function(name)
          return u ~= nil and u.results[name] ~= nil
        end, names)
        if u and #pending > 0 then
          u.apply(pending)
        else
          events.report(('no pending update for %s; c checks'):format(table.concat(names, ', ')))
        end
      end),
      'apply its pending update, or theirs',
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
        if not u then
          return
        end
        -- The selected plugins, or else all of them.
        local names = next(ui.ctx.marked or {}) and in_specs(targets()) or nil
        u.check(names, { notify = true })
        ui.ctx.marked = {}
        w.redraw()
      end,
      'check for updates in the background: the selected plugins, or all',
    },
    { { 'd' }, delete, 'delete the plugin, or the ones selected, from disk, once you confirm' },
    {
      { 'y' },
      function()
        w.answer(true)
      end,
      'yes, when a row asks',
      asked = 'answer',
    },
    {
      { 'n' },
      function()
        w.answer(false)
      end,
      'no, when a row asks',
      asked = 'answer',
    },
    {
      { 's' },
      function()
        w.in_editor(require('cinch').sync)
        w.redraw()
      end,
      'sync: install what is missing, offer to delete what no spec names, check for updates',
    },
    { { '<S-CR>', '<Space>' }, toggle, 'select the plugin under the cursor for l b u c d, or let it go' },
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
    { { '<C-s>' }, profile_sort, 'in Profile, sort by time taken or by when each began' },
    { { '<C-f>' }, profile_min, 'in Profile, hide entries that took less than some ms' },
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
        ui.even = not ui.even
        w.render()
      end,
      'switch the list and details between 70/30 and 50/50',
    },
    {
      { '-' },
      function()
        ui.tall = not ui.tall
        w.render()
      end,
      "switch between 75% and 95% of the editor's height",
    },
    { { 'q', 'Q' }, w.close, 'close', asked = 'no' },
    {
      { '<Esc>' },
      function()
        if next(ui.ctx.marked or {}) then
          ui.ctx.marked = {}
          return w.render()
        end
        w.close()
      end,
      'let go of the selection, or close',
      asked = 'no',
    },
  }
  -- While a row asks, only an answer gets through.
  for _, k in ipairs(list) do
    local fn = k[2]
    k[2] = function()
      if not ui.ctx.ask or k.asked == 'answer' then
        fn()
      elseif k.asked == 'no' then
        w.answer(false)
      end
    end
  end
  return list
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
