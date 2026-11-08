-- require() of a plugin's module loads the plugin: submodules, pcall, a config that
-- requires the module itself, what the log says, and a plugin added after the first miss.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

cinch.setup({
  confirm = false,
  spec = {
    {
      {
        H.src('modly'),
        cmd = 'ModlyGo',
        config = function()
          vim.g.modly_from_config = require('modly').name
        end,
      },
    },
  },
})

H.after_startup(function()
  local modly = H.plugin('modly')
  H.eq(modly.state, 'pending', 'nothing has required it yet')

  local ok, err = pcall(require, 'no.such.module')
  H.eq(ok, false, 'a module no plugin has')
  H.eq(err:find('cinch:', 1, true), nil, 'gets the plain error')
  H.eq(modly.state, 'pending', 'and loads nothing')

  H.eq(pcall(require, 'modly.nothing'), false, 'a module its plugin does not have')
  H.eq(modly.state, 'pending', 'loads nothing either')

  H.eq(select(2, pcall(require, 'modly.sub')).name, 'sub', 'a submodule loads the plugin')
  H.eq({ modly.state, modly.reason }, { 'loaded', 'require modly.sub' }, 'and names the reason')
  H.eq(vim.g.modly_plugin, 1, 'its plugin/ ran')
  H.eq(vim.api.nvim_get_commands({}).ModlyGo, nil, 'its stub is gone')

  H.eq(require('modly').name, 'modly', 'the module works')
  H.eq(vim.g.modly_from_config, 'modly', 'config required it')
  H.eq(vim.g.modly_runs, 1, 'and it ran once')

  local logged = vim.tbl_filter(function(l)
    return l.msg:find('loaded modly by require modly.sub', 1, true) ~= nil
  end, require('cinch.features.messages').log)
  H.eq(#logged, 1, 'the log says why it loaded')

  cinch.add({ { H.src('twomods'), cmd = 'TwoGo' } }, { confirm = false })
  H.eq(require('two'), {}, 'a plugin added after the first miss is found')
  H.eq(H.plugin('twomods').reason, 'require two', 'and loaded')
end)
