-- The Triggers view: what each waiting plugin waits for. Every trigger (event, ft,
-- cmd, keys, and any of your own) with the plugins behind it, the ones still armed
-- first, then the ones done with, which fired or whose plugins loaded some other
-- way. Then the now and later queues, which are no triggers but load the rest, and
-- the plugins that load only with what needs them. Built from the plugin records
-- alone, so it shows triggers whose handlers are long gone.

local canvas = require('cinch.features.ui.canvas')
local plugins_view = require('cinch.features.ui.plugins')
local state = require('cinch.state')

local glyph = plugins_view.glyph

local M = {}

---@class cinch.ui.Trigger
---@field kind string event, ft, cmd, keys or your own
---@field value string as shown
---@field fired_as string the reason a plugin gets when it fires
---@field plugins cinch.Plugin[] in declaration order

-- Kinds in this order, then your own by name.
local kind_order = { event = 1, ft = 2, cmd = 3, keys = 4 }

---@param p cinch.Plugin
---@return number? ms since Neovim started, when it loaded
local function loaded_at(p)
  local stats = package.loaded['cinch.features.stats']
  local r = stats and stats.plugins[p.name]
  return r and r.at
end

---@param p cinch.Plugin
---@return boolean
local function waits(p)
  return p.state == 'pending' or p.state == 'registered'
end

--- Every trigger of every plugin that waits for one, each once.
---@return cinch.ui.Trigger[]
local function collect()
  local by, list = {}, {}
  for _, p in ipairs(state.yours()) do
    if p.when == 'trigger' and p.state ~= 'disabled' then
      for kind, values in pairs(p.triggers or {}) do
        for _, v in ipairs(values) do
          local raw = type(v) == 'table' and v.lhs or tostring(v)
          local id = kind .. ' ' .. raw
          local t = by[id]
          if not t then
            local shown = kind == 'ft' and raw:gsub('^FileType ', '') or raw
            local modes = type(v) == 'table' and v.modes or nil
            if modes and not (#modes == 1 and modes[1] == 'n') then
              shown = ('%s (%s)'):format(shown, table.concat(modes, ', '))
            end
            -- What the handler names as the reason when it fires: 'event FileType lua'.
            local fired_as = ((kind == 'event' or kind == 'ft') and 'event' or kind) .. ' ' .. raw
            t = { kind = kind, value = shown, fired_as = fired_as, plugins = {} }
            by[id], list[#list + 1] = t, t
          end
          table.insert(t.plugins, p)
        end
      end
    end
  end
  return list
end

---@param t cinch.ui.Trigger
---@return number? when it first fired, nil when it never did
local function fired(t)
  local first
  for _, p in ipairs(t.plugins) do
    if p.reason == t.fired_as and not waits(p) then
      local at = loaded_at(p) or math.huge
      first = math.min(first or math.huge, at)
    end
  end
  return first
end

---@param a cinch.ui.Trigger
---@param b cinch.ui.Trigger
---@return boolean
local function by_kind(a, b)
  local x, y = kind_order[a.kind] or 9, kind_order[b.kind] or 9
  if x ~= y then
    return x < y
  end
  return a.kind ~= b.kind and a.kind < b.kind or a.value < b.value
end

local marks =
  { loaded = { '●', 'CinchLoaded' }, failed = { '✗', 'CinchFailed' }, loading = { '●', 'CinchActive' } }

--- What happened to one plugin, next to its name.
---@param p cinch.Plugin
---@param fired_as? string the trigger the plugin is listed under
---@return string
local function outcome(p, fired_as)
  if waits(p) then
    return p.activity and (p.activity .. '…') or ''
  elseif p.state == 'failed' then
    return 'failed'
  end
  local at = loaded_at(p)
  local when = at and (' at ' .. canvas.ms(at)) or ''
  if p.reason == fired_as or p.reason == 'now' or p.reason == 'later' then
    return 'loaded' .. when
  end
  local by = ({ manual = 'by hand' })[p.reason] or p.reason or '?'
  return ('loaded %s%s'):format(by, when)
end

---@param c cinch.ui.Canvas
---@param p cinch.Plugin
---@param fired_as? string
---@param label? string after the name, such as `now_if_args`
local function plugin_row(c, p, fired_as, label)
  local mark = marks[p.state] or { '○', 'CinchWaiting' }
  c:add({
    { '     ' .. mark[1] .. ' ', mark[2] },
    { p.name, 'CinchName' },
    { label and (' ' .. label) or '', 'CinchIconNow' },
    { ' ' .. outcome(p, fired_as), p.state == 'failed' and 'CinchFailed' or 'CinchMuted' },
  }, { plugin = p.name })
end

---@param c cinch.ui.Canvas
---@param ctx cinch.ui.Ctx
---@param key string
---@param title string
---@param count integer
---@param note string
---@return boolean open
local function section(c, ctx, key, title, count, note)
  local open = not ctx.folded[key]
  c:add({
    { (open and ' ▾ ' or ' ▸ ') .. title, 'CinchSection' },
    { ' ' .. count, 'CinchMuted' },
    { '  ' .. note, 'CinchMuted' },
  }, { section = key })
  return open
end

---@param c cinch.ui.Canvas
---@param t cinch.ui.Trigger
---@param note string
---@param note_hl string
local function trigger_rows(c, t, note, note_hl)
  c:add({
    { '   ' .. glyph(t.kind) .. ' ' .. t.kind, 'CinchIconTrigger' },
    { ' ' .. t.value, 'CinchTriggerValue' },
    { '  ' .. note, note_hl },
  })
  for _, p in ipairs(t.plugins) do
    plugin_row(c, p, t.fired_as)
  end
end

--- The plugins of one queue, those still waiting first.
---@param when 'now'|'later'
---@return cinch.Plugin[]
local function queue(when)
  local list = vim.tbl_filter(function(p)
    return p.when == when and p.state ~= 'disabled'
  end, state.yours())
  table.sort(list, function(a, b)
    if waits(a) ~= waits(b) then
      return waits(a)
    end
    return (a.order or math.huge) < (b.order or math.huge)
  end)
  return list
end

--- The view, `width` cells wide.
---@param width integer
---@param ctx cinch.ui.Ctx
---@return cinch.ui.Canvas
function M.view(width, ctx)
  local c = canvas.new(width)
  local active, done = {}, {}
  for _, t in ipairs(collect()) do
    table.insert(vim.iter(t.plugins):any(waits) and active or done, t)
  end
  table.sort(active, by_kind)
  -- Fired ones in the order they fired, then the ones that never did.
  table.sort(done, function(a, b)
    local x, y = fired(a) or math.huge, fired(b) or math.huge
    if x ~= y then
      return x < y
    end
    return by_kind(a, b)
  end)

  if #active > 0 and section(c, ctx, 'triggers:active', 'armed', #active, 'waiting to fire') then
    for _, t in ipairs(active) do
      local n = #vim.tbl_filter(waits, t.plugins)
      trigger_rows(c, t, ('%d waiting'):format(n), 'CinchWaiting')
    end
  end
  if #done > 0 and section(c, ctx, 'triggers:done', 'done', #done, 'nothing waits on them any more') then
    for _, t in ipairs(done) do
      local at = fired(t)
      local note = at and ('fired' .. (at < math.huge and (' at ' .. canvas.ms(at)) or '')) or 'never fired'
      trigger_rows(c, t, note, at and 'CinchLoaded' or 'CinchMuted')
    end
  end
  if #active + #done == 0 then
    c:add({ { ' no plugin waits for a trigger', 'CinchMuted' } })
  end

  -- The queues. now_if_args is no queue: it became now or later when the spec was read.
  for _, q in ipairs({
    { 'now', 'loads during startup, in order' },
    { 'later', 'loads once the UI is up, a few at a time' },
  }) do
    local list = queue(q[1])
    if #list > 0 then
      c:blank()
      if section(c, ctx, 'triggers:' .. q[1], glyph(q[1]) .. ' ' .. q[1], #list, q[2]) then
        for _, p in ipairs(list) do
          plugin_row(c, p, nil, p.load == 'now_if_args' and 'now_if_args' or nil)
        end
      end
    end
  end

  local deps = vim.tbl_filter(function(p)
    return p.dep_only and p.state ~= 'disabled'
  end, state.yours())
  if #deps > 0 then
    c:blank()
    if section(c, ctx, 'triggers:deps', glyph('dep') .. ' dependencies', #deps, 'load before what needs them') then
      for _, p in ipairs(deps) do
        plugin_row(c, p)
      end
    end
  end
  return c
end

return M
