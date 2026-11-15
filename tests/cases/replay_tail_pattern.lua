-- Replay matches a pattern with no slash against the file's tail, as Neovim does: an
-- autocmd for `Cargo.toml` runs for the read that loaded its plugin.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = { { { H.src('cargo'), event = 'BufReadPost' } } },
})

H.after_startup(function()
  local file = vim.fs.joinpath(H.home, 'proj', 'Cargo.toml')
  H.write(file, { '[package]' })
  vim.cmd.edit(file)
  H.eq(H.plugin('cargo').state, 'loaded', 'the read loads it')
  H.eq(vim.g.cargo_read, 1, 'and its autocmd ran for that read')
end)
