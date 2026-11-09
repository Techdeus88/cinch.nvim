-- phases: 2
-- A spec file that fails to load makes its plugins look like strays on disk, so clean
-- deletes nothing then; `:Cinch clean!` still does. Phase 1 installs; phase 2 drops
-- gamma from the specs and adds a broken spec file.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

---@diagnostic disable-next-line: duplicate-set-field
vim.fn.confirm = function()
  return 1
end

local spec = { { H.src('alpha.nvim') } }
if H.phase == 1 then
  spec[#spec + 1] = { H.src('gamma') }
else
  H.write('lua/plugins/broken.lua', { "error('broken spec')" })
end
cinch.setup({ confirm = false, spec = { 'plugins', spec } })

local function on_disk(name)
  return vim.uv.fs_stat(vim.fs.joinpath(require('cinch.pack').dir, name)) ~= nil
end

H.after_startup(function()
  if H.phase == 1 then
    H.eq(on_disk('gamma'), true, 'installed')
    return
  end
  H.eq(H.noted('broken spec'), true, 'the broken file is reported')
  vim.cmd('Cinch clean')
  H.eq(on_disk('gamma'), true, 'clean deletes nothing')
  H.eq(H.noted('A spec file failed to load, so nothing was deleted'), true, 'and says why')
  H.eq(cinch.clean(), {}, 'from Lua too')
  vim.cmd('Cinch clean!')
  H.eq(on_disk('gamma'), false, 'the bang deletes anyway')
end)
