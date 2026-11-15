-- A trigger stub something else replaced: the key or command no longer loads the plugin,
-- and cinch says so when the plugin loads another way. A stub still in place says nothing.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = {
    {
      { H.src('delta.nvim'), keys = { 'gA', 'gB' }, cmd = { 'DeltaGo', 'DeltaTwo' } },
      { H.src('beta.nvim'), keys = 'gE' },
    },
  },
})
-- Taken over after setup(), the way another plugin's mapping would.
vim.keymap.set('n', 'gB', '<Nop>')
vim.api.nvim_create_user_command('DeltaTwo', function() end, {})

H.after_startup(function()
  require('cinch').load('delta.nvim')
  H.eq(H.plugin('delta.nvim').state, 'loaded', 'it loads')
  H.eq(
    H.noted('`delta.nvim`: its key `gB` was mapped by something else before it loaded'),
    true,
    'a replaced key is reported'
  )
  H.eq(
    H.noted('`delta.nvim`: its command `:DeltaTwo` was defined by something else before it loaded'),
    true,
    'and a replaced command'
  )
  H.eq(H.noted('`gA`'), false, 'a key still its stub is not')
  H.eq(H.noted(':DeltaGo'), false, 'nor a command')
  H.eq(vim.fn.maparg('gB', 'n'), '<Nop>', 'the mapping that replaced it stays')

  local notes = #H.notes
  require('cinch').load('beta.nvim')
  H.eq(#H.notes, notes, 'a plugin whose stubs are all in place says nothing')
end)
