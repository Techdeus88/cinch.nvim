-- phases: 2
-- features/stats.lua: counts, phases, load times, the start time, and history kept across sessions.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = { { { H.src('early'), load = 'now' }, { H.src('beta.nvim') }, { H.src('alpha.nvim'), cmd = 'AlphaCmd' } } },
})

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
  H.eq(stats.source, jit.os == 'Windows' and 'cpu' or 'os', 'start time from the OS')
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
  local now = find(find(tree, 'cinch').children, 'now')
  H.eq(find(now.children, 'early').reason, 'now', 'a now plugin under the now phase')
  local startup_files = find(tree, 'plugin files at startup').children
  H.eq(find(find(startup_files, 'early').children, 'plugin/early.lua').kind, 'file', 'its plugin/ file under its name')
  H.eq(find(startup_files, 'runtime').kind, 'owner', "Neovim's own plugin files under runtime")
  local beta = find(find(tree, 'later').children, 'beta.nvim')
  H.eq(find(beta.children, 'plugin/beta.lua').kind, 'file', 'a later plugin holds the files it sourced')
  H.eq(beta.ms >= beta.children[1].ms, true, 'and took at least as long as they did')

  local spans = #stats.spans
  local tmp = vim.fn.tempname() .. '.lua'
  vim.fn.writefile({ 'vim.g.sourced_late = 1' }, tmp)
  vim.cmd.source(tmp)
  H.eq(#stats.spans, spans, 'a file sourced after startup, with no plugin loading, is not kept')
  vim.cmd('AlphaCmd')
  local alpha = find(find(stats.profile(), 'after startup').children, 'alpha.nvim')
  H.eq(alpha.reason, 'cmd AlphaCmd', 'a trigger load after startup')
  H.eq(find(alpha.children, 'plugin/alpha.lua').kind, 'file', 'with the files it sourced')

  local history = stats.history()
  if H.phase == 1 then
    H.eq(#history, 0, 'no history in the first session')
  else
    H.eq(#history, 1, 'the first session was saved at exit')
    H.eq(history[1].plugins, 3, 'with its plugin count')
    H.eq(type(history[1].startup), 'number', 'and startup time')
  end
end)
