-- `load = 'never'`: installed and built, its init runs, and nothing loads it: not a
-- trigger, a require(), :Cinch load, nor a plugin that needs it, which loads beside it.
-- The window shows it with its own chip and leaves it out of the waiting count.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')
local api = vim.api

cinch.setup({
  confirm = false,
  spec = {
    {
      {
        H.src('modly'),
        load = 'never',
        cmd = 'ModlyGo',
        opts = {},
        build = 'touch built',
        init = function(p)
          vim.g.never_init = p.path
        end,
      },
      { H.src('twomods'), load = 'never', build = ':TwoBuild' },
      { H.src('alpha.nvim'), cmd = 'AlphaCmd', deps = { 'modly' } },
    },
  },
})

H.after_startup(function()
  local modly = H.plugin('modly')
  H.wait(function()
    return modly.activity == nil and H.plugin('twomods').activity == nil
  end, 'the builds')
  H.eq({ modly.state, modly.when }, { 'pending', 'never' }, 'on disk, and nothing comes for it')
  H.eq(vim.list_contains(vim.opt.rtp:get(), modly.path), false, 'not on the runtimepath')
  H.eq(vim.g.modly_plugin, nil, 'its plugin/ never ran')
  H.eq(vim.uv.fs_stat(modly.path .. '/built') ~= nil, true, 'its shell build ran')
  H.eq(vim.g.never_init, modly.path, 'its init ran, with its path')
  H.eq(api.nvim_get_commands({}).ModlyGo, nil, 'no stub for its cmd')
  H.eq(H.noted('modly.*so its triggers are ignored'), true, 'its trigger is named as ignored')
  H.eq(H.noted('modly.*so its `opts` is ignored'), true, 'and so are its opts')
  H.eq(H.noted('twomods.*so its `:` build cannot run'), true, 'a `:` build is warned about')
  H.eq(H.noted('build of `twomods` failed: it needs the plugin loaded'), true, 'and fails')

  H.eq(pcall(require, 'modly'), false, 'require() does not load it')
  cinch.load('modly')
  H.eq(modly.state, 'pending', ':Cinch load does not either')
  H.eq(H.noted('`modly` not loaded: it sets load = `never`'), true, 'and says why')

  cinch.load('alpha.nvim')
  H.eq(H.plugin('alpha.nvim').state, 'loaded', 'a plugin needing it loads')
  H.eq(modly.state, 'pending', 'beside it, still not loaded')

  local rows = require('cinch.features.ui.rows')
  H.eq(rows.section_of(modly), 'never', 'its own section')
  local chip = rows.load_items(modly, {})[1][1][1]
  H.eq(vim.endswith(chip, ' never'), true, 'with its own chip')

  vim.cmd('Cinch')
  local w = require('cinch.features.ui').windows()
  local row2 = H.header()[2]
  H.eq(row2:find('waiting', 1, true), nil, 'nothing counted as waiting')
  H.eq(row2:find('1 loaded', 1, true) ~= nil, true, 'alpha counted as loaded')
  local list = api.nvim_buf_get_lines(api.nvim_win_get_buf(w.list), 0, -1, false)
  local found = vim.tbl_filter(function(l)
    return l:find(' modly ', 1, true) and l:find(' never', 1, true)
  end, list)
  H.eq(#found, 1, 'its row shows the chip')
end)
