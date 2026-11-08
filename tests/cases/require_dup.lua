-- phases: 2
-- Two plugins provide one module: the first declared wins, with one warning. Phase 2
-- disables the first, on disk by then, so the second serves it with no warning.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = {
    {
      { H.src('dup-first'), cmd = 'DupOne', enabled = H.phase == 1 },
      { H.src('dup-second'), cmd = 'DupTwo' },
    },
  },
})

H.after_startup(function()
  local warned = H.noted("'dupmod' is in `dup%-first` and `dup%-second`; loading the first declared")
  if H.phase == 1 then
    H.eq(warned, false, 'no warning before anything asks')
    H.eq(require('dupmod').from, 'first', 'the first declared wins')
    H.eq(H.noted("'dupmod' is in `dup%-first` and `dup%-second`"), true, 'with a warning')
    H.eq(H.plugin('dup-second').state, 'pending', 'and the second stays pending')
  else
    H.eq(require('dupmod').from, 'second', 'a disabled plugin does not count')
    H.eq(H.noted("'dupmod' is in"), false, 'so there is nothing to warn about')
  end
end)
