-- With vim.loader on, its cached runtimepath still finds a plugin added by the searcher,
-- during init.lua and after startup, even after a miss has been cached.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
vim.loader.enable()

require('cinch').setup({
  confirm = false,
  spec = {
    {
      { H.src('modly'), cmd = 'ModlyGo' },
      { H.src('twomods'), cmd = 'TwoGo' },
    },
  },
})

H.eq(pcall(require, 'modly.nothing'), false, 'a miss first')
H.eq(require('modly.sub').name, 'sub', 'during init.lua')
H.eq(H.plugin('modly').state, 'loaded', 'it loads the plugin')

H.after_startup(function()
  H.eq(require('modly').name, 'modly', 'the rest of it resolves')
  H.eq(pcall(require, 'two.nothing'), false, 'a miss after startup')
  H.eq(require('two'), {}, 'after startup')
  H.eq(H.plugin('twomods').reason, 'require two', 'it loads the plugin')
  H.eq(package.loaded['two'], {}, 'with one copy of the module')
end)
