-- An async function build keeps the plugin on the runtimepath until it calls done(), and a
-- build that raises after done() ends once.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch, events = require('cinch'), require('cinch.events')

local built = {}
events.on('Build', function(d)
  built[#built + 1] = d
end)
local finish ---@type function
cinch.setup({
  confirm = false,
  features = {},
  spec = {
    {
      {
        H.src('alpha.nvim'),
        cmd = 'AlphaCmd',
        build = function(_, done)
          finish = function()
            vim.g.alpha_late = require('alpha') ~= nil
            done(true)
          end
        end,
      },
      {
        H.src('beta.nvim'),
        cmd = 'BetaCmd',
        build = function(_, done)
          done(true)
          error('boom')
        end,
      },
    },
  },
})

H.after_startup(function()
  H.wait(function()
    return finish ~= nil and #built == 1
  end, 'beta to build')
  H.eq({ built[1].plugin.name, built[1].ok }, { 'beta.nvim', true }, 'done() before a raise ends the build once')
  H.eq(H.noted('raised after done()'), true, 'and the raise is reported')
  finish()
  H.wait(function()
    return #built == 2
  end, 'alpha to build')
  H.eq(vim.g.alpha_late, true, 'a module of the plugin loads after the build function returned')
  H.eq(vim.list_contains(vim.opt.rtp:get(), H.plugin('alpha.nvim').path), false, 'and the path leaves after done()')
end)
