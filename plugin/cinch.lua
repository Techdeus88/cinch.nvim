-- :Cinch only. Everything behind it is required on first use.
if vim.g.loaded_cinch then
  return
end
vim.g.loaded_cinch = true

vim.api.nvim_create_user_command('Cinch', function(a)
  require('cinch.command').run(a.fargs, a.bang)
end, {
  nargs = '*',
  bang = true,
  desc = 'cinch: plugins',
  complete = function(lead, line)
    return require('cinch.command').complete(lead, line)
  end,
})
