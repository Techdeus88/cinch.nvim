-- cinch-groups on cinch's runner: copy this into cinch's tests/cases with cinch carrying
-- doc/core-seams.patch, and set CINCH_GROUPS_ROOT to this repo. Ported from the groups branch.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
vim.opt.rtp:prepend(assert(vim.env.CINCH_GROUPS_ROOT))

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
-- No `group`: the file's name names it. `order` puts it before the rest, aaa_late after.
H.write('lua/plugins/editor.lua', {
  "return { event = 'InsertEnter', order = 10, { 'owner/pairs' }, 'owner/surround' }",
})
H.write('lua/plugins/solo.lua', { "return { 'owner/solo', cmd = 'Solo' }" })
H.write('lua/plugins/aaa_late.lua', { "return { order = 150, { 'owner/late1' } }" })
H.write('lua/plugins/badorder.lua', { "return { order = 'x', { 'owner/bo' } }" })
H.write('lua/plugins/byname/x.lua', { "return { 'owner/named' }" })
-- One spec naming a group nothing else defines: that group, made for it, not `solo2`.
H.write('lua/plugins/solo2.lua', { "return { 'owner/solo2', group = 'tools' }" })
-- Plugins seen only as dependencies, and one that is also a plugin of its own.
H.write('lua/plugins/deps.lua', {
  'return {',
  "  { 'owner/p1', deps = { { 'owner/ownd', group = 'git' }, { 'owner/nod', group = false }, 'owner/lsdep' } },",
  "  { 'owner/p2', deps = { 'owner/both', { 'owner/deep', deps = { 'owner/deeper' } } } },",
  "  { 'owner/both' },",
  '}',
})
H.write('lua/plugins/zz.lua', {
  'return {',
  "  { 'owner/cmp', cmd = 'Cmp' },",
  "  { group = 'cmds', { 'owner/signs' } },",
  "  { 'owner/line' },",
  "  { 'owner/tabs' },",
  '}',
})

-- Nothing under lua/plugins/ installs: the files are only read, by a second collect below.
-- One bootstrap line: cinch-groups sets cinch up, with `groups` as the extension's options.
require('cinch-groups').setup({
  confirm = false,
  features = { 'messages' },
  groups = {
    real = { cmd = 'AlphaCmd' },
    alt = { load = 'later', plugins = { 'line', 'lsdep' } },
    byname = { cmd = 'ByName', dir = true },
    ins = { ft = 'markdown' },
    lsp = { ft = { 'lua' }, dir = 'lsp', other = true },
    ui = { event = 'UIEnter', plugins = { 'line', 'tabs', 'signs' } },
  },
  spec = { { { H.src('alpha.nvim'), group = 'real' } } },
})

H.after_startup(function()
  local groups = require('cinch-groups')
  local alpha = H.plugin('alpha.nvim')
  H.eq({ groups.of('alpha.nvim'), alpha.load, alpha.state }, { 'real', 'trigger', 'pending' }, 'waits for its command')
  H.eq(H.noted('unknown field `group`'), false, 'cinch knows the group field')
  H.eq(require('cinch').extensions.groups, groups, 'it is the groups extension')
  vim.cmd('AlphaCmd')
  H.eq(alpha.state, 'loaded', 'which loads it')

  local spec, state = require('cinch.spec'), require('cinch.state')
  spec.register(
    spec.collect({ 'plugins', { { group = 'inline', keys = '<leader>i', { 'owner/ina' } }, { 'owner/loose' } } }, {
      file = 'init.lua',
    })
  )
  ---@return any[] # group, load, and the fields asked for
  local function of(name, ...)
    local p = state.plugins[name]
    local out = { groups.of(name) or false, p.load }
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
  H.eq(of('wrapdep'), { 'dependencies', 'trigger' }, 'a nested dependency is in dependencies, not its parent group')

  H.eq(of('cmp', 'event', 'ft', 'cmd'), { 'ins', 'trigger', 'InsertEnter', 'markdown', 'Cmp' }, 'setup and file merge')
  H.eq(of('snip', 'event', 'cmd'), { 'ins', 'trigger', 'InsertEnter', 'Snip' }, "its own trigger beside the group's")
  H.eq(of('ownevent', 'event'), { 'ins', 'trigger', 'BufRead' }, "its own value over the group's")
  H.eq(of('noevent', 'event', 'ft'), { 'ins', 'trigger', false, 'markdown' }, 'false drops one trigger of the group')
  H.eq(of('nowins', 'event', 'ft'), { 'ins', 'now', 'nil', 'nil' }, "its own load takes none of the group's triggers")
  H.eq(H.noted('`nowins`'), false, 'and nothing warns')
  H.eq(of('two', 'cmd'), { 'cmds', 'trigger', 'Two' }, 'a file can hold several groups')
  H.eq(of('plain'), { 'many', 'later' }, "and plain specs beside them, in the file's group")
  H.eq(of('bl'), { 'badload', 'later' }, 'an unknown load of a group is ignored')
  H.eq(H.noted('group `badload` has unknown load `soon`'), true, 'with a warning')
  H.eq(of('ina', 'keys'), { 'inline', 'trigger', '<leader>i' }, 'a group table works in inline specs')

  H.eq(of('lspconfig', 'ft'), { 'lsp', 'trigger', { 'lua' } }, "a spec file under a group's dir is in it")
  H.eq(H.noted('setup%(%): group `lsp` has unknown field `other`'), true, 'setup groups are checked too')
  H.eq(of('named', 'cmd'), { 'byname', 'trigger', 'ByName' }, "dir = true is the group's own name")
  H.eq(of('fielded', 'event'), { 'ui', 'trigger', 'UIEnter' }, "a spec's group field beats the folder")
  H.eq(of('opted', 'ft'), { 'lsp', 'trigger', { 'lua' } }, 'group = false is no way out: its folder has it')
  H.eq(H.noted('`opted` has group `false`, not a name; it is ignored'), true, 'with a warning')
  H.eq(of('ghost')[1], 'nope', 'naming a group nothing defines makes it')
  H.eq(H.noted('`ghost`'), false, 'without a warning')
  H.eq(of('dirdep'), { 'dependencies', 'trigger' }, "a nested dependency is not in its file's group")

  H.eq(of('tabs', 'event'), { 'ui', 'trigger', 'UIEnter' }, 'a plugin listed by a setup group is in it')
  H.eq(of('line'), { 'alt', 'later' }, 'listed twice, the first group by name has it')
  H.eq(H.noted('`line` is listed in groups `alt` and `ui`; using `alt`'), true, 'and it warns')
  H.eq(of('signs')[1], 'git', 'the group table that wraps a spec beats a list')
  H.eq(H.noted('zz.lua: `signs` is already in group `git`; `cmds` is ignored'), true, 'and a second wrapper warns')

  H.eq(groups.members('cmds'), { 'two' }, 'members() lists a group by registration order')

  local reg = require('cinch-groups.registry')
  H.eq(of('solo2')[1], 'tools', 'a single spec in a file is in the group it names')
  H.eq(reg.groups.solo2, nil, 'and no group is made after its file')
  H.eq(of('ownd'), { 'git', 'now' }, 'a dependency naming a group is in it, and takes its load')
  H.eq(of('nod'), { 'dependencies', 'trigger' }, 'nor for a dependency')
  H.eq(of('lsdep'), { 'alt', 'later' }, 'a setup() group listing a dependency has it')
  H.eq({ of('deep')[1], of('deeper')[1] }, { 'dependencies', 'dependencies' }, 'at any depth')
  H.eq(of('both')[1], 'deps', 'a dependency with a spec of its own is a plugin, in its file group')
  H.eq(require('cinch.state').plugins.deep.dep_only, true, 'dependencies stay dependencies to cinch')

  H.eq(of('pairs', 'event'), { 'editor', 'trigger', 'InsertEnter' }, "a file's table with no group is named after it")
  H.eq(of('surround', 'event'), { 'editor', 'trigger', 'InsertEnter' }, 'a string spec in it too')
  H.eq(of('solo', 'cmd'), { 'solo', 'trigger', 'Solo' }, 'a file holding one spec is a group of one')
  H.eq(of('loose'), { 'init', 'later' }, 'an inline spec is in the group of the file it is written in')
  H.eq(of('bo'), { 'badorder', 'later' }, 'an order that is not a number is ignored')
  H.eq(H.noted('group `badorder` has order `x`, not a number'), true, 'with a warning')
  local at = {}
  for i, p in ipairs(state.list) do
    at[p.name] = i
  end
  H.eq(at.pairs < at.plain and at.plain < at.late1, true, 'lower order registers, so loads, first')
  H.eq(at.surround < at.plain, true, 'the whole group moves')
end)
