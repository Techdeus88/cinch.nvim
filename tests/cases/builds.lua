-- phases: 2
-- pack.lua builds: shell, function, async function and :Cmd builds; a load waits for a
-- running build without blocking; a failed build runs again on the next start.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local events = require('cinch.events')

local built = {}
events.on('Build', function(d)
  built[#built + 1] = d.plugin.name .. (d.ok and '' or ' failed')
end)
events.on('Load', function(d)
  if d.plugin.name == 'delta.nvim' then
    vim.g.made_at_load = vim.uv.fs_stat(d.plugin.path .. '/made') ~= nil
  elseif d.plugin.name == 'beta.nvim' then
    vim.g.async_at_load = vim.g.async_done
  end
end)

require('cinch').setup({
  confirm = false,
  spec = {
    {
      { H.src('alpha.nvim'), build = 'echo shell-out && touch built.txt' },
      {
        H.src('builder'),
        cmd = 'BuilderGo',
        build = function()
          vim.g.builder_saw = require('builder') ~= nil
          require('builder').make()
        end,
      },
      {
        H.src('beta.nvim'),
        build = function(_, done)
          vim.defer_fn(function()
            vim.g.async_done = true
            done(true)
          end, 100)
        end,
      },
      { H.src('cmdy'), cmd = 'CmdyGo', build = ':CmdyBuild' },
      { H.src('delta.nvim'), cmd = 'DeltaGo', build = 'sleep 0.5 && touch made' },
      { H.src('gamma'), build = 'exit 3' },
    },
  },
})

H.after_startup(function()
  local gamma = H.plugin('gamma')
  if H.phase == 2 then
    H.wait(function()
      return #built > 0
    end, 'the failed build to run again')
    vim.wait(100)
    H.eq(built, { 'gamma failed' }, 'only the build that failed last time runs again')
    H.eq(vim.uv.fs_stat(gamma.path .. '/.git/cinch-build') ~= nil, true, 'and stays marked')
    return
  end

  local delta = H.plugin('delta.nvim')
  H.eq(delta.activity, 'building', 'delta is still building')
  H.eq(require('cinch').load('delta.nvim'), nil, 'load returns at once')
  H.eq(delta.state, 'pending', 'and waits for the build')
  H.wait(function()
    return delta.state == 'loaded'
  end, 'delta to load after its build')
  H.eq(vim.g.made_at_load, true, 'the build had finished when it loaded')
  local waited = vim.tbl_filter(function(l)
    return l.msg == 'manual: delta.nvim waits for its build'
  end, require('cinch.features.messages').log)
  H.eq(#waited, 1, 'the wait is in the log')

  local alpha = H.plugin('alpha.nvim')
  H.wait(function()
    return vim.uv.fs_stat(alpha.path .. '/built.txt') ~= nil and alpha.activity == nil
  end, 'the shell build')
  H.eq(vim.uv.fs_stat(alpha.path .. '/.git/cinch-build'), nil, 'a build that worked is unmarked')

  local builder = H.plugin('builder')
  H.eq({ vim.g.builder_saw, vim.g.builder_made }, { true, true }, 'a function build can require the plugin')
  H.eq(builder.state, 'pending', 'without loading it')
  H.eq(vim.g.builder_plugin, nil, 'its plugin/ did not run')
  H.eq(package.loaded['builder'], nil, 'and its modules are forgotten')

  H.wait(function()
    return H.plugin('beta.nvim').state == 'loaded'
  end, 'beta')
  H.eq(vim.g.async_at_load, true, 'a later plugin waits for its async build')

  H.wait(function()
    return vim.g.cmdy_built == true
  end, 'the :Cmd build')
  H.eq(H.plugin('cmdy').reason, 'build', 'a :Cmd build loads its plugin first')

  H.wait(function()
    return vim.tbl_contains(built, 'gamma failed')
  end, 'gamma build')
  H.eq(H.noted('build of `gamma` failed'), true, 'a failed build is reported')
  H.eq(vim.uv.fs_stat(gamma.path .. '/.git/cinch-build') ~= nil, true, 'and stays marked')
end)
