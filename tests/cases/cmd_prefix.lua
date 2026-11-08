-- phases: 6
-- cmd_prefix names the user command. Phase 1: setup() before Neovim's plugin pass.
-- Phase 2: plugin/cinch.lua ran first, so the default is replaced. Phase 3: an invalid
-- name. Phase 4: a name already taken. Phase 5: the default. Phase 6: add() and no setup().
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')
local specs = { { H.src('alpha.nvim'), cmd = 'AlphaCmd' }, { H.src('beta.nvim') } }

local function exists(name)
  return vim.api.nvim_get_commands({})[name] ~= nil
end

local want = ({ 'Pack', 'Pack2', 'Cinch', 'Cinch', 'Cinch', 'Cinch' })[H.phase]

if H.phase == 2 then
  vim.cmd.runtime('plugin/cinch.lua')
  H.eq(exists('Cinch'), true, 'the plugin file made the default')
elseif H.phase == 4 then
  vim.api.nvim_create_user_command('Taken', function()
    vim.g.taken_ran = true
  end, {})
end

if H.phase == 6 then
  cinch.add(specs, { confirm = false })
else
  local prefix = ({ 'Pack', 'Pack2', 'not-valid', 'Taken', nil })[H.phase]
  cinch.setup({ confirm = false, cmd_prefix = prefix, spec = { specs } })
end

H.after_startup(function()
  H.eq(exists(want), true, ':' .. want .. ' exists')
  if want ~= 'Cinch' then
    H.eq(exists('Cinch'), false, 'and :Cinch does not')
  end

  H.eq(vim.fn.getcompletion(want .. ' load a', 'cmdline'), { 'alpha.nvim' }, 'completion works under the name')
  vim.cmd(want .. ' load alpha.nvim')
  H.eq(H.plugin('alpha.nvim').reason, 'manual', 'and subcommands run')
  vim.cmd(want .. '! update! beta.nvim')
  H.eq(H.noted('subcommands'), false, 'with bangs too')

  vim.cmd(want .. ' del')
  local usage = ('which plugins%%? `:%s del {name}`; `:%s clean` deletes'):format(want, want)
  H.eq(H.noted(usage), true, 'messages name it')

  if H.phase == 3 then
    H.eq(H.noted('cmd_prefix `not%-valid`: a user command starts with a capital'), true, 'a bad name warns')
  elseif H.phase == 4 then
    H.eq(H.noted('cmd_prefix `Taken`: that command already exists'), true, 'a taken name warns')
    vim.cmd('Taken')
    H.eq(vim.g.taken_ran, true, 'and the other command is left alone')
  else
    H.eq(H.noted('cmd_prefix'), false, 'a fine name does not warn')
  end
end)
