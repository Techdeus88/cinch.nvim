-- Whether a UI is coming: never headless, in silent Ex mode or for a -l script; an embedded Neovim only when
-- its UI is attached by the time init.lua runs, since one driven without a UI never gets UIEnter.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch, handler = require('cinch'), require('cinch.handler')

cinch.setup({ confirm = false, features = {}, spec = { { { H.src('beta.nvim') } } } })

H.after_startup(function()
  H.eq(handler.ui_coming({ 'nvim' }, 0), true, 'a plain start')
  H.eq(handler.ui_coming({ 'nvim', '--headless' }, 0), false, 'headless')
  H.eq(handler.ui_coming({ 'nvim', '--embed' }, 1), true, 'embedded, with its UI attached')
  H.eq(handler.ui_coming({ 'nvim', '--embed' }, 0), false, 'embedded, with none')
  H.eq(handler.ui_coming({ 'nvim', '--embed', '--headless' }, 1), false, 'headless wins')
  H.eq(handler.ui_coming({ 'nvim', '-es' }, 0), false, 'silent Ex mode')
  H.eq(handler.ui_coming({ 'nvim', '-Es' }, 0), false, 'silent improved Ex mode')
  H.eq(handler.ui_coming({ 'nvim', '-e', '-s' }, 0), false, 'silent Ex mode, as two flags')
  H.eq(handler.ui_coming({ 'nvim', '-s', 'keys.txt', '-e' }, 0), true, '-s before -e names a script')
  H.eq(handler.ui_coming({ 'nvim', '--', '-es' }, 0), true, 'after --, a file name')
  H.eq(handler.ui_coming({ 'nvim', '--', '--headless' }, 0), true, 'even --headless')
  H.eq(handler.ui_coming({ 'nvim', '-u', 'init.lua', '-l', 'x.lua' }, 0), false, 'a -l script')
  H.eq(handler.ui_coming({ 'nvim', '--', '-l', 'x.lua' }, 0), true, 'but not after --')
  H.eq(handler.ui_coming({ 'nvim', '-l', 'x.lua', '--embed' }, 1), false, "what follows -l is the script's")
  H.eq(cinch.ui_coming(), false, 'this session is headless')
  H.wait(function()
    return H.plugin('beta.nvim').state == 'loaded'
  end, 'the later queue, with no UIEnter')
end)
