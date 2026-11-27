-- The Plugins view: the list on the left and the detail pane on the right, which
-- follows the plugin under the cursor. While plugins install, each one has a row in an
-- `installing` section above the list; as it lands, that row moves to its official
-- place in the list, which every later message uses. This file composes the list;
-- rows.lua draws each row and details.lua the pane.
-- Nothing here changes state or calls vim.pack; the window hands in what it knows.

local canvas = require('cinch.features.ui.canvas')
local details = require('cinch.features.ui.details')
local rows = require('cinch.features.ui.rows')
local state = require('cinch.state')

local M = {}

---@class cinch.ui.Op an install, check, update or delete under way, or just ended
---@field kind cinch.OpKind
---@field total integer
---@field done integer
---@field current? string the plugin that last reported progress
---@field status table<string, 'queued'|'cloning'|'installed'|'failed'> each plugin's install status; only the queued and cloning ones are in the installing section
---@field message? string how it ended, shown for a moment

---@class cinch.ui.Ctx
---@field folded table<string, true> sections folded shut
---@field filter? string only plugins whose name contains it
---@field show? string only plugins in this state, from the filters above the list; nil: all
---@field tick integer spinner frame
---@field info table<string, { branches: string[], tags: string[] }|string> branches and tags per plugin, or git's error
---@field spec_lines table<string, integer|false> line of each plugin's spec in its file; false: not found
---@field op? cinch.ui.Op set while an install, check, update or delete runs
---@field orphans? cinch.Orphan[] on disk, in no spec
---@field marked? table<string, true> plugins selected for an action
---@field grouping? string the Plugins list is split by this grouping, not by state
---@field ask? { verb: string, names: table<string, true>, done: fun(yes: boolean) } a yes or no on their rows
---@field profile_sort? 'time' the Profile view sorts siblings by time, not order
---@field profile_min? number the Profile view hides what took less, in ms

-- Drawn by rows.lua and details.lua, kept here under the names views and tests use.
M.sections = rows.sections
M.section_of = rows.section_of
M.icons = rows.icons
M.glyph = rows.glyph
M.kind_chip = rows.kind_chip
M.pane = details.pane

local mark, message = rows.mark, rows.message
local add_row, load_ms, pending, dependents = rows.add_row, rows.load_ms, rows.pending, rows.dependents

--- Whether the filter chosen above the list shows `p`.
---@param p cinch.Plugin
---@param ctx cinch.ui.Ctx
---@return boolean
local function shows_state(p, ctx)
  return not ctx.show or rows.state_of(p) == ctx.show
end

--- Split the list another way: `working` keeps its section and title, and the rest go
--- into the grouping's sections, in declaration order within each. Changes `by`.
---@param by table<string, cinch.Plugin[]>
---@param grouping cinch.ui.Grouping
---@return table[] sections
local function regroup(by, grouping)
  local at = {}
  for i, p in ipairs(state.list) do
    at[p] = i
  end
  local keys, into = {}, {}
  for key, list in pairs(by) do
    if key ~= 'working' then
      for _, p in ipairs(list) do
        local g = grouping.of(p)
        if not into[g] then
          into[g], keys[#keys + 1] = {}, g
        end
        table.insert(into[g], p)
      end
      by[key] = nil
    end
  end
  local sections = { M.sections[1] }
  for _, g in ipairs(grouping.order(keys)) do
    local list = into[g]
    table.sort(list, function(a, b)
      return at[a] < at[b]
    end)
    by['group ' .. g] = list
    sections[#sections + 1] = { key = 'group ' .. g, titled = true, chunks = grouping.title(g, list) }
  end
  return sections
end

---@param ctx cinch.ui.Ctx
---@return cinch.Plugin[]
local function visible(ctx)
  -- `/<prefix>:<value>`, when an extension knows the prefix; else by name.
  local prefix, value = (ctx.filter or ''):match('^(%w+):(.*)$')
  local ui = package.loaded['cinch.features.ui']
  local by = prefix and ui and ui.ext.filters[prefix]
  return vim.tbl_filter(function(p)
    if not shows_state(p, ctx) then
      return false
    elseif by then
      return by(p, value)
    end
    return not ctx.filter or p.name:lower():find(ctx.filter:lower(), 1, true) ~= nil
  end, state.yours())
end

--- The filters, `● Loaded (18)`, the chosen one on the tab color; with labels when they
--- fit, else `● 18`. Then a rule under them, as the pane has under its title.
---@param c cinch.ui.Canvas
---@param ctx cinch.ui.Ctx
---@param skip? table<string, true> plugins still installing: not counted until they land
local function subheader(c, ctx, skip)
  local chosen = ctx.show or 'all'
  local line
  for _, labels in ipairs({ true, false }) do
    line = { { ' ' } }
    for i, f in ipairs(rows.filter_counts(ctx.show, skip)) do
      local text = labels and ('%s (%d) '):format(f.label, f.n) or ('%d '):format(f.n)
      if i > 1 then
        line[#line + 1] = { ' ' }
      end
      if f.key == chosen then
        line[#line + 1] = { ' ' .. f.mark .. ' ' .. text, 'CinchTab' }
      else
        line[#line + 1] = { ' ' .. f.mark .. ' ', f.hl }
        line[#line + 1] = { text, 'CinchMuted' }
      end
    end
    local n = 0
    for _, ch in ipairs(line) do
      n = n + canvas.cells(ch[1])
    end
    if n <= c.width then
      break
    end
  end
  c:add(canvas.clip(line, c.width))
  c:add({ { ' ' .. ('─'):rep(c.width - 2), 'CinchRule' } })
end

--- Draw the row as a question when one is asked about this plugin.
---@param c cinch.ui.Canvas
---@param ctx cinch.ui.Ctx
---@param name string
---@param m string its mark
---@param m_hl? string
---@param indent? boolean under a section title
---@return boolean asked
local function asks(c, ctx, name, m, m_hl, indent)
  local ask = ctx.ask
  if ask and ask.names[name] then
    rows.add_ask_row(c, name, ask.verb, m, m_hl, indent)
    return true
  end
  return false
end

--- Plugins with pending updates, taken from the section they would be in, with cinch
--- itself, which has a row only here. One that is working, failed or off stays there.
---@param plugins cinch.Plugin[]
---@param ctx cinch.ui.Ctx
---@return cinch.Plugin[]
local function with_updates(plugins, ctx)
  local out = {}
  for _, p in ipairs(state.list) do
    local key = M.section_of(p)
    local shown = p.self
        and shows_state(p, ctx)
        and (not ctx.filter or p.name:lower():find(ctx.filter:lower(), 1, true))
      or vim.list_contains(plugins, p)
    if shown and pending(p) and (key == 'loaded' or key == 'waiting') then
      out[#out + 1] = p
    end
  end
  return out
end

--- The Updates section, drawn only when it has something: plugins with pending updates,
--- then what is on disk in no spec.
---@param c cinch.ui.Canvas
---@param list cinch.Plugin[]
---@param orphans cinch.Orphan[]
---@param ctx cinch.ui.Ctx
---@return boolean drawn
local function updates_section(c, list, orphans, ctx)
  local count = #list + #orphans
  if count == 0 then
    return false
  end
  local open = not ctx.folded.updates
  c:add({
    { (open and ' ▾ ' or ' ▸ ') .. 'Updates', 'CinchSection' },
    { (' (%d)'):format(count), 'CinchMuted' },
  }, { section = 'updates' })
  if not open then
    return true
  end
  for _, p in ipairs(list) do
    local m, m_hl = mark(p, ctx.tick)
    if not asks(c, ctx, p.name, m, m_hl, true) then
      rows.add_update_row(c, p, ctx.tick, ctx.marked and ctx.marked[p.name])
    end
  end
  for _, o in ipairs(orphans) do
    if not asks(c, ctx, o.name, '·', 'CinchMuted', true) then
      c:add(
        { { '   · ' .. o.name .. ' ', 'CinchMuted' }, { 'not in specs', 'CinchWarn' } },
        { plugin = o.name, line_hl = ctx.marked and ctx.marked[o.name] and 'CinchMarked' or nil }
      )
    end
  end
  return true
end

-- Each install status that has a row in the installing section: its mark (nil: the
-- spinner), its color, the message. A plugin that landed or failed has left it.
local install_look = {
  queued = { '·', 'CinchMuted', 'queued' },
  cloning = { nil, 'CinchActive', 'cloning…' },
}

--- The plugins of the install under way that have not landed yet, by name.
---@param ctx cinch.ui.Ctx
---@return table<string, true>
local function installing_names(ctx)
  local out = {}
  local op = ctx.op
  for name, status in pairs(op and op.kind == 'install' and op.status or {}) do
    if install_look[status] and state.plugins[name] then
      out[name] = true
    end
  end
  return out
end

--- The installing section: a row for each plugin that is cloning, new to the list.
--- Drawn only while there is one; the rest of the list has no row for it until it lands.
---@param c cinch.ui.Canvas
---@param ctx cinch.ui.Ctx
---@param list cinch.Plugin[] the installing plugins the filters show
---@return boolean drawn
local function install_section(c, ctx, list)
  if #list == 0 then
    return false
  end
  local needed = dependents()
  local open = not ctx.folded.installing
  c:add({
    { (open and ' ▾ ' or ' ▸ ') .. 'installing', 'CinchSection' },
    { ' ' .. #list, 'CinchMuted' },
  }, { section = 'installing' })
  for _, p in ipairs(open and list or {}) do
    local look = install_look[ctx.op.status[p.name]]
    local m, m_hl = look[1] or canvas.spinner[ctx.tick % #canvas.spinner + 1], look[2]
    if not asks(c, ctx, p.name, m, m_hl, true) then
      add_row(c, p, {
        mark = m,
        mark_hl = m_hl,
        slowest = 0,
        needed_by = needed[p.name] or {},
        msg = look[3],
        msg_hl = look[2],
        only_msg = true,
        indent = true,
      })
    end
  end
  return true
end

--- The list, `width` cells wide.
---@param width integer
---@param ctx cinch.ui.Ctx
---@return cinch.ui.Canvas
function M.list(width, ctx)
  local c = canvas.new(width)
  local installing_now = installing_names(ctx)
  local plugins, installing = {}, {}
  for _, p in ipairs(visible(ctx)) do
    table.insert(installing_now[p.name] and installing or plugins, p)
  end
  local slowest = 0
  for _, p in ipairs(plugins) do
    slowest = math.max(slowest, load_ms(p) or 0)
  end
  local needed = dependents()
  local updating = with_updates(plugins, ctx)
  local by = {}
  for _, p in ipairs(plugins) do
    if not vim.list_contains(updating, p) then
      local key = M.section_of(p)
      by[key] = by[key] or {}
      table.insert(by[key], p)
    end
  end
  table.sort(by.loaded or {}, function(a, b)
    return (a.order or 0) < (b.order or 0)
  end)
  local sections = M.sections
  local ui = package.loaded['cinch.features.ui']
  local grouping = ctx.grouping and ui and ui.ext.groupings[ctx.grouping]
  if grouping then
    sections = regroup(by, grouping)
  end
  subheader(c, ctx, installing_now)
  if ctx.filter then
    c:add({ { ' / ' .. ctx.filter, 'CinchKey' }, { ('  %d of %d'):format(#plugins, #state.yours()), 'CinchMuted' } })
  end
  -- On disk and in no spec: no state, so only All lists them.
  local orphans = vim.tbl_filter(function(o)
    return not ctx.show and (not ctx.filter or o.name:lower():find(ctx.filter:lower(), 1, true) ~= nil)
  end, ctx.orphans or {})
  -- Plugins that are installing come first, so they are in view while they clone.
  local cloning = install_section(c, ctx, installing)
  if cloning and #updating + #orphans > 0 then
    c:add({})
  end
  -- A titled section's rows sit two cells in, and a blank row parts it from what follows.
  local gap = updates_section(c, updating, orphans, ctx) or cloning
  -- One list in section order. The filters above count the states, so only work under
  -- way, such as a build, keeps its title.
  for _, s in ipairs(sections) do
    local list = by[s.key] or {}
    local open = not (s.titled and ctx.folded[s.key])
    local titled = s.titled and #list > 0
    if gap and #list > 0 then
      c:add({})
      gap = false
    end
    if titled then
      local fold = open and ' ▾ ' or ' ▸ '
      local title = s.chunks and vim.list_extend({ { fold, 'CinchSection' } }, s.chunks)
        or { { fold .. s.title, 'CinchSection' }, { ' ' .. #list, 'CinchMuted' } }
      c:add(canvas.clip(title, c.width - 1), { section = s.key })
      gap = true
    end
    for _, p in ipairs(open and list or {}) do
      local m, m_hl = mark(p, ctx.tick)
      local msg, msg_hl, only_msg = message(p)
      if not asks(c, ctx, p.name, m, m_hl, titled) then
        add_row(c, p, {
          mark = m,
          mark_hl = m_hl,
          ms = load_ms(p),
          slowest = slowest,
          needed_by = needed[p.name] or {},
          up = pending(p),
          msg = msg,
          msg_hl = msg_hl,
          only_msg = only_msg,
          marked = ctx.marked and ctx.marked[p.name],
          indent = titled,
        })
      end
    end
  end
  if #plugins + #orphans + #updating + #installing == 0 then
    c:add({ { (' No %splugins'):format(ctx.show and ctx.show .. ' ' or ''), 'CinchMuted' } })
  end
  return c
end

return M
