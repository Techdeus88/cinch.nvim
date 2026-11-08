-- Usage: nvim -l tests/run.lua [case-name-filter]
-- Each case runs in its own headless Neovim with isolated XDG dirs, using its file as init.lua.
-- A first line `-- phases: N` runs the case N times over the same dirs (CINCH_PHASE=1..N),
-- to test what carries over from one session to the next. A line `-- args: files` in the
-- header opens those files, as if passed on the command line.
-- Modeled on wrappack's runner.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local tmp = vim.fn.tempname()

-- Local git repos the cases install from: no network, and every run starts the same.
---@type table<string, table<string, string>>
local fixtures = {
  ['alpha.nvim'] = {
    ['lua/alpha/init.lua'] = 'return { setup = function(o) vim.g.alpha_opts = o end }',
    ['plugin/alpha.lua'] = [[
vim.g.alpha_plugin = (vim.g.alpha_plugin or 0) + 1
vim.api.nvim_create_user_command('AlphaCmd', function(a)
  vim.g.alpha_cmd = { args = a.args, bang = a.bang, range = a.range }
end, { nargs = '*', bang = true, range = true })]],
    ['after/plugin/alpha.lua'] = 'vim.g.alpha_after = (vim.g.alpha_after or 0) + 1',
    ['README.md'] = '# alpha',
  },
  ['beta.nvim'] = {
    ['lua/beta.lua'] = 'vim.g.beta_required = (vim.g.beta_required or 0) + 1 return { v = 1 }',
    ['plugin/beta.lua'] = "vim.g.beta_order = (vim.g.beta_order or '') .. 'beta '",
  },
  ['gamma'] = {
    ['plugin/gamma.lua'] = [[
local g = vim.api.nvim_create_augroup('gamma', {})
vim.api.nvim_create_autocmd('BufReadPost', { group = g, callback = function()
  vim.g.gamma_saw = (vim.g.gamma_saw or 0) + 1
end })
vim.api.nvim_create_autocmd('User', { group = g, pattern = 'GammaGo', callback = function(ev)
  vim.g.gamma_user = (vim.g.gamma_user or 0) + 1
end })]],
    ['ftplugin/cnc.lua'] = 'vim.b.gamma_ft = true',
  },
  -- Vimscript that calls a script-local function from its FileType autocmd, the
  -- way markdown-preview.nvim does.
  ['vimmy'] = {
    ['plugin/vimmy.vim'] = [[
augroup vimmy
  autocmd!
  autocmd FileType * if &filetype ==# 'cnc' | call s:init() | endif
augroup END
function! s:init() abort
  let b:vimmy = get(b:, 'vimmy', 0) + 1
endfunction]],
  },
  -- A `once` autocmd on the event that loads it.
  ['oncy'] = {
    ['plugin/oncy.lua'] = [[
vim.api.nvim_create_autocmd('User', { pattern = 'OncyGo', once = true, callback = function()
  vim.g.oncy = (vim.g.oncy or 0) + 1
end })]],
  },
  -- An operator-pending mapping: L moves to the end of the line.
  ['opy'] = {
    ['plugin/opy.lua'] = "vim.keymap.set('o', 'L', '$')",
  },
  ['delta.nvim'] = {
    ['lua/delta.lua'] = 'return { hit = function() vim.g.delta_hit = (vim.g.delta_hit or 0) + 1 end }',
    ['plugin/delta.lua'] = "vim.keymap.set('n', 'gD', function() vim.g.delta_own = (vim.g.delta_own or 0) + 1 end)",
  },
  ['early'] = {
    ['plugin/early.lua'] = [[
vim.g.early_did_enter = vim.v.vim_did_enter
vim.g.beta_order = (vim.g.beta_order or '') .. 'early ']],
  },
  ['broken.nvim'] = {
    ['lua/broken.lua'] = "return { setup = function() error('boom') end }",
  },
  ['twomods'] = {
    ['lua/one.lua'] = 'return { setup = function() end }',
    ['lua/two.lua'] = 'return {}',
  },
  ['cmdy'] = {
    ['plugin/cmdy.lua'] = "vim.api.nvim_create_user_command('CmdyBuild', function() vim.g.cmdy_built = true end, {})",
  },
  -- Opens a buffer in the current window as it loads, like a dashboard.
  ['dashy'] = {
    ['plugin/dashy.lua'] = "vim.cmd('enew') vim.b.dashy = true",
  },
  -- Opens a float and focuses it as it loads, like a picker or an input prompt.
  ['floaty'] = {
    ['plugin/floaty.lua'] = [[
vim.g.floaty_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true,
  { relative = 'editor', row = 1, col = 1, width = 20, height = 3 })]],
  },
  ['colory'] = {
    ['colors/colory.lua'] = "vim.g.colors_name = 'colory'",
  },
  ['builder'] = {
    ['lua/builder.lua'] = 'return { make = function() vim.g.builder_made = true end }',
    ['plugin/builder.lua'] = 'vim.g.builder_plugin = true',
  },
  -- Modules with no setup of their own, for loading by require().
  ['modly'] = {
    ['lua/modly/init.lua'] = "vim.g.modly_runs = (vim.g.modly_runs or 0) + 1 return { name = 'modly' }",
    ['lua/modly/sub.lua'] = "return { name = 'sub' }",
    ['plugin/modly.lua'] = 'vim.g.modly_plugin = (vim.g.modly_plugin or 0) + 1',
  },
  -- Two plugins that provide one module.
  ['dup-first'] = { ['lua/dupmod.lua'] = "return { from = 'first' }" },
  ['dup-second'] = { ['lua/dupmod.lua'] = "return { from = 'second' }" },
}

local function sh(cmd, cwd)
  local r = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(r.code == 0, table.concat(cmd, ' ') .. '\n' .. (r.stderr or ''))
end

for name, files in pairs(fixtures) do
  local dir = vim.fs.joinpath(tmp, 'fixtures', name)
  for path, content in pairs(files) do
    local file = vim.fs.joinpath(dir, path)
    vim.fn.mkdir(vim.fs.dirname(file), 'p')
    vim.fn.writefile(vim.split(content, '\n'), file)
  end
  sh({ 'git', 'init', '-q', '-b', 'main' }, dir)
  sh({ 'git', 'add', '-A' }, dir)
  -- No signing: your own git config may sign every commit, which needs a key.
  sh({ 'git', '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'init' }, dir)
end

local filter = _G.arg[1]
local cases = vim.fn.glob(vim.fs.joinpath(root, 'tests', 'cases', '*.lua'), false, true)
local failed = 0

for _, case in ipairs(cases) do
  local name = vim.fn.fnamemodify(case, ':t:r')
  if not filter or name:find(filter, 1, true) then
    local phases = tonumber(io.lines(case)():match('^%-%- phases: (%d+)')) or 1
    local home = vim.fs.joinpath(tmp, 'cases', name)
    -- A line `-- args: a.md b.lua` near the top opens those files, under the case's home.
    local args = {}
    for line in io.lines(case) do
      if not line:find('^%-%-') then
        break
      end
      for word in (line:match('^%-%- args: (.*)') or ''):gmatch('%S+') do
        args[#args + 1] = vim.fs.joinpath(home, word)
      end
    end
    vim.fn.mkdir(vim.fs.joinpath(home, 'config', 'nvim', 'lua'), 'p')
    local env = {
      CINCH_ROOT = root,
      CINCH_FIXTURES = vim.fs.joinpath(tmp, 'fixtures'),
      CINCH_HOME = home,
      XDG_CONFIG_HOME = vim.fs.joinpath(home, 'config'),
      XDG_DATA_HOME = vim.fs.joinpath(home, 'data'),
      XDG_STATE_HOME = vim.fs.joinpath(home, 'state'),
      XDG_CACHE_HOME = vim.fs.joinpath(home, 'cache'),
    }
    local ok, out = true, ''
    for phase = 1, phases do
      env.CINCH_PHASE = tostring(phase)
      local cmd = vim.list_extend({ 'nvim', '--headless', '-i', 'NONE', '-u', case }, args)
      local r = vim.system(cmd, { env = env, text = true, timeout = 30000 }):wait()
      if r.code ~= 0 or not (r.stdout or ''):find('cinch: case done', 1, true) then
        local why = r.code ~= 0 and ('exit ' .. r.code) or 'exited before its checks ran'
        ok, out = false, ('phase %d %s\n%s%s'):format(phase, why, r.stdout or '', r.stderr or '')
        break
      end
    end
    io.stdout:write(('%s %s\n'):format(ok and 'PASS' or 'FAIL', name))
    if not ok then
      failed = failed + 1
      io.stdout:write(out, '\n')
    end
  end
end

io.stdout:write(failed == 0 and 'all passed\n' or ('%d failed\n'):format(failed))
os.exit(failed == 0 and 0 or 1)
