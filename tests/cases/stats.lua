-- phases: 2
-- features/stats.lua: counts, phases, load times, the start time, and history kept across sessions.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').now(function() end)
require('cinch').setup({
  confirm = false,
  spec = {
    {
      { H.src('early'), load = 'now', init = function() end },
      { H.src('beta.nvim'), config = function() end },
      { H.src('alpha.nvim'), cmd = 'AlphaCmd' },
    },
  },
})
require('cinch').later(function() end)

H.after_startup(function()
  local stats = require('cinch.features.stats')
  local s = stats.summary()
  H.eq(s.plugins.total, 3, 'plugins counted')
  H.eq(s.by_when, { now = 1, later = 1, trigger = 1 }, 'by when')
  H.eq(s.loaded_by, { now = 1, later = 1 }, 'by what loaded them')
  for _, phase in ipairs({ 'specs', 'install', 'init', 'now' }) do
    H.eq(type(stats.phases[phase]), 'number', 'phase ' .. phase)
  end
  H.eq(stats.marks.vimenter > 0 and stats.marks.later >= stats.marks.vimenter, true, 'VimEnter, then later done')
  H.eq(stats.source, 'os', 'start time from the OS')
  H.eq(type(stats.plugins.early.packadd), 'number', 'per-plugin times')
  vim.cmd('Cinch stats')

  -- The profile: spans nested by time, the top level in groups.
  ---@param nodes cinch.stats.Node[]
  ---@param name string
  ---@return cinch.stats.Node
  local function find(nodes, name)
    for _, n in ipairs(nodes) do
      if n.name == name or n.label == name then
        return n
      end
    end
    error(('no `%s` in %s'):format(
      name,
      vim.inspect(vim.tbl_map(function(n)
        return n.label
      end, nodes))
    ))
  end
  local tree = stats.profile()
  local now = find(tree, 'now')
  H.eq(now.kind, 'group', 'now: a group of its own, like later')
  H.eq(find(now.children, 'early').reason, 'now', 'holding the now plugins')
  H.eq(find(now.children, 'now stats.lua:5').kind, 'run', 'and the now functions')
  H.eq(tree[1].name == 'cinch' and tree[2].name == 'now', true, 'after cinch, in the order they ran')
  H.eq(
    vim.tbl_contains(
      vim.tbl_map(function(n)
        return n.name
      end, find(tree, 'cinch').children),
      'now'
    ),
    false,
    'and no longer under cinch'
  )
  local startup_files = find(tree, 'plugin files at startup').children
  H.eq(find(find(startup_files, 'early').children, 'plugin/early.lua').kind, 'file', 'its plugin/ file under its name')
  H.eq(find(startup_files, 'runtime').kind, 'owner', "Neovim's own plugin files under runtime")
  local beta = find(find(tree, 'later').children, 'beta.nvim')
  local packadd = find(beta.children, 'packadd')
  H.eq(packadd.kind, 'step', 'a plugin holds the steps of its load')
  H.eq(find(packadd.children, 'plugin/beta.lua').kind, 'file', 'packadd holds the files it sourced')
  H.eq(find(beta.children, 'config').kind, 'step', 'then its config')
  H.eq(beta.ms >= packadd.ms, true, 'and the plugin took at least as long as its steps')
  H.eq(find(find(tree, 'cinch').children, 'init').children[1].label, 'init early', 'init hooks under the init phase')
  H.eq(find(find(tree, 'later').children, 'later stats.lua:16').kind, 'run', 'a later function, by where it is')

  local spans = #stats.spans
  local tmp = vim.fn.tempname() .. '.lua'
  vim.fn.writefile({ 'vim.g.sourced_late = 1' }, tmp)
  vim.cmd.source(tmp)
  H.eq(#stats.spans, spans, 'a file sourced after startup, with no plugin loading, is not kept')
  vim.cmd('AlphaCmd')
  local alpha = find(find(stats.profile(), 'after startup').children, 'alpha.nvim')
  H.eq(alpha.reason, 'cmd AlphaCmd', 'a trigger load after startup')
  H.eq(find(find(alpha.children, 'packadd').children, 'plugin/alpha.lua').kind, 'file', 'with the files it sourced')
  H.eq(
    vim.tbl_contains(
      vim.tbl_map(function(n)
        return n.name
      end, stats.profile()),
      'functions'
    ),
    false,
    'no functions unless asked for'
  )

  local history = stats.history()
  if H.phase == 1 then
    H.eq(#history, 0, 'no history in the first session')
  else
    H.eq(#history, 1, 'the first session was saved at exit')
    H.eq(history[1].plugins, 3, 'with its plugin count')
    H.eq(type(history[1].startup), 'number', 'and startup time')
  end
end)
