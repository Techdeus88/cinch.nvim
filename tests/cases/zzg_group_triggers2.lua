-- Group triggers, batch 2: idle, mode, bt, path, on, and focus, each set on a group.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
vim.opt.rtp:prepend(assert(vim.env.CINCH_GROUPS_ROOT))

local notes = vim.fs.joinpath(H.home, 'notes')
H.write(vim.fs.joinpath(notes, 'today.md'), { '# today' })
H.write(vim.fs.joinpath(H.home, 'api.http'), { 'GET /' })

require('cinch-groups').setup({
  confirm = false,
  features = { 'messages' },
  spec = {
    {
      { group = 'quiet', idle = 150, { H.src('alpha.nvim') } },
      { group = 'typing', mode = 'i', { H.src('beta.nvim') } },
      { group = 'qf', bt = 'quickfix', { H.src('delta.nvim') } },
      { group = 'notes', path = '~/notes/**', { H.src('gamma') } },
      { group = 'http', path = '*.http', { H.src('opy') } },
      { group = 'manual', on = 'Notes', { H.src('oncy') }, { H.src('vimmy') } },
      { group = 'back', focus = true, { H.src('early') } },
      { group = 'badmode', mode = 'insert', { H.src('dup-first') } },
    },
  },
})
-- Under the test's home, so `~/notes/**` points at the folder written above.
vim.env.HOME = H.home

H.after_startup(function()
  local function loaded(name)
    return H.plugin(name).state == 'loaded'
  end
  local function reason(name)
    return H.plugin(name).reason
  end
  H.eq(H.noted('unknown field'), false, 'cinch knows every trigger')

  H.wait(function()
    return loaded('alpha.nvim')
  end, 'idle to load alpha.nvim', 2000)
  H.eq(reason('alpha.nvim'), 'idle 150', 'idle: once no key came for that long')

  H.eq(H.plugin('beta.nvim').state, 'pending', 'mode: waits for insert mode')
  H.press('i')
  H.press('<Esc>')
  H.eq({ loaded('beta.nvim'), reason('beta.nvim') }, { true, 'mode i' }, 'loads on entering it')
  H.eq(H.noted('`mode = "insert"`: each value should be one mode letter'), true, 'a bad mode warns')

  vim.fn.setqflist({ { filename = 'x', lnum = 1, text = 'x' } })
  vim.cmd('copen')
  H.eq({ loaded('delta.nvim'), reason('delta.nvim') }, { true, 'bt quickfix' }, 'bt: when a quickfix list shows')
  vim.cmd('cclose')

  vim.cmd.edit(vim.fs.joinpath(H.home, 'api.http'))
  H.eq({ loaded('opy'), reason('opy') }, { true, 'path *.http' }, 'path: a name glob matches the file name')
  H.eq(H.plugin('gamma').state, 'pending', 'and a folder glob waits for its folder')
  vim.cmd.edit(vim.fs.joinpath(notes, 'today.md'))
  H.eq({ loaded('gamma'), reason('gamma') }, { true, 'path ~/notes/**' }, 'which loads it')
  H.eq(vim.g.gamma_saw, 1, 'and its own BufReadPost runs for that buffer')

  H.eq(H.plugin('oncy').state, 'pending', 'on: waits for its name')
  require('cinch-groups').fire('Notes')
  H.eq({ loaded('oncy'), loaded('vimmy'), reason('vimmy') }, { true, true, 'on Notes' }, 'fire() loads the group')

  vim.api.nvim_exec_autocmds('FocusGained', {})
  H.eq(H.plugin('early').state, 'pending', 'focus: not on the FocusGained of a start')
  vim.api.nvim_exec_autocmds('FocusLost', {})
  vim.api.nvim_exec_autocmds('FocusGained', {})
  H.eq({ loaded('early'), reason('early') }, { true, 'focus true' }, 'but on coming back')
end)
