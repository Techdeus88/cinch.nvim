-- phases: 3
-- The live first start.
-- Phase 1, a first start: nothing on disk, a UI is coming, so everything waits for
-- UIEnter; add() calls meanwhile join the batch; Installing and Installed frame it.
-- Phase 2, a spec whose src does not exist: what is on disk starts as usual during
-- init.lua, and only the missing plugin waits for the UI.
-- Phase 3, a new machine with your lockfile: a locked plugin is gone from disk, so
-- the whole batch waits, since vim.pack's first call would install it anyway.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch, events, pack = require('cinch'), require('cinch.events'), require('cinch.pack')

if H.phase == 3 then
  vim.fn.delete(vim.fs.joinpath(pack.dir, 'beta.nvim'), 'rf')
end

-- Headless Neovim never gets a UI; pretend one is coming, and send UIEnter by hand.
cinch.ui_coming = function()
  return true
end

local seen = {}
events.on('Installing', function(d)
  seen.installing = d.names
end)
events.on('Installed', function(d)
  seen.failed = d.failed
end)

cinch.setup({
  confirm = false,
  features = {},
  spec = { { { H.src('early'), load = 'now' }, { H.src('beta.nvim') }, { H.src('missing') } } },
})
cinch.add({ { H.src('alpha.nvim'), cmd = 'AlphaCmd' } })
-- A :Cmd build needs its plugin loaded, so it must wait until the batch is armed.
cinch.add({ { H.src('cmdy'), cmd = 'CmdyGo', build = ':CmdyBuild' } })
local after_setup = { early = H.plugin('early').state, alpha = H.plugin('alpha.nvim').state }

local function ui_enter()
  vim.api.nvim_exec_autocmds('UIEnter', {})
  H.wait(function()
    return seen.failed ~= nil and H.plugin('beta.nvim').state == 'loaded'
  end, 'the batch to install and start')
  table.sort(seen.installing)
end

H.after_startup(function()
  if H.phase == 2 then
    H.eq(after_setup.early, 'loaded', 'what is on disk loads during init.lua as usual')
    H.eq(H.plugin('missing').state, 'registered', 'only the missing plugin waits')
    vim.api.nvim_exec_autocmds('UIEnter', {})
    H.wait(function()
      return seen.failed ~= nil
    end, 'the missing plugin to be tried')
    H.eq(seen.installing, { 'missing' }, 'and is the only one installed on UIEnter')
    return
  elseif H.phase == 3 then
    H.eq(after_setup.early, 'registered', 'a locked plugin is missing: everything waits')
    ui_enter()
    H.eq(seen.installing, { 'beta.nvim', 'missing' }, 'the locked plugin is installed again')
    return
  end

  H.eq(after_setup, { early = 'registered', alpha = 'registered' }, 'setup waits for the UI')
  H.eq(vim.uv.fs_stat(pack.dir .. '/early'), nil, 'nothing installed before UIEnter')
  H.eq(pack.idle(), false, 'and vim.pack not called yet')
  ui_enter()
  H.eq(
    seen.installing,
    { 'alpha.nvim', 'beta.nvim', 'cmdy', 'early', 'missing' },
    'one batch, the add() calls joined it'
  )
  H.eq(seen.failed, { 'missing' }, 'Installed names what did not install')
  H.eq(H.plugin('early').reason, 'now', 'now plugins load right after the batch')
  H.eq(vim.g.early_did_enter, 1, 'after VimEnter on a first start')
  vim.cmd('AlphaCmd go')
  H.eq(vim.g.alpha_cmd.args, 'go', 'triggers are armed after the batch')
  H.eq(H.plugin('missing').failed_in, 'install', 'a failed install is marked')
  H.eq(vim.g.cmdy_built, true, 'a :Cmd build ran once its plugin was armed')
  H.eq(H.plugin('cmdy').reason, 'build', 'loading the plugin first')
end)
