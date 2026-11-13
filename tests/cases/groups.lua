-- spec.lua groups: a load strategy plugins share. A group is the table that wraps its
-- specs in a spec file, or an entry of `groups` in setup(), which can also list its
-- plugins or name their folder. A plugin's own fields go over its group's, one by one.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

H.write('lua/plugins/git.lua', {
  'return {',
  "  group = 'git',",
  "  load = 'later',",
  "  { 'owner/signs' },",
  "  { 'owner/diff', cmd = 'Diff' },",
  "  { 'owner/withdep', deps = { { 'owner/wrapdep' } } },",
  '}',
})
-- Read after git.lua: the same group, so its fields go over that one's.
H.write('lua/plugins/git2.lua', { "return { group = 'git', load = 'now', bogus = 1, { 'owner/blame' } }" })
H.write('lua/plugins/many.lua', {
  'return {',
  "  { group = 'ins', event = 'InsertEnter',",
  "    { 'owner/cmp' },",
  "    { 'owner/snip', cmd = 'Snip' },",
  "    { 'owner/ownevent', event = 'BufRead' },",
  "    { 'owner/noevent', event = false },",
  "    { 'owner/nowins', load = 'now' },",
  '  },',
  "  { group = 'cmds', cmd = 'Two', { 'owner/two' } },",
  "  { group = 'badload', load = 'soon', { 'owner/bl' } },",
  "  { 'owner/plain' },",
  '}',
})
H.write('lua/plugins/lsp/servers.lua', {
  'return {',
  "  { 'owner/lspconfig' },",
  "  { 'owner/fielded', group = 'ui' },",
  "  { 'owner/opted', group = false },",
  "  { 'owner/ghost', group = 'nope' },",
  "  { 'owner/dirparent', deps = { { 'owner/dirdep' } } },",
  '}',
})
H.write('lua/plugins/byname/x.lua', { "return { 'owner/named' }" })
H.write('lua/plugins/zz.lua', {
  'return {',
  "  { 'owner/cmp', cmd = 'Cmp' },",
  "  { group = 'cmds', { 'owner/signs' } },",
  "  { 'owner/line' },",
  "  { 'owner/tabs' },",
  '}',
})

require('cinch').setup({
  confirm = false,
  groups = { real = { cmd = 'AlphaCmd' } },
  spec = { { { H.src('alpha.nvim'), group = 'real' } } },
})

H.after_startup(function()
  local alpha = H.plugin('alpha.nvim')
  H.eq({ alpha.group, alpha.load, alpha.state }, { 'real', 'trigger', 'pending' }, "it waits for its group's command")
  vim.cmd('AlphaCmd')
  H.eq(alpha.state, 'loaded', 'which loads it')

  local spec, state = require('cinch.spec'), require('cinch.state')
  spec.set_groups({
    alt = { load = 'later', plugins = { 'line' } },
    byname = { cmd = 'ByName', dir = true },
    ins = { ft = 'markdown' },
    lsp = { ft = { 'lua' }, dir = 'lsp', other = true },
    ui = { event = 'UIEnter', plugins = { 'line', 'tabs', 'signs' } },
  }, { file = 'init.lua' })
  spec.register(spec.collect({ 'plugins', { { group = 'inline', keys = '<leader>i', { 'owner/ina' } } } }, {
    file = 'init.lua',
  }))
  ---@return any[] group, load, and the fields asked for
  local function of(name, ...)
    local p = state.plugins[name]
    local out = { p.group or false, p.load }
    for _, k in ipairs({ ... }) do
      local v = p.data[k]
      out[#out + 1] = v == nil and 'nil' or v
    end
    return out
  end

  H.eq(of('blame'), { 'git', 'now' }, 'a spec in a group table takes its load')
  H.eq(of('signs'), { 'git', 'now' }, 'a group defined in two files is one: the later load wins')
  H.eq(H.noted('git2.lua: group `git` has unknown field `bogus`'), true, 'an unknown field of a group warns')
  H.eq(of('diff', 'cmd'), { 'git', 'now', 'Diff' }, "a group's load is explicit: it wins over a trigger")
  H.eq(H.noted('`diff` is in group `git` with load = `now`, so its triggers are ignored'), true, 'and says so')
  H.eq(of('wrapdep'), { false, 'trigger' }, 'a nested dependency is not in the group that wraps its parent')

  H.eq(of('cmp', 'event', 'ft', 'cmd'), { 'ins', 'trigger', 'InsertEnter', 'markdown', 'Cmp' }, 'setup and file merge')
  H.eq(of('snip', 'event', 'cmd'), { 'ins', 'trigger', 'InsertEnter', 'Snip' }, "its own trigger beside the group's")
  H.eq(of('ownevent', 'event'), { 'ins', 'trigger', 'BufRead' }, "its own value over the group's")
  H.eq(of('noevent', 'event', 'ft'), { 'ins', 'trigger', false, 'markdown' }, 'false drops one trigger of the group')
  H.eq(of('nowins', 'event', 'ft'), { 'ins', 'now', 'nil', 'nil' }, "its own load takes none of the group's triggers")
  H.eq(H.noted('`nowins`'), false, 'and nothing warns')
  H.eq(of('two', 'cmd'), { 'cmds', 'trigger', 'Two' }, 'a file can hold several groups')
  H.eq(of('plain'), { false, 'later' }, 'and plain specs beside them')
  H.eq(of('bl'), { 'badload', 'later' }, 'an unknown load of a group is ignored')
  H.eq(H.noted('group `badload` has unknown load `soon`'), true, 'with a warning')
  H.eq(of('ina', 'keys'), { 'inline', 'trigger', '<leader>i' }, 'a group table works in inline specs')

  H.eq(of('lspconfig', 'ft'), { 'lsp', 'trigger', { 'lua' } }, "a spec file under a group's dir is in it")
  H.eq(H.noted('init.lua: group `lsp` has unknown field `other`'), true, 'setup groups are checked too')
  H.eq(of('named', 'cmd'), { 'byname', 'trigger', 'ByName' }, "dir = true is the group's own name")
  H.eq(of('fielded', 'event'), { 'ui', 'trigger', 'UIEnter' }, "a spec's group field beats the folder")
  H.eq(of('opted'), { false, 'later' }, 'group = false leaves it')
  H.eq(of('ghost')[1], 'lsp', 'a group nothing defines is ignored')
  H.eq(H.noted('`ghost` names group `nope`, which nothing defines'), true, 'with a warning')
  H.eq(of('dirdep'), { false, 'trigger' }, "a nested dependency is not in its file's group")

  H.eq(of('tabs', 'event'), { 'ui', 'trigger', 'UIEnter' }, 'a plugin listed by a setup group is in it')
  H.eq(of('line'), { 'alt', 'later' }, 'listed twice, the first group by name has it')
  H.eq(H.noted('`line` is listed in groups `alt` and `ui`; using `alt`'), true, 'and it warns')
  H.eq(of('signs')[1], 'git', 'the group table that wraps a spec beats a list')
  H.eq(H.noted('zz.lua: `signs` is already in group `git`; `cmds` is ignored'), true, 'and a second wrapper warns')
end)
