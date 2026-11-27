-- How far git is with a plugin: its --progress records as a percent, the reader that
-- takes them out of stderr, and watch(), which gives vim.pack's clone and checkout
-- --progress and keeps what they print about it from vim.pack.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({ confirm = false, spec = { { H.src('alpha.nvim') } } })

H.after_startup(function()
  local progress = require('cinch.progress')
  local alpha = H.plugin('alpha.nvim')

  H.eq(
    {
      progress.percent('remote: Counting objects:  50% (289/578)        ', 'clone'),
      progress.percent('Receiving objects:   0% (1/2833)', 'clone'),
      progress.percent('Receiving objects: 100% (2833/2833), 1.2 MiB | 2.3 MiB/s, done.', 'clone'),
      progress.percent('Resolving deltas: 100% (1532/1532), done.', 'clone'),
      progress.percent('Updating files:  50% (28/56)', 'files'),
      progress.percent('Updating files: 100% (56/56), done.', 'files'),
      progress.percent('Updating files:  50% (28/56)', 'checkout'),
      progress.percent('Receiving objects: 100% (9/9), done.', 'fetch'),
      progress.percent("fatal: repository 'x' not found", 'clone'),
      progress.percent('remote: Enumerating objects: 1967, done.', 'clone'),
      progress.percent('Updating files:  50% (28/56)', 'clone'),
    },
    { 2, 10, 35, 40, 72, 100, 50, 85, nil, nil, nil },
    "each phase as its share of the plugin's work, by what git runs"
  )

  -- The reader: records split anywhere across chunks, by \r or \n.
  alpha.activity, alpha.percent = 'installing', nil
  local handler, said = progress.reader(alpha, 'clone')
  handler(nil, "Cloning into 'alpha.nvim'...\nremote: Enumerating objects: 9, done.        \nremote: Count")
  handler(nil, 'ing objects: 100% (9/9), done.        \nReceiving objects:  50% (4/9)\rReceiv')
  H.eq(alpha.percent, 22, 'its percent moves as git reports')
  handler(nil, 'ing objects: 100% (9/9), done.\nwarning: something real\nremote: Total 9 (delta 0)\n')
  handler(nil, 'Receiving objects:  10% (1/9)\r')
  H.eq(alpha.percent, 35, 'and only forward')
  handler(nil, 'fatal: the end')
  handler(nil, nil)
  H.eq(said(), 'warning: something real\nfatal: the end\n', 'stderr keeps what git said, not how it went')

  local fetch_handler, fetch_said = progress.reader(alpha, 'fetch')
  fetch_handler(nil, 'From file:///repos/alpha\n * [new tag]         v1.0       -> v1.0\n')
  fetch_handler(nil, '   1a2b3c4..5d6e7f8  main       -> origin/main\nFetching submodule lib\n')
  fetch_handler(nil, nil)
  H.eq(fetch_said(), '', "and drops a fetch's refs, which --quiet would have kept back")

  alpha.activity, alpha.percent = nil, nil
  progress.set(alpha, 40)
  H.eq(alpha.percent, nil, 'no percent while it does no disk work')
  local state = require('cinch.state')
  state.activity(alpha, 'checking')
  progress.set(alpha, 40)
  H.eq(alpha.percent, 40, 'a percent while it does')
  state.activity(alpha, 'building')
  H.eq(alpha.percent, nil, 'and a new activity starts with none')
  state.activity(alpha, nil)

  -- watch(): a stand-in for vim.system, the way vim.pack calls it.
  local system = vim.system
  local calls = {}
  local function fake(cmd, opts, on_exit)
    calls[#calls + 1] = { cmd = cmd, opts = opts, percent = alpha.percent }
    if opts and type(opts.stderr) == 'function' then
      opts.stderr(nil, 'Receiving objects:  50% (1/2)\rReceiving objects: 100% (2/2), done.\n')
      opts.stderr(nil, "Cloning into 'alpha.nvim'...\n")
      opts.stderr(nil, nil)
    end
    if on_exit then
      on_exit({ code = 0, signal = 0, stdout = '', stderr = 'unseen' })
    end
  end
  vim.system = fake
  local restore = progress.watch()
  state.activity(alpha, 'installing')
  local path = vim.fs.joinpath(require('cinch.pack').dir, 'alpha.nvim')
  local got = {}
  local clone = { 'git', '-c', 'gc.auto=0', 'clone', '--quiet', '--no-checkout', '--origin', 'origin', 'url', path }
  vim.system(clone, { text = true }, function(out)
    got.clone = out.stderr
    got.after_clone = alpha.percent
  end)
  H.eq(
    calls[1].cmd,
    { 'git', '-c', 'gc.auto=0', 'clone', '--progress', '--no-checkout', '--origin', 'origin', 'url', path },
    'a clone reports, without --quiet, which hides the download'
  )
  H.eq(clone[5], '--quiet', "vim.pack's own command is left as it was")
  H.eq({ got.clone, got.after_clone }, { '', 35 }, 'vim.pack gets what git said with --quiet, and the row the percent')
  vim.system({ 'git', '-c', 'gc.auto=0', 'checkout', '--quiet', 'abc123' }, { cwd = path }, function(out)
    got.checkout = out.stderr
  end)
  H.eq(
    calls[2].cmd,
    { 'git', '-c', 'gc.auto=0', 'checkout', '--progress', '--quiet', 'abc123' },
    "a checkout reports, and keeps --quiet, which hides git's advice"
  )
  H.eq(
    { calls[2].percent, got.checkout, alpha.percent },
    { 45, '', 100 },
    'its checkout starts past the clone, and once it ends well, the plugin is done'
  )
  local rev_list = { 'git', '-c', 'gc.auto=0', 'rev-list', '-1', 'HEAD' }
  vim.system(rev_list, { cwd = path }, function() end)
  local other = { 'git', 'clone', '--quiet', 'url', '/elsewhere/not-a-plugin' }
  vim.system(other, {}, function() end)
  H.eq(
    { calls[3].cmd == rev_list, calls[3].opts.stderr, calls[4].cmd == other },
    { true, nil, true },
    'any other command, or one for no plugin, goes through untouched'
  )
  restore()
  H.eq(vim.system == fake, true, 'restore puts back what was there')
  vim.system = system
  state.activity(alpha, nil)

  -- A row with disk work under way shows how far it is.
  local rows = require('cinch.features.ui.rows')
  alpha.activity, alpha.percent = 'checking', 5
  local text = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, rows.meter(alpha)))
  H.eq(text, '5% ' .. ('━'):rep(16), 'the percent, then the meter')
  alpha.activity, alpha.percent = nil, nil
end)
