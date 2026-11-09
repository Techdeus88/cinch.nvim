-- phases: 2
-- Deleting plugins: cinch.del, :Cinch del and clean, and d in the window, both on
-- a plugin your specs list and on one left on disk that no spec names any more.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local api = vim.api
local phase = tonumber(vim.env.CINCH_PHASE)

local specs = { { H.src('alpha.nvim') }, { H.src('beta.nvim') } }
if phase == 1 then
  -- Installed now; phase 2 drops them from the specs.
  vim.list_extend(specs, { { H.src('gamma') }, { H.src('delta.nvim') }, { H.src('early') }, { H.src('cmdy') } })
end
require('cinch').setup({ confirm = false, spec = { specs } })

---@param name string
---@return boolean
local function on_disk(name)
  return vim.uv.fs_stat(vim.fs.joinpath(require('cinch.pack').dir, name)) ~= nil
end

---@return string[]
local function list_lines()
  local w = require('cinch.features.ui').windows()
  return api.nvim_buf_get_lines(api.nvim_win_get_buf(w.list), 0, -1, false)
end

---@param pat string
local function go(pat)
  local w = require('cinch.features.ui').windows()
  for i, l in ipairs(list_lines()) do
    if l:find(pat) then
      api.nvim_win_set_cursor(w.list, { i, 0 })
      api.nvim_exec_autocmds('CursorMoved', { buffer = api.nvim_win_get_buf(w.list) })
      return
    end
  end
  error('no line matches ' .. pat)
end

local answer = 1
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.confirm = function()
  return answer
end

H.after_startup(function()
  if phase == 1 then
    H.eq(on_disk('gamma') and on_disk('delta.nvim'), true, 'installed')
    return
  end
  local pack = require('cinch.pack')
  local orphans = vim.tbl_map(function(o)
    return o.name
  end, pack.orphans())
  table.sort(orphans)
  H.eq(orphans, { 'cmdy', 'delta.nvim', 'early', 'gamma' }, 'on disk and in no spec')

  -- In your specs: vim.pack keeps it unless forced, and cinch says why.
  local beta = H.plugin('beta.nvim')
  vim.cmd('Cinch del beta.nvim')
  H.eq(on_disk('beta.nvim'), true, 'a plugin in your specs stays without !')
  H.eq(H.noted('not deleted: beta%.nvim is in your specs'), true, 'and cinch says why')
  H.eq(beta.activity, nil, 'it is not left "deleting"')

  vim.cmd('Cinch')
  H.eq(vim.list_contains(list_lines(), ' ▾ Updates (4)'), true, 'the window lists them under Updates')
  H.eq(vim.list_contains(list_lines(), ' · cmdy not in specs'), true, 'each saying it is not in specs')

  -- Several at once: select them, then d.
  local w = require('cinch.features.ui').windows()
  go(' · early ')
  H.press('<S-CR>')
  local marked = vim
    .iter(api.nvim_buf_get_extmarks(api.nvim_win_get_buf(w.list), -1, 0, -1, { details = true }))
    :filter(function(m)
      return m[4].line_hl_group == 'CinchMarked'
    end)
    :totable()
  H.eq(#marked, 1, '<S-CR> shades the row it selects')
  go(' · cmdy ')
  H.press('<Space>')
  local footer = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, api.nvim_win_get_config(w.frame).footer))
  H.eq(footer:find('2 selected', 1, true) ~= nil, true, 'the footer counts the selection')
  H.press('d')
  H.eq({ on_disk('early'), on_disk('cmdy') }, { false, false }, 'd deletes every selected plugin')
  H.eq(on_disk('gamma'), true, 'and only those')
  go(' · gamma ')
  H.press('d')
  H.eq(on_disk('gamma'), false, 'd deletes one')
  H.eq(table.concat(list_lines(), '\n'):find(' · gamma ', 1, true), nil, 'and its row goes')

  go(' beta%.nvim ')
  answer = 2
  H.press('d')
  H.eq(on_disk('beta.nvim'), true, 'd asks first; no keeps it')
  answer = 1
  H.press('d')
  H.eq(on_disk('beta.nvim'), false, 'yes deletes a plugin in your specs too')
  H.eq(beta.deleted, true, 'which is marked deleted')
  local row = list_lines()[vim.fn.match(list_lines(), ' beta\\.nvim ') + 1]
  H.eq(row:find('deleted from disk', 1, true) ~= nil, true, 'and its row says so')
  local pane = api.nvim_buf_get_lines(api.nvim_win_get_buf(require('cinch.features.ui').windows().pane), 0, -1, false)
  H.eq(
    table.concat(pane, '\n'):find('installs again on the next start', 1, true) ~= nil,
    true,
    'the pane, what comes next'
  )

  vim.cmd('Cinch clean')
  H.eq(on_disk('delta.nvim'), false, ':Cinch clean deletes the rest')
  H.wait(function()
    return table.concat(list_lines(), '\n'):find('not in specs', 1, true) == nil
  end, 'the section to go')
  vim.cmd('Cinch clean')
  H.eq(H.noted('nothing to clean'), true, 'then there is nothing to clean')
  H.eq(on_disk('alpha.nvim'), true, 'what your specs list is left alone')
end)
