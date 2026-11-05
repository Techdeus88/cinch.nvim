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

local seen = { done = {} }
-- What had loaded when User CinchDone fired.
vim.api.nvim_create_autocmd('User', {
  pattern = 'CinchDone',
  callback = function()
    seen.done[#seen.done + 1] = { early = H.plugin('early').state, installed = seen.failed ~= nil }
  end,
})
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
-- While the batch waits, cinch.now() waits with it.
cinch.now(function()
  vim.g.now_saw = H.plugin('early').state
end)
local after_setup = { early = H.plugin('early').state, alpha = H.plugin('alpha.nvim').state, now_ran = vim.g.now_saw }

--- User CinchDone fired once, after the batch installed and its now plugins loaded.
local function done_after_batch()
  H.wait(function()
    return #seen.done > 0
  end, 'User CinchDone')
  H.eq(seen.done, { { early = 'loaded', installed = true } }, 'CinchDone once the batch has installed and loaded')
end

local function ui_enter()
  H.eq(seen.done, {}, 'no CinchDone while a batch waits for the UI')
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
    H.eq(after_setup.now_ran, 'loaded', 'and now() runs during init.lua as usual')
    H.eq(seen.done, {}, 'CinchDone waits for the missing plugin too')
    vim.api.nvim_exec_autocmds('UIEnter', {})
    H.wait(function()
      return seen.failed ~= nil
    end, 'the missing plugin to be tried')
    H.eq(seen.installing, { 'missing' }, 'and is the only one installed on UIEnter')
    done_after_batch()
    return
  elseif H.phase == 3 then
    H.eq(after_setup.early, 'registered', 'a locked plugin is missing: everything waits')
    H.eq(after_setup.now_ran, nil, 'now() too')
    ui_enter()
    H.eq(seen.installing, { 'beta.nvim', 'missing' }, 'the locked plugin is installed again')
    done_after_batch()
    return
  end

  H.eq(after_setup, { early = 'registered', alpha = 'registered' }, 'setup waits for the UI, and so does now()')
  H.eq(vim.uv.fs_stat(pack.dir .. '/early'), nil, 'nothing installed before UIEnter')
  H.eq(pack.idle(), false, 'and vim.pack not called yet')
  ui_enter()
  H.eq(
    seen.installing,
    { 'alpha.nvim', 'beta.nvim', 'cmdy', 'early', 'missing' },
    'one batch, the add() calls joined it'
  )
  H.eq(seen.failed, { 'missing' }, 'Installed names what did not install')
  done_after_batch()
  H.eq(H.plugin('early').reason, 'now', 'now plugins load right after the batch')
  H.eq(vim.g.early_did_enter, 1, 'after VimEnter on a first start')
  vim.cmd('AlphaCmd go')
  H.eq(vim.g.alpha_cmd.args, 'go', 'triggers are armed after the batch')
  H.eq(H.plugin('missing').failed_in, 'install', 'a failed install is marked')
  H.eq(vim.g.cmdy_built, true, 'a :Cmd build ran once its plugin was armed')
  H.eq(vim.g.now_saw, 'loaded', 'now() ran after the batch, once its now plugins loaded')
  H.eq(H.plugin('cmdy').reason, 'build', 'loading the plugin first')
end)
