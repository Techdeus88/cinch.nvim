-- phases: 2
-- :Cinch sync and s: install what is missing, offer to delete what no spec names, then
-- check for updates. It never applies one. Phase 1 installs; phase 2 drops gamma.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

---@return boolean whether the window asks about gamma on its row
local function asks()
  local w = require('cinch.features.ui').windows()
  local lines = w.list and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w.list), 0, -1, false) or {}
  return table.concat(lines, '\n'):find('Delete gamma Yes (y) or No (n)', 1, true) ~= nil
end

local alpha_src, alpha_dir = H.own('alpha.nvim')
local spec = { { alpha_src }, { H.src('beta.nvim'), cmd = 'BetaGo' } }
if H.phase == 1 then
  spec[#spec + 1] = { H.src('gamma') }
end
cinch.setup({ confirm = false, spec = { spec } })

local function on_disk(name)
  return vim.uv.fs_stat(vim.fs.joinpath(require('cinch.pack').dir, name)) ~= nil
end

H.after_startup(function()
  if H.phase == 1 then
    H.eq(on_disk('gamma'), true, 'installed')
    return
  end
  local u = require('cinch.features.updates')
  local order = {}
  for _, name in ipairs({ 'Installing', 'Deleting', 'Checking' }) do
    require('cinch.events').on(name, function()
      order[#order + 1] = name
    end)
  end
  local function idle()
    H.wait(function()
      return not u.checking
    end, 'the check')
  end
  idle()

  cinch.del({ 'beta.nvim' }, { force = true })
  H.commit(alpha_dir, 'feat: newer')
  local before = require('cinch.pack').rev(H.plugin('alpha.nvim'))
  order = {}
  vim.cmd('Cinch sync')
  H.eq(on_disk('beta.nvim'), true, 'what is missing installs')
  H.eq(asks(), true, 'it asks before deleting, on the row')
  H.eq(order, { 'Installing' }, 'and the check waits for the answer')
  H.press('n')
  idle()
  H.eq(on_disk('gamma'), true, 'saying no keeps it')
  H.eq(order, { 'Installing', 'Checking' }, 'install, then check')
  H.eq(H.noted('Checked 2 plugins in [%d.]+m?s · 1 update'), true, 'and says what the check found')
  H.eq(require('cinch.pack').rev(H.plugin('alpha.nvim')), before, 'without applying it')

  order = {}
  vim.cmd('Cinch')
  H.press('s')
  H.press('y')
  idle()
  H.eq(on_disk('gamma'), false, 's deletes it once you say yes')
  H.eq(order, { 'Deleting', 'Checking' }, 'nothing to install, then delete, then check')
  H.eq(on_disk('alpha.nvim') and on_disk('beta.nvim'), true, 'what your specs list stays')
end)
