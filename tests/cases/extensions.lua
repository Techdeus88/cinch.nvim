-- extensions.lua: an extension named in `extensions` loads before any spec is read, gets
-- its options, and exports through cinch.extensions. One cinch knows the repo of installs
-- when missing and becomes one of your plugins; one already on the runtimepath is used.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

--- A git repo holding lua/cinch/extensions/<name>.lua with `body` as its module.
---@param name string
---@param body string[]
---@return string dir
local function repo(name, body)
  local dir = vim.fs.joinpath(H.home, 'repos', name)
  H.write(vim.fs.joinpath(dir, 'lua', 'cinch', 'extensions', name .. '.lua'), body)
  H.sh({ 'git', 'init', '-q', '-b', 'main' }, dir)
  H.sh({ 'git', 'add', '-A' }, dir)
  H.commit(dir, 'feat: ' .. name)
  return dir
end

local fetched = repo('fetched', {
  'return require("cinch").register_extension({',
  '  setup = function(opts)',
  '    vim.g.fetched_opts = opts',
  '    require("cinch").on("Collect", function() vim.g.fetched_saw_specs = true end)',
  '  end,',
  '  exports = { hi = function() return "hi" end },',
  '  health = function() vim.g.fetched_health = true end,',
  '})',
})
local local_dir = repo('onrtp', { 'return require("cinch").register_extension({ exports = { here = true } })' })
vim.opt.rtp:append(local_dir)
local extensions = require('cinch.extensions')
extensions.known.fetched = 'file://' .. fetched

require('cinch').setup({
  confirm = false,
  extensions = { fetched = { a = 1 }, onrtp = {}, nope = {} },
  spec = { { { H.src('alpha.nvim') } } },
})

H.after_startup(function()
  local cinch = require('cinch')
  H.eq(vim.g.fetched_opts, { a = 1 }, 'setup gets its options')
  H.eq(vim.g.fetched_saw_specs, true, 'before the specs are read')
  H.eq(cinch.extensions.fetched.hi(), 'hi', 'exports through cinch.extensions')
  H.eq(cinch.extensions.onrtp.here, true, 'one on the runtimepath loads where it is')

  local p = H.plugin('fetched')
  H.eq({ p ~= nil, p and p.extension, p and p.state }, { true, 'fetched', 'loaded' }, 'an installed one is a plugin')
  H.eq(H.plugin('onrtp'), nil, 'one outside vim.pack is yours to manage')
  H.eq(H.noted('extension `nope`: not found, and cinch knows no repo'), true, 'an unknown one is reported')

  require('cinch.health').check()
  H.eq(vim.g.fetched_health, true, ':checkhealth runs its check')
end)
