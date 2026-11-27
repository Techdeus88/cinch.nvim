-- extensions.lua: an extension named in `extensions` loads before any spec is read, gets
-- its options, and exports through cinch.extensions. One cinch knows the repo of installs
-- when missing and becomes one of your plugins, through cinch, so vim.pack's own
-- progress never reaches the command line; one already on the runtimepath is used.
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

-- What vim.pack echoes itself, past cinch.
local from_pack = {}
local echo = vim.api.nvim_echo
---@diagnostic disable-next-line: duplicate-set-field
vim.api.nvim_echo = function(chunks, history, o)
  if type(o) == 'table' and o.source == 'vim.pack' then
    from_pack[#from_pack + 1] = chunks[1] and chunks[1][1]
  end
  return echo(chunks, history, o)
end

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
  H.eq(vim.list_contains(require('cinch.state').yours(), p), false, 'kept by cinch, like cinch: not one of yours')
  cinch.del({ 'fetched' })
  H.eq(H.noted('not deleted: `fetched` is a cinch extension'), true, 'and not deleted')
  H.eq(vim.uv.fs_stat(p.path) ~= nil, true, 'it stays on disk')
  H.eq(from_pack, {}, "its install went through cinch: none of vim.pack's progress reached Neovim")
  local logged = vim.tbl_filter(function(e)
    return e.source == 'vim.pack' and e.msg:find('^Installing plugins') ~= nil
  end, require('cinch.features.messages').log)
  H.eq(#logged > 0, true, 'and the Log has it')
  H.eq(H.plugin('onrtp'), nil, 'one outside vim.pack is yours to manage')
  H.eq(H.noted('extension `nope`: not found, and cinch knows no repo'), true, 'an unknown one is reported')

  require('cinch.health').check()
  H.eq(vim.g.fetched_health, true, ':checkhealth runs its check')
end)
