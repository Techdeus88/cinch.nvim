-- A module root like 'plugins' is read from your config's lua/ folder only: a plugin on
-- the runtimepath that ships a lua/plugins/ of its own, for lazy.nvim, is not your specs.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local spec = require('cinch.spec')

H.write('lua/plugins.lua', { "return { 'owner/top' }" })
H.write('lua/plugins/mine.lua', { "return { 'owner/mine' }" })
local other = vim.fs.joinpath(H.home, 'other')
H.write(vim.fs.joinpath(other, 'lua/plugins/stray.lua'), { "return { 'owner/stray' }" })
H.write(vim.fs.joinpath(other, 'lua/plugins.lua'), { "return { 'owner/stray-top' }" })
vim.opt.rtp:prepend(other)

local srcs = vim.tbl_map(function(e)
  return e.spec[1]
end, spec.collect({ 'plugins' }, { file = 'init.lua' }))
H.eq(srcs, { 'owner/top', 'owner/mine' }, 'only the config folder is read, plugins.lua first')
H.eq(spec.collect({ 'nothing.here' }, { file = 'init.lua' }), {}, 'a root with no files reads nothing')

require('cinch').setup({ confirm = false, features = {}, spec = {} })
H.after_startup(function() end)
