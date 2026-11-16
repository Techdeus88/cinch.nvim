-- phases: 2
-- :Cinch sync and s: install what is missing, offer to delete what no spec names, then
-- check for updates. It never applies one. Phase 1 installs; phase 2 drops gamma.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch = require('cinch')

---@param question? string default: deleting gamma
---@return boolean whether the window asks it on the plugin's row
local function asks(question)
  local w = require('cinch.features.ui').windows()
  local lines = w.list and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w.list), 0, -1, false) or {}
  return table.concat(lines, '\n'):find((question or 'Delete gamma') .. ' Yes (y) or No (n)', 1, true) ~= nil
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
  -- Installed without asking; the rows ask from here on.
  cinch.opts.confirm = true
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
  -- Opening the window checks once on its own; the sync's own check comes after.
  vim.cmd('Cinch')
  idle()
  order = {}
  vim.cmd('Cinch sync')
  H.eq({ asks('Install beta.nvim'), asks() }, { true, false }, 'it asks before installing, one question at a time')
  H.press('y')
  H.eq(on_disk('beta.nvim'), true, 'what is missing installs')
  H.eq(asks(), true, 'then it asks before deleting, on the row')
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
  H.eq(asks(), true, 's asks too')
  H.press('n')
  idle()
  H.eq(on_disk('gamma'), true, 'and no keeps it')

  -- With confirm off, s deletes without asking.
  cinch.opts.confirm = false
  order = {}
  H.press('s')
  idle()
  H.eq({ asks(), on_disk('gamma') }, { false, false }, 'with confirm off, s deletes without asking')
  H.eq(order, { 'Deleting', 'Checking' }, 'nothing to install, then delete, then check')
  H.eq(on_disk('alpha.nvim') and on_disk('beta.nvim'), true, 'what your specs list stays')
end)
