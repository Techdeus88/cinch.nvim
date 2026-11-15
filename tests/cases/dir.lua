-- dir: a plugin loaded from a local folder. cinch never installs, updates or deletes it;
-- it loads the way any plugin does, during init.lua or after, and takes triggers.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch, events, pack = require('cinch'), require('cinch.events'), require('cinch.pack')

--- A folder with a plugin in it, outside vim.pack's.
---@param name string
---@return string dir
local function checkout(name)
  local dir = vim.fs.joinpath(H.home, 'checkouts', name)
  H.write(dir .. '/plugin/' .. name .. '.lua', { ('vim.g.%s_plugin = (vim.g.%s_plugin or 0) + 1'):format(name, name) })
  H.write(
    dir .. '/after/plugin/' .. name .. '.lua',
    { ('vim.g.%s_after = (vim.g.%s_after or 0) + 1'):format(name, name) }
  )
  H.write(dir .. '/lua/' .. name .. '.lua', { ('return { setup = function(o) vim.g.%s_opts = o end }'):format(name) })
  return dir
end
local early, lazy, cmdy = checkout('early'), checkout('lazy'), checkout('cmdy')
H.write(
  cmdy .. '/plugin/cmd.lua',
  { "vim.api.nvim_create_user_command('LocalGo', function() vim.g.local_go = true end, {})" }
)

local installing
events.on('Installing', function(d)
  installing = d.names
end)

cinch.setup({
  confirm = false,
  features = { 'updates' },
  spec = {
    {
      { dir = early, load = 'now', opts = { a = 1 } },
      { dir = lazy },
      { 'owner/cmdy', dir = cmdy, cmd = 'LocalGo' },
      { dir = vim.fs.joinpath(H.home, 'checkouts', 'gone') },
      { H.src('alpha.nvim') },
    },
  },
})
local at_init = H.plugin('early').state

H.after_startup(function()
  H.eq(at_init, 'loaded', 'a now plugin loads from its folder during init.lua')
  H.eq(
    { vim.g.early_plugin, vim.g.early_after, vim.g.early_opts },
    { 1, 1, { a = 1 } },
    'plugin/, after/plugin/ and setup()'
  )
  H.eq(H.plugin('early').path, early, 'its path is the folder')
  H.eq(installing, { 'alpha.nvim' }, 'only what vim.pack owns installs')
  H.eq(vim.uv.fs_stat(vim.fs.joinpath(pack.dir, 'early')), nil, 'nothing is cloned for it')

  H.wait(function()
    return H.plugin('lazy').state == 'loaded'
  end, 'the later plugin')
  H.eq({ vim.g.lazy_plugin, vim.g.lazy_after }, { 1, 1 }, 'after startup, its files are sourced once')
  H.eq(require('lazy') ~= nil, true, 'and its modules resolve')

  H.eq(H.plugin('cmdy').state, 'pending', 'one with a trigger waits')
  vim.cmd('LocalGo')
  H.eq({ H.plugin('cmdy').state, vim.g.local_go }, { 'loaded', true }, 'and its command loads it, then runs')

  local gone = H.plugin('gone')
  H.eq({ gone.state, gone.failed_in }, { 'failed', 'install' }, 'a folder that is not there fails')

  local checked
  require('cinch.features.updates').check(nil, {
    on_done = function()
      checked = true
    end,
  })
  H.wait(function()
    return checked
  end, 'the update check')
  H.eq(
    vim.tbl_contains(vim.tbl_keys(require('cinch.features.updates').results), 'early'),
    false,
    'never checked for updates'
  )
  H.eq(cinch.del({ 'early' }, { force = true }) ~= false, true, 'deleting it does nothing')
  H.eq(vim.uv.fs_stat(early) ~= nil, true, 'the folder stays')
end)
