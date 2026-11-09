-- A plugin only ever named as a dependency turns off with the plugins that need it, however
-- deep. One with its own spec, or needed by a plugin that is on, stays on. A later add() brings it back.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

cinch.setup({
  confirm = false,
  spec = {
    {
      -- Off, with a dependency that has one of its own.
      { H.src('alpha.nvim'), enabled = false, deps = { { H.src('beta.nvim'), deps = { H.src('gamma') } } } },
      -- Off with cond, sharing a dependency with a plugin that is on.
      {
        H.src('delta.nvim'),
        cond = function()
          return false
        end,
        deps = { H.src('dup-first') },
      },
      { H.src('modly'), load = 'now', deps = { H.src('dup-first') } },
      -- Off, with a dependency that has a spec of its own.
      { H.src('twomods'), cond = false, deps = { 'early' } },
      { H.src('early') },
      -- On for now: add() turns it off below, and its dependency with it.
      { H.src('cmdy'), cmd = 'CmdyGo', deps = { { H.src('oncy'), cmd = 'OncyGo' } } },
    },
  },
})

local function on_disk(name)
  return vim.uv.fs_stat(vim.fs.joinpath(require('cinch.pack').dir, name)) ~= nil
end

H.after_startup(function()
  local beta, gamma = H.plugin('beta.nvim'), H.plugin('gamma')
  H.eq({ beta.state, beta.reason }, { 'disabled', 'unneeded' }, 'its dependency is off')
  H.eq({ gamma.state, gamma.reason }, { 'disabled', 'unneeded' }, 'and that one is too')
  H.eq({ on_disk('beta.nvim'), on_disk('gamma') }, { false, false }, 'neither is installed')
  H.eq(H.plugin('alpha.nvim').reason, 'enabled', 'the plugin keeps its own reason')

  H.eq(H.plugin('dup-first').state, 'loaded', 'a dependency a plugin that is on needs stays on')
  H.eq(H.plugin('modly').state, 'loaded', 'and that plugin loads')
  H.eq(H.plugin('early').state, 'loaded', 'a dependency with its own spec stays on')

  local rows = require('cinch.features.ui.rows')
  H.eq(rows.off_reason(beta), nil, 'no message of its own')
  H.eq(rows.off_reason(H.plugin('alpha.nvim')), 'enabled = false', 'the plugin that is off keeps its')
  local list = require('cinch.features.ui.plugins').list(100, { folded = {}, tick = 0, info = {}, spec_lines = {} })
  local dep = ' ' .. rows.glyph('dep') .. ' dep  alpha.nvim'
  local row = vim.tbl_filter(function(l)
    return l:find(' beta.nvim ', 1, true) ~= nil
  end, list.lines)[1]
  H.eq(row, ' ✕ beta.nvim ' .. dep, 'its row: an X, the name, the dep chip, the plugin that needs it')
  H.eq(table.concat(list.lines, '\n'):find('only plugins', 1, true), nil, 'and no message')
  local pane =
    require('cinch.features.ui.plugins').pane('beta.nvim', 100, { folded = {}, tick = 0, info = {}, spec_lines = {} })
  H.eq(table.concat(pane.lines, '\n'):find('dep  alpha.nvim', 1, true) ~= nil, true, 'the pane shows the same chip')
  local logged = vim.tbl_filter(function(l)
    return l.msg:find('beta.nvim is off', 1, true) ~= nil
  end, require('cinch.features.messages').log)
  H.eq(#logged, 0, 'and the log adds no line for it')

  local ok, err = pcall(require, 'beta')
  H.eq(ok, false, 'require() does not load it')
  H.eq(err:find("`beta.nvim` provides 'beta' but is disabled", 1, true) ~= nil, true, err)

  -- A pending plugin turned off takes its pending dependency with it.
  local oncy = H.plugin('oncy')
  H.eq(oncy.state, 'pending', 'on while cmdy is on')
  H.eq(vim.api.nvim_get_commands({}).OncyGo ~= nil, true, 'with its stub')
  cinch.add({ { H.src('cmdy'), enabled = false } }, { confirm = false })
  H.eq({ H.plugin('cmdy').state, oncy.state }, { 'disabled', 'disabled' }, 'both go off')
  H.eq(vim.api.nvim_get_commands({}).OncyGo, nil, 'and the stub goes')

  -- A plugin that needs them brings them back, however deep.
  local added = cinch.add({ { H.src('vimmy'), load = 'now', deps = { H.src('beta.nvim') } } }, { confirm = false })
  H.eq(#added, 1, 'one new record')
  H.wait(function()
    return beta.state == 'loaded' and gamma.state == 'loaded'
  end, 'the dependencies to come back')
  H.eq({ on_disk('beta.nvim'), on_disk('gamma') }, { true, true }, 'installed now')
  H.eq(H.plugin('vimmy').state, 'loaded', 'and the plugin needing them loads')
  H.eq(H.plugin('alpha.nvim').state, 'disabled', 'the plugin that was off stays off')
  H.eq(H.noted('dependency'), false, 'nothing failed for a missing dependency')
end)
