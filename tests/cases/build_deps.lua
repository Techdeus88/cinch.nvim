-- A function build sees its dependencies on the runtimepath too, as blink.cmp's needs
-- blink.lib, and they come off again after. A dependency that loads while the build
-- runs is loaded properly: its plugin/ files run, and it stays.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local events = require('cinch.events')
vim.loader.enable()

local built = {}
events.on('Build', function(d)
  built[d.plugin.name] = d.ok and 'ok' or d.err
end)

require('cinch').setup({
  confirm = false,
  features = {},
  spec = {
    {
      {
        H.src('delta.nvim'),
        keys = '<leader>zz',
        deps = { { H.src('beta.nvim'), keys = '<leader>zy' } },
        build = function()
          vim.g.delta_saw = require('beta').v
        end,
      },
      {
        H.src('builder'),
        cmd = 'BuilderGo',
        module = false,
        deps = { { H.src('alpha.nvim'), cmd = 'AlphaCmd' } },
        build = function(_, done)
          vim.g.builder_saw = require('alpha') ~= nil
          vim.defer_fn(function()
            require('cinch').load({ 'alpha.nvim' })
            done(true)
          end, 100)
        end,
      },
      {
        H.src('cmdy'),
        cmd = 'CmdyGo',
        deps = { { H.src('oncy'), cmd = 'OncyGo' } },
        -- Not async: the first build, at install, ends before startup sources anything.
        build = function()
          if vim.g.late then
            require('cinch').load({ 'oncy' })
          end
        end,
      },
    },
  },
})

H.after_startup(function()
  H.wait(function()
    return built['delta.nvim'] and built['builder']
  end, 'both builds to end')
  H.eq(built['delta.nvim'], 'ok', 'the build that requires its dependency succeeds')
  H.eq(vim.g.delta_saw, 1, 'and saw the dependency')
  local beta = H.plugin('beta.nvim')
  H.eq(beta.state, 'pending', 'the dependency is still not loaded')
  H.eq(vim.list_contains(vim.opt.rtp:get(), beta.path), false, 'and is off the runtimepath again')
  H.eq(package.loaded.beta, nil, 'with its module forgotten')

  H.eq(built['builder'], 'ok', 'the async build succeeds')
  H.eq(vim.g.builder_saw, true, 'and saw its dependency')
  local alpha = H.plugin('alpha.nvim')
  H.eq(alpha.state, 'loaded', 'the dependency it loaded is loaded')
  H.eq(vim.g.alpha_plugin, 1, 'with its plugin/ file run')
  H.eq(vim.list_contains(vim.opt.rtp:get(), alpha.path), true, 'and stays on the runtimepath')

  -- After startup nothing sources a borrowed path on its own: the load must.
  vim.g.late = true
  built['cmdy'] = nil
  require('cinch').build({ 'cmdy' })
  H.wait(function()
    return built['cmdy']
  end, 'the build after startup to end')
  H.eq(H.plugin('oncy').state, 'loaded', 'the dependency it loaded is loaded')
  vim.api.nvim_exec_autocmds('User', { pattern = 'OncyGo' })
  H.eq(vim.g.oncy, 1, 'with its plugin/ file run once')
end)
