-- spec.lua: discovery from lua/plugins/**, top-level fields moved into data, pins,
-- warnings, how `load` is worked out, dependencies and name references.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

H.write('lua/plugins/a.lua', {
  'return {',
  "  { 'owner/tele.nvim', cmd = 'Tele', opts = { a = 1 }, data = { opts = { a = 2 } },",
  "    deps = { 'owner/plenary.nvim', 'icons' } },",
  "  { 'owner/which.nvim', event = 'VeryLazy', commit = 'abc1234', tag = 'v1', bogus = 1, lazy = false },",
  "  { 'owner/now-cmd', load = 'now', cmd = 'Foo' },",
  "  { 'owner/odd', load = 'sometimes' },",
  "  { 'owner/needs', deps = { 'ghost.nvim' } },",
  "  { 'owner/args', load = 'now_if_args' },",
  "  { src = 'https://example.com/x/repo.git' },",
  '}',
})
H.write('lua/plugins/sub/b.lua', { "return { 'owner/icons-repo', name = 'icons', branch = 'dev' }" })
H.write('lua/plugins/c.lua', { "return { 'owner/which.nvim' }" })
H.write('lua/plugins/d.lua', { "error('broken file')" })
H.write('lua/plugins/e.lua', {
  'return {',
  "  { 'owner/ranged', version = '^1.2' },",
  "  { 'owner/starred', tag = '1.*' },",
  "  { 'owner/branchy', version = 'feat/x-1.0' },",
  "  { 'owner/real-range', version = vim.version.range('^1.2') },",
  '}',
})

local spec, state = require('cinch.spec'), require('cinch.state')
local added = spec.register(spec.collect({ 'plugins' }, { file = 'init.lua' }))

H.after_startup(function()
  local names = vim.tbl_map(function(p)
    return p.name
  end, added)
  H.eq(names, {
    'plenary.nvim',
    'tele.nvim',
    'which.nvim',
    'now-cmd',
    'odd',
    'needs',
    'args',
    'repo',
    'ranged',
    'starred',
    'branchy',
    'real-range',
    'icons',
  }, 'deps first')

  local t = state.plugins['tele.nvim']
  H.eq(t.src, 'https://github.com/owner/tele.nvim', 'owner/repo expands')
  H.eq(t.data.cmd, 'Tele', 'top-level field moved into data')
  H.eq(t.spec['cmd'], nil, 'and removed from the top level')
  H.eq(t.data.opts, { a = 2 }, 'data wins over the top level')
  H.eq(t.load, 'trigger', 'a trigger means load = trigger')
  H.eq(t.deps, { 'plenary.nvim', 'icons' }, 'deps: a spec and a name reference')

  H.eq(state.plugins['plenary.nvim'].load, 'trigger', 'only a dependency: loads with its dependent')
  H.eq(state.plugins['plenary.nvim'].dep_only, true, 'marked as such')

  local w = state.plugins['which.nvim']
  H.eq(w.load, 'later', 'VeryLazy means later')
  H.eq(w.version, 'abc1234', 'commit beats tag')
  H.eq(H.noted('sets `commit` and `tag`; using `commit`'), true, 'the losing pin warns')
  H.eq(H.noted('unknown field `bogus`'), true, 'unknown fields warn')
  H.eq(H.noted('unknown field `lazy`'), true, 'lazy is not a field')
  H.eq(H.noted('`which.nvim` declared twice'), true, 'a second spec of a name warns')

  H.eq(state.plugins['now-cmd'].load, 'now', 'an explicit load wins')
  H.eq(H.noted('load = `now`, so its triggers are ignored'), true, 'and says its triggers are ignored')
  H.eq(state.plugins['odd'].load, 'later', 'an unknown load falls back to the default')
  H.eq(H.noted('unknown load `sometimes`'), true, 'and warns')
  H.eq(state.plugins['needs'].deps, {}, 'a reference no spec declares is dropped')
  H.eq(H.noted('depends on `ghost.nvim`, which no spec declares'), true, 'with a warning')
  H.eq(state.plugins['args'].when, 'later', 'now_if_args without file arguments is later')
  H.eq(state.plugins['repo'] ~= nil, true, 'the name drops .git like vim.pack')
  H.eq(state.plugins['icons'].version, 'dev', 'branch becomes version')
  H.eq(H.noted('broken file'), true, 'a broken spec file is reported')

  local looks = 'version `%s` looks like a range, which vim.pack reads as a branch or tag; write vim.version.range'
  H.eq(H.noted(vim.pesc(looks:format('^1.2'))), true, 'a range written as a string warns')
  H.eq(H.noted(vim.pesc(looks:format('1.*'))), true, 'from a tag too')
  H.eq(state.plugins['ranged'].version, '^1.2', 'and goes to vim.pack unchanged')
  H.eq(H.noted('`feat/x%-1%.0` looks like'), false, 'a branch name does not warn')
  H.eq(H.noted('`real%-range`'), false, 'a real range does not warn')
  H.eq(getmetatable(state.plugins['real-range'].version) ~= nil, true, 'and stays a range object')
end)
