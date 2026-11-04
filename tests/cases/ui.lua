-- features/ui: the float, its sizes, views, the spec subview and the action keys.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local api = vim.api

local beta_src, beta_dir = H.own('beta.nvim')
require('cinch').setup({
  confirm = false,
  spec = {
    { { H.src('alpha.nvim'), opts = { style = 'night' } }, { beta_src }, { H.src('delta.nvim'), cmd = 'DeltaGo' } },
  },
})

---@param pat string
---@return integer?
local function line_of(pat)
  for i, l in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find(pat) then
      return i
    end
  end
end

local function size()
  local c = api.nvim_win_get_config(0)
  return c.relative ~= '' and { c.width, c.height } or 'closed'
end

H.after_startup(function()
  local events = require('cinch.events')
  H.eq(events.has('State'), false, 'nothing listens to State before the first open')
  H.commit(beta_dir, 'feat: from ui')

  vim.cmd('Cinch')
  local lines = vim.o.lines - vim.o.cmdheight
  H.eq(size(), { math.floor(vim.o.columns * 0.75), math.floor(lines * 0.75) }, ':Cinch opens a float at 75%')
  H.eq(events.has('State'), true, 'subscribed on open')
  local u = require('cinch.features.updates')
  H.eq(u.checking, true, 'opening starts a check')
  H.wait(function()
    return not u.checking
  end, 'the check')
  vim.wait(50)
  H.eq(
    api
      .nvim_buf_get_lines(0, assert(line_of(' beta%.nvim ')) - 1, assert(line_of(' beta%.nvim ')), false)[1]
      :find('↑1') ~= nil,
    true,
    'pending commits on the row'
  )

  H.press('=')
  H.eq(size(), { math.floor(vim.o.columns * 0.95), math.floor(lines * 0.95) }, '= stretches to 95%')
  H.press('=')
  H.eq(size()[1], math.floor(vim.o.columns * 0.75), '= again goes back')

  api.nvim_win_set_cursor(0, { line_of(' alpha%.nvim '), 0 })
  H.press('<CR>')
  H.eq(line_of('spec  as cinch read it') ~= nil, true, 'spec block')
  H.eq(line_of('vim.pack  what vim.pack knows') ~= nil, true, 'vim.pack block')
  H.eq(line_of("require%('alpha'%)%.setup%(%) called with") ~= nil, true, 'config block')
  H.eq(line_of('style = "night"') ~= nil, true, 'with the opts it received')

  api.nvim_win_set_cursor(0, { line_of('style = "night"'), 0 })
  H.press('u')
  H.eq(H.noted('no pending update for `alpha.nvim`'), true, 'a key inside the details acts on that plugin')

  api.nvim_win_set_cursor(0, { line_of(' delta%.nvim '), 0 })
  H.press('l')
  H.eq(H.plugin('delta.nvim').state, 'loaded', 'l loads')
  H.eq(api.nvim_get_current_line():find(' delta%.nvim ') ~= nil, true, 'the cursor follows the plugin')

  api.nvim_win_set_cursor(0, { line_of(' beta%.nvim '), 0 })
  H.press('u')
  H.eq(u.results['beta.nvim'], nil, 'u applies the update under the cursor')

  H.press('<Tab>')
  H.eq(line_of('^ when ') ~= nil, true, '<Tab> goes to stats')
  H.press('<Tab>')
  H.eq(line_of('^ %d%d:%d%d:%d%d ') ~= nil, true, 'then log')
  H.press('<Tab>')
  H.eq(line_of('^ loaded %(') ~= nil, true, 'then back to plugins')
  H.press('<S-Tab>')
  H.eq(line_of('^ loaded %(') == nil, true, '<S-Tab> goes back')

  H.press('q')
  H.eq(size(), 'closed', 'q closes')
  vim.cmd('Cinch open stats')
  H.eq(line_of('^ when ') ~= nil, true, ':Cinch open stats')
  H.press('Q')
  H.eq(size(), 'closed', 'Q closes')
end)
