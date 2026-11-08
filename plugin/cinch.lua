-- The user command only. Everything behind it is required on first use.
if vim.g.loaded_cinch then
  return
end
vim.g.loaded_cinch = true

require('cinch.usercmd').define_default()
