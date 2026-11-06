-- cinch.time(): a wrapped function passes arguments, results and errors through
-- unchanged, and each call is totalled under its name for the Profile view.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

local add = cinch.time('add', function(a, b)
  return a + b, nil, 'third'
end)
local boom = cinch.time('boom', function()
  error({ code = 7 })
end)
local obj = { n = 2 }
function obj:double()
  return self.n * 2
end
obj.double = cinch.time('obj:double', obj.double)

-- Before setup() nothing listens: the wrapper only calls the function.
H.eq(add(1, 1), 2, 'works before setup')

cinch.setup({ confirm = false, spec = {} })

local seen = {}
cinch.on('Time', function(d)
  seen[#seen + 1] = d
end)

H.after_startup(function()
  local r = { add(2, 3) }
  H.eq(r[1], 5, 'the result')
  H.eq(select('#', add(2, 3)), 3, 'every result, a nil in the middle too')
  H.eq(r[3], 'third', 'the last result')
  H.eq(obj:double(), 4, 'a method gets its self')
  local ok, err = pcall(boom)
  H.eq(ok, false, 'an error still raises')
  H.eq(err, { code = 7 }, 'the same error value')

  H.eq(#seen, 4, 'the Time event, once a call')
  H.eq(seen[1].name, 'add', 'with its name')
  H.eq(type(seen[1].start) == 'number' and seen[1].ms >= 0, true, 'its start and how long it took')
  H.eq(seen[4].ok, false, 'and whether it raised')

  local stats = require('cinch.features.stats')
  H.eq(stats.timed.add.calls, 2, 'calls before setup are not counted')
  H.eq(stats.timed.boom.failed, 1, 'failures counted')

  local group
  for _, n in ipairs(stats.profile()) do
    if n.name == 'timed' then
      group = n
    end
  end
  H.eq(group ~= nil, true, 'a timed group in the profile')
  ---@cast group cinch.stats.Node
  H.eq(
    vim.tbl_map(function(n)
      return n.name
    end, group.children),
    { 'add', 'obj:double', 'boom' },
    'one entry per name, in the order each first ran'
  )
  H.eq(group.children[1].calls, 2, 'with its call count')

  local ui = require('cinch.features.ui')
  ui.open('profile')
  local w = ui.windows()
  local lines = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w.list), 0, -1, false), '\n')
  H.eq(lines:find('add  2 calls · slowest', 1, true) ~= nil, true, 'drawn with its calls and slowest call')
  H.eq(lines:find('boom  1 call · slowest [^\n]* · failed') ~= nil, true, 'and a failure noted')
end)
