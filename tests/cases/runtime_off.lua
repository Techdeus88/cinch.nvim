-- disable_runtime keeps Neovim's own plugins you name from loading at startup, and
-- leaves the rest; the startup marks and User CinchDone.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local done = 0
vim.api.nvim_create_autocmd('User', {
  pattern = 'CinchDone',
  callback = function()
    done = done + 1
  end,
})
require('cinch').setup({
  confirm = false,
  disable_runtime = { 'gzip', 'netrwPlugin', 'nosuch' },
  spec = { { { H.src('alpha.nvim') } } },
})

H.after_startup(function()
  local sourced = {}
  for _, s in ipairs(vim.fn.getscriptinfo()) do
    if vim.startswith(s.name, vim.env.VIMRUNTIME .. '/plugin/') then
      sourced[vim.fn.fnamemodify(s.name, ':t:r')] = true
    end
  end
  H.eq({ sourced.gzip, sourced.netrwPlugin }, { nil, nil }, 'the ones you name do not load')
  H.eq(sourced.matchit and sourced.tarPlugin, true, 'the rest do')
  H.eq(vim.fn.exists(':Explore'), 0, 'netrw is off')
  H.eq(require('cinch').runtime_off, { 'gzip', 'netrwPlugin' }, 'what is off')
  H.eq(H.noted('no runtime plugin `nosuch`; there are .*gzip'), true, 'a name that is not there says what is')
  vim.cmd('runtime plugin/gzip.vim')
  H.eq(vim.g.loaded_gzip ~= nil, true, 'after startup, :runtime works as usual')

  H.eq(done, 1, 'User CinchDone, once')
  local m = require('cinch.features.stats').marks
  H.eq(m.setup < m.done and m.done < m.vimenter, true, 'CinchStart, then CinchDone, then VimEnter')
  local stats = table.concat(require('cinch.features.ui.dashboard').stats(100).lines, '\n')
  H.eq(
    stats:find('CinchStart +[%d.]+m?s') ~= nil and stats:find('CinchDone +[%d.]+m?s %(%+[%d.]+m?s%)') ~= nil,
    true,
    'in Stats'
  )
  H.eq(stats:find('runtime off +gzip · netrwPlugin') ~= nil, true, 'with what is off')
end)
