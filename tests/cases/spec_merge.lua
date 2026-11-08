-- spec.lua: specs of one name merge, later fields winning. Nested tables merge, lists
-- and functions are replaced, and the load is worked out from the merged spec.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

H.write('lua/plugins/a.lua', {
  'return {',
  "  { 'owner/filed', cmd = 'FromA', opts = { a = 1, nested = { x = 1, y = 1 } } },",
  "  { 'owner/filed', opts = { nested = { y = 2 } } },",
  '}',
})
H.write('lua/plugins/b.lua', { "return { 'owner/filed', opts = { b = 2, nested = { y = 3, z = 3 } } }" })

local spec, state = require('cinch.spec'), require('cinch.state')
local function reg(list)
  return spec.register(spec.collect({ list }, { file = 'init.lua' }))
end
local function plugin(name)
  return state.plugins[name]
end

local from_files = spec.register(spec.collect({ 'plugins' }, { file = 'init.lua' }))

local function first() end
local function second() end
local range = vim.version.range('^1.2')
local mine = { 'owner/mine', opts = { kept = { 1 } } }
local mine_again = { 'owner/mine', opts = { kept = { 2 }, more = true } }
reg({
  { 'owner/lists', keys = { 'a', 'b' }, cmd = { 'One', 'Two' }, deps = { 'owner/dep-one' } },
  { 'owner/lists', keys = { 'c' }, deps = { 'owner/dep-two' } },
  { 'owner/hooks', config = first, init = first },
  { 'owner/hooks', config = second },
  { 'owner/off', keys = { 'a' } },
  { 'owner/off', keys = false },
  { 'owner/ranged', version = range },
  { 'owner/ranged', opts = {} },
  { 'owner/pinned', commit = 'abc' },
  { 'owner/pinned', branch = 'dev' },
  { 'owner/moved', cmd = 'Moved' },
  { src = 'https://example.com/fork/moved' },
  { 'owner/deadline', event = { 'VeryLazy', 'BufReadPre' } },
  { 'owner/deadline', opts = {} },
  { 'owner/settled', load = 'now', cmd = 'Settled' },
  { 'owner/settled', load = 'trigger' },
  { 'owner/warned', cmd = 'Warned', bogus = 1 },
  { 'owner/warned', load = 'now', other = 2 },
  { 'owner/depends', deps = { 'kept-dep' } },
  { 'owner/depends', opts = {} },
  { 'owner/kept-dep' },
  mine,
  mine_again,
  -- A dependency also declared on its own, in both orders.
  { 'owner/needs-lib', deps = { { 'owner/lib', opts = { a = 1, b = 1 } } } },
  { 'owner/lib', opts = { b = 2 } },
  { 'owner/lib2', opts = { b = 1 } },
  { 'owner/needs-lib2', deps = { { 'owner/lib2', opts = { b = 2 } } } },
  { 'owner/only-dep-user', deps = { { 'owner/only-dep', opts = { a = 1 } } } },
  { 'owner/other-dep-user', deps = { { 'owner/only-dep', opts = { b = 2 } } } },
  -- Only naming a dependency leaves the fork in place.
  { src = 'https://example.com/fork/forked', opts = { a = 1 } },
  { 'owner/fork-user', deps = { 'owner/forked' } },
  { 'owner/fork-user-table', deps = { { 'owner/forked' } } },
})

H.after_startup(function()
  H.eq(#from_files, 1, 'one record for three specs')
  H.eq(
    plugin('filed').data.opts,
    { a = 1, b = 2, nested = { x = 1, y = 3, z = 3 } },
    'nested opts merge, across files and in order'
  )
  H.eq(plugin('filed').data.cmd, 'FromA', 'a field only one spec sets stays')
  H.eq(plugin('filed').origin.file:find('b.lua', 1, true) ~= nil, true, 'origin is the last spec')

  H.eq(plugin('lists').data.keys, { 'c' }, 'a later list replaces')
  H.eq(plugin('lists').data.cmd, { 'One', 'Two' }, 'a list set once stays')
  H.eq(plugin('lists').deps, { 'dep-one', 'dep-two' }, 'deps add up')
  H.eq({ plugin('hooks').data.config, plugin('hooks').data.init }, { second, first }, 'functions: the later one')
  H.eq({ plugin('off').data.keys, plugin('off').load }, { false, 'later' }, 'keys = false turns earlier keys off')

  H.eq(getmetatable(plugin('ranged').version) ~= nil, true, 'a version range stays an object')
  H.eq(plugin('pinned').version, 'dev', 'the later pin wins')
  H.eq(
    { plugin('moved').src, plugin('moved').data.cmd },
    { 'https://example.com/fork/moved', 'Moved' },
    'a later src replaces'
  )

  H.eq(
    { plugin('deadline').very_lazy, plugin('deadline').data.event },
    { true, { 'BufReadPre' } },
    'VeryLazy survives a merge'
  )
  H.eq(plugin('settled').load, 'trigger', 'the load comes from the merged spec')
  H.eq(H.noted('`settled` sets load'), false, 'and a warning that no longer holds is not given')
  H.eq(plugin('warned').load, 'now', 'an explicit load from a later spec')
  H.eq(H.noted('`warned` sets load = `now`'), true, 'warns about triggers from an earlier one')
  H.eq(H.noted('`warned` has unknown field `bogus`'), true, 'every spec is checked for unknown fields')
  H.eq(H.noted('`warned` has unknown field `other`'), true, 'the later one too')
  H.eq(plugin('depends').deps, { 'kept-dep' }, 'a spec without deps keeps them, and refs still resolve')

  H.eq(plugin('mine').data.opts, { kept = { 2 }, more = true }, 'merged')
  H.eq(mine, { 'owner/mine', opts = { kept = { 1 } } }, 'your own tables are left as you wrote them')
  H.eq(mine_again, { 'owner/mine', opts = { kept = { 2 }, more = true } }, 'both of them')

  H.eq(plugin('lib').data.opts, { a = 1, b = 1 }, 'a nested spec beats the own spec read after it')
  H.eq(plugin('lib').dep_only, nil, 'is not only a dependency')
  H.eq(plugin('lib').load, 'later', 'so it loads as its own')
  H.eq(plugin('lib2').data.opts, { b = 2 }, 'and the one read before it')
  H.eq(plugin('lib2').dep_only, nil, 'is not only a dependency either')
  H.eq(plugin('only-dep').data.opts, { a = 1, b = 2 }, 'two dependents merge')
  H.eq({ plugin('only-dep').dep_only, plugin('only-dep').load }, { true, 'trigger' }, 'and it stays a dependency')
  H.eq(plugin('forked').src, 'https://example.com/fork/forked', 'naming a dependency leaves src alone')
  H.eq(plugin('fork-user').deps, { 'forked' }, 'and still depends on it')
  H.eq(plugin('fork-user-table').deps, { 'forked' }, 'in a table of its own too')
  H.eq(H.noted('declared twice'), false, 'nothing warns about a second spec')
end)
