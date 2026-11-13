-- phases: 2
-- pack.lua builds: shell, function, async function and :Cmd builds; a load waits for a
-- running build without blocking; a failed build runs again on the next start.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local events = require('cinch.events')
-- Shell builds run with sh on Unix, whatever 'shell' is.
if vim.fn.has('win32') == 0 then
  vim.o.shell = '/no/such/shell'
end
-- The function build hides the plugin from vim.loader's cache too.
vim.loader.enable()

-- Nothing about a build reaches the command line: its row shows it.
local echoed = {}
local echo = vim.api.nvim_echo
---@diagnostic disable-next-line: duplicate-set-field
vim.api.nvim_echo = function(chunks, history, opts)
  for _, c in ipairs(chunks) do
    echoed[#echoed + 1] = c[1]
  end
  return echo(chunks, history, opts)
end

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
        module = false,
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
      {
        H.src('delta.nvim'),
        cmd = 'DeltaGo',
        -- Colored, then a progress counter on one line, the way build tools print.
        build = [[printf '\033[32mstep one\033[0m\n' && sleep 0.5 && printf '50%%\r100%%\n' && touch made]],
      },
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
  H.wait(function()
    return #(delta.build_log or {}) > 0
  end, 'its first line of output')
  H.eq(delta.build_log, { 'step one' }, 'its output streams in as it runs, without colors')
  local plugins = require('cinch.features.ui.plugins')
  local ctx = { folded = {}, tick = 0, info = {}, spec_lines = {} }
  local row = vim.iter(plugins.list(120, ctx).lines):find(function(l) ---@param l string
    return l:find(' delta%.nvim ') ~= nil
  end)
  H.eq(vim.endswith(row, 'step one'), true, 'the row shows the newest line')
  H.eq(require('cinch').load('delta.nvim'), nil, 'load returns at once')
  H.eq(delta.state, 'pending', 'and waits for the build')
  H.wait(function()
    return delta.state == 'loaded'
  end, 'delta to load after its build')
  H.eq(vim.g.made_at_load, true, 'the build had finished when it loaded')
  H.eq(delta.build_log, { 'step one', '50%', '100%' }, 'a carriage return ends a line too')
  local pane = table.concat(plugins.pane('delta.nvim', 80, ctx).lines, '\n')
  H.eq(pane:find('output +step one\n +50%%\n +100%%') ~= nil, true, 'the pane keeps the last build output')
  local waited = vim.tbl_filter(function(l)
    return l.msg == 'manual: delta.nvim waits for its build'
  end, require('cinch.features.messages').log)
  H.eq(#waited, 1, 'the wait is in the log')

  local alpha = H.plugin('alpha.nvim')
  H.wait(function()
    return vim.uv.fs_stat(alpha.path .. '/built.txt') ~= nil and alpha.activity == nil
  end, 'the shell build')
  H.eq(vim.uv.fs_stat(alpha.path .. '/.git/cinch-build'), nil, 'a build that worked is unmarked')
  local build_node
  for _, g in ipairs(require('cinch.features.stats').profile()) do
    for _, n in ipairs(g.name == 'builds and vim.pack' and g.children or {}) do
      build_node = build_node or (n.name == 'build alpha.nvim' and n)
    end
  end
  H.eq(build_node and build_node.kind, 'build', 'the build is in Profile, with builds and vim.pack')

  local builder = H.plugin('builder')
  H.eq({ vim.g.builder_saw, vim.g.builder_made }, { true, true }, 'a function build can require the plugin')
  H.eq(builder.state, 'pending', 'without loading it')
  H.eq(vim.g.builder_plugin, nil, 'its plugin/ did not run')
  H.eq(package.loaded['builder'], nil, 'and its modules are forgotten')
  H.eq(pcall(require, 'builder'), false, 'and vim.loader does not find them either')

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

  local ui = require('cinch.features.ui')
  H.wait(ui.is_open, 'the failed build to open the window')
  local function row_of(name)
    return vim.iter(plugins.list(120, ctx).lines):find(function(l) ---@param l string
      return l:find(' ' .. vim.pesc(name) .. ' ') ~= nil
    end) or ''
  end
  H.eq(row_of('gamma'):find('build failed: exit 3', 1, true) ~= nil, true, 'its row says the build failed')

  require('cinch').build({ 'alpha.nvim' })
  H.wait(function()
    return row_of('alpha.nvim'):find('built in %d') ~= nil
  end, 'the row to say how long the build took')
  H.eq(row_of('gamma'):find('build failed', 1, true) ~= nil, true, 'a failure stays on its row')
  H.wait(function()
    return row_of('alpha.nvim'):find('built in', 1, true) == nil
  end, 'a build that worked to leave the row', 6000)

  -- vim.pack's install progress names the plugin it just cloned, `builder` among them.
  local said = table.concat(echoed, '\n')
  local quiet = said:gsub('builder', '')
  H.eq({ quiet:find('build', 1, true), quiet:find('built', 1, true) }, {}, 'no build reached the command line')

  ui.close()
  events.report('a note for later')
  vim.wait(50)
  H.eq({ ui.is_open(), said == table.concat(echoed, '\n') }, { false, true }, 'information waits, silently')
  ui.open()
  H.eq(H.header()[2]:find('a note for later', 1, true) ~= nil, true, 'in the header of the next open')
end)
