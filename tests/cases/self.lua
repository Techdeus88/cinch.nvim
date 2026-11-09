-- phases: 4
-- cinch as one of its own plugins: adopted from its folder in vim.pack's directory,
-- where the install clones it, loaded without running its files again, updated like
-- any other plugin, and never deleted. Phase 2 lists cinch in your own specs, with
-- the default `later`, so it loads after startup. Phase 3 pins it with `self`, and
-- phase 4 turns it off: then cinch is no plugin, and a clean still leaves it alone.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch, pack = require('cinch'), require('cinch.pack')

-- Where cinch comes from, and its clone in vim.pack's folder, as the install makes it.
local origin = vim.fs.joinpath(H.home, 'cinch-origin')
local dir = vim.fs.joinpath(pack.dir, 'cinch.nvim')
if H.phase == 1 then
  H.write(vim.fs.joinpath(origin, 'plugin', 'cinch-self.lua'), {
    'vim.g.self_sourced = (vim.g.self_sourced or 0) + 1',
  })
  H.sh({ 'git', 'init', '-q', '-b', 'main' }, origin)
  H.sh({ 'git', 'add', '-A' }, origin)
  H.commit(origin, 'init')
  H.sh({ 'git', 'tag', 'v1' }, origin)
  H.sh({ 'git', 'clone', '-q', 'file://' .. origin, dir })
end
vim.opt.rtp:prepend(dir)
cinch.own_dir = dir

local specs = { { H.src('alpha.nvim') } }
if H.phase == 2 then
  specs[#specs + 1] = { 'file://' .. origin, name = 'cinch.nvim' }
end
local self_opt = ({ true, true, { tag = 'v1' }, false })[H.phase]
cinch.setup({ confirm = false, self = self_opt, spec = { specs } })

H.after_startup(function()
  if H.phase == 4 then
    H.eq(require('cinch.state').plugins['cinch.nvim'], nil, '`self = false`: not one of its plugins')
    local orphans = vim.tbl_map(function(o)
      return o.name
    end, pack.orphans())
    H.eq(vim.list_contains(orphans, 'cinch.nvim'), false, 'and never a plugin to clean')
    return
  end
  local p = H.plugin('cinch.nvim')
  if H.phase == 3 then
    H.eq({ p.self, p.version, vim.pack.get({ 'cinch.nvim' })[1].spec.version }, { true, 'v1', 'v1' }, '`self` pins it')
    return
  end
  H.eq(
    { p.self, p.src, p.state },
    { true, 'file://' .. origin, 'loaded' },
    'cinch is one of its plugins, from its origin'
  )
  H.eq(vim.g.self_sourced, 1, 'loading it did not run its files again')
  if H.phase == 2 then
    H.eq(p.load, 'later', 'your own spec of it is used as written')
    return
  end
  H.eq(vim.pack.get({ 'cinch.nvim' })[1].active, true, 'vim.pack manages it')

  -- cinch is none of your plugins: no row, no count.
  local view = require('cinch.features.ui.plugins')
  local ctx = { folded = {}, tick = 0, info = {}, spec_lines = {} }
  local function list()
    return table.concat(view.list(100, ctx).lines, '\n')
  end
  H.eq(list():find('cinch', 1, true), nil, 'no row in the Plugins view')
  H.eq(require('cinch.features.stats').summary().plugins.total, 1, 'and not counted')
  H.eq(require('cinch.state').yours()[1].name, 'alpha.nvim', 'only your plugins')

  local before = pack.rev(p)
  H.commit(origin, 'feat: newer cinch')
  local u = require('cinch.features.updates')
  u.check()
  H.wait(function()
    return not u.checking
  end, 'the check')
  H.eq(#(u.results['cinch.nvim'] or { commits = {} }).commits, 1, 'its new commit shows as an update')
  H.eq(list():find('Updates (1)', 1, true) ~= nil, true, 'its update has a row in the Updates section')
  H.eq(list():find('cinch.nvim 1 commit', 1, true) ~= nil, true, 'with how far behind it is')
  u.apply({ 'cinch.nvim' })
  H.eq(list():find('cinch', 1, true), nil, 'gone once applied')
  H.eq(pack.rev(p) ~= before, true, 'and applies')
  H.eq(H.noted('Updated 1 of 1 plugin in [%d.]+m?s · restart to use them'), true, 'with a restart notice')

  vim.cmd('Cinch del! cinch.nvim')
  H.eq(vim.uv.fs_stat(dir) ~= nil, true, 'it never deletes itself')
  H.eq(H.noted('`cinch.nvim` is cinch itself'), true, 'and says why')
end)
