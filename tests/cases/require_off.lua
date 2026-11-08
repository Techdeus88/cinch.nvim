-- phases: 2
-- Phase 1, `module = false` in setup: no searcher, so a require fails as it does
-- anywhere. Phase 2, `module = false` on one spec: only that plugin is left out.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local before = #package.loaders

require('cinch').setup({
  confirm = false,
  module = H.phase ~= 1,
  spec = {
    {
      { H.src('modly'), cmd = 'ModlyGo', module = H.phase ~= 2 },
      { H.src('twomods'), cmd = 'TwoGo' },
    },
  },
})

H.after_startup(function()
  local ok, err = pcall(require, 'modly')
  H.eq(ok, false, 'require does not load it')
  H.eq(err:find('cinch:', 1, true), nil, 'and says nothing about cinch')
  H.eq(H.plugin('modly').state, 'pending', 'it stays pending')
  H.eq(H.noted('module'), false, 'module is a known spec field')
  if H.phase == 1 then
    H.eq(#package.loaders, before, 'no searcher was added')
    H.eq(pcall(require, 'two'), false, 'for any plugin')
  else
    H.eq(#package.loaders, before + 1, 'the searcher is there')
    H.eq(require('two'), {}, 'and other plugins load')
  end
end)
