-- :checkhealth cinch: what it reports about Neovim, git, plugins, features and timing.
-- vim.health is replaced with recorders, so the report can be read back.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = { { { H.src('alpha.nvim') }, { H.src('broken.nvim'), opts = {} } } },
})

H.after_startup(function()
  -- Loaded now: a plugin with no trigger waits in the `later` queue.
  require('cinch').load('broken.nvim')
  local seen = {}
  for _, kind in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
    vim.health[kind] = function(msg)
      seen[#seen + 1] = kind .. ': ' .. tostring(msg)
    end
  end
  require('cinch.health').check()
  local report = table.concat(seen, '\n')

  H.eq(report:find('start: cinch', 1, true) ~= nil, true, 'a section for cinch')
  H.eq(report:find('ok: vim.pack is there', 1, true) ~= nil, true, 'vim.pack is there')
  H.eq(report:find('ok: git version', 1, true) ~= nil, true, 'git is found, with its version')
  H.eq(report:find('error: `broken.nvim` failed to load', 1, true) ~= nil, true, 'a plugin that failed is an error')
  H.eq(
    report:find('ok: startup is timed from when the process began', 1, true) ~= nil,
    true,
    'the start time came from the OS'
  )
  H.eq(report:find('ok: checks for updates every 86400 seconds', 1, true) ~= nil, true, 'update checks are said')
end)
