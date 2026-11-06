-- cinch.install, :Cinch install and the i key: a plugin whose install failed installs
-- again once its source is there, and loads as its spec says.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local late_dir = vim.fs.joinpath(H.home, 'repos', 'late')
require('cinch').setup({
  confirm = false,
  spec = { { { H.src('alpha.nvim') }, { 'file://' .. late_dir }, { H.src('beta.nvim'), cmd = 'BetaGo' } } },
})

H.after_startup(function()
  local late = H.plugin('late')
  H.wait(function()
    return late.state == 'failed'
  end, 'the install to fail')
  H.eq(late.failed_in, 'install', 'its source is not there yet')

  vim.fn.mkdir(vim.fs.dirname(late_dir), 'p')
  H.sh({ 'git', 'clone', '-q', vim.fs.joinpath(vim.env.CINCH_FIXTURES, 'gamma'), late_dir })
  local tried = require('cinch').install({ 'late' })
  H.eq(#tried, 1, 'cinch.install tries it again')
  H.eq(late.path ~= nil, true, 'and it is on disk')
  H.wait(function()
    return late.state == 'loaded'
  end, 'it to load later, as its spec says')
  H.eq(late.err, nil, 'the old error is gone')

  vim.cmd('Cinch install')
  H.eq(H.noted('nothing to install'), true, ':Cinch install with nothing missing says so')
  H.eq(H.noted('already installed'), false, 'and only that')

  -- The i key, on a plugin deleted this session.
  local beta = H.plugin('beta.nvim')
  require('cinch').del({ 'beta.nvim' }, { force = true })
  H.wait(function()
    return beta.path == nil
  end, 'beta to be deleted')
  vim.cmd('Cinch open plugins')
  local ui = require('cinch.features.ui')
  local w = ui.windows()
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w.list), 0, -1, false)
  for l, line in ipairs(lines) do
    if line:find(' beta%.nvim ') then
      vim.api.nvim_win_set_cursor(w.list, { l, 0 })
    end
  end
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(w.list) })
  vim.wait(20)
  H.press('i')
  H.wait(function()
    return beta.path ~= nil
  end, 'i to install it')
  H.eq(beta.state, 'pending', 'still waiting for its trigger')
  vim.cmd('BetaGo')
  H.eq(beta.state, 'loaded', 'which still loads it')
end)
