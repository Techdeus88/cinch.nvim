-- pack.lua: PackPre and Pack come after cinch's state is updated, every vim.pack
-- call is announced, nothing calls vim.pack before cinch's add, rev and delete.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local events, pack = require('cinch.events'), require('cinch.pack')

local before_ok, before_err = pack.get()
local log = {}
events.on('PackPre', function(d)
  log[#log + 1] = ('pre %s %s %s'):format(d.kind, d.name, tostring(d.plugin and d.plugin.activity))
end)
events.on('Pack', function(d)
  local p = d.plugin
  log[#log + 1] = ('pack %s %s %s %s'):format(d.kind, d.name, tostring(p and p.activity), tostring(p and p.path ~= nil))
end)
events.on('PackOpPre', function(d)
  log[#log + 1] = 'op ' .. d.op
end)
events.on('PackOp', function(d)
  log[#log + 1] = ('done %s %s'):format(d.op, tostring(d.ok))
end)

require('cinch').setup({
  confirm = false,
  spec = { { { H.src('alpha.nvim'), cmd = 'AlphaCmd', opts = { style = 'night' } }, { H.src('beta.nvim') } } },
})

H.after_startup(function()
  H.eq(
    { before_ok, tostring(before_err):find('not set up yet') ~= nil },
    { false, true },
    'no vim.pack call before cinch adds'
  )
  H.eq(log, {
    'op add',
    'pre install alpha.nvim installing',
    'pre install beta.nvim installing',
    'pack install alpha.nvim nil true',
    'pack install beta.nvim nil true',
    'done add true',
  }, 'state is settled before the bus hears of it')

  local alpha = H.plugin('alpha.nvim')
  local data = vim.pack.get({ 'alpha.nvim' })[1].spec.data
  H.eq({ data.cmd, data.opts }, { 'AlphaCmd', { style = 'night' } }, 'vim.pack.get() has its cinch fields in data')
  H.eq(data, alpha.data, 'the same ones cinch uses')
  local fixture = vim.fs.joinpath(vim.env.CINCH_FIXTURES, 'alpha.nvim')
  H.eq(pack.rev(alpha), H.sh({ 'git', '-C', fixture, 'rev-parse', 'HEAD' }), 'rev from .git/HEAD')
  H.eq(pack.idle(), true, 'idle once add returned')

  local beta = H.plugin('beta.nvim')
  local path = beta.path
  local ok = require('cinch').del({ 'beta.nvim' }, { force = true })
  H.eq(ok, true, 'delete through cinch')
  H.eq(beta.path, nil, 'path cleared')
  H.eq(vim.uv.fs_stat(path), nil, 'gone from disk')
  H.eq(vim.list_contains(log, 'pack delete beta.nvim nil false'), true, 'Pack delete')
end)
