-- The first start in the window. On Installing the window opens in its install
-- phase; each Progress turns a plugin's row to installed; the colorscheme applies
-- as soon as its plugin is on disk; on Installed the outcome shows, then the same
-- rows settle into the Plugins view. ui/init.lua listens for these events from
-- startup and loads this file the first time one of them fires.

local state = require('cinch.state')

local M = {}

---@class cinch.ui.InstallHost what the first start needs from the window
---@field ui table its state: ctx, colors_done
---@field opts cinch.ui.Opts
---@field open fun(view?: string)
---@field is_open fun(): boolean
---@field render fun()
---@field redraw fun()
---@field animate fun()
---@field focus fun(to: 'editor'|'list')

---@param path string a plugin's folder
---@param name string
---@return boolean
local function ships_colors(path, name)
  -- Not glob(): on Windows `{vim,lua}` only expands in a pattern that also has `*?[`.
  local base = vim.fs.joinpath(path, 'colors', name)
  return vim.uv.fs_stat(base .. '.lua') ~= nil or vim.uv.fs_stat(base .. '.vim') ~= nil
end

--- Apply `opts.colorscheme` once a plugin that ships it is on disk: on the
--- runtimepath at once, so the rest of the install already shows in your colors.
---@param w cinch.ui.InstallHost
function M.colorscheme(w)
  local ui, name = w.ui, w.opts.colorscheme
  if not name or ui.colors_done or vim.g.colors_name then
    return
  end
  local dir = require('cinch.pack').dir
  for _, p in ipairs(state.list) do
    local status = ui.ctx.install and ui.ctx.install.status[p.name]
    local path = p.path or vim.fs.joinpath(dir, p.name)
    if status ~= 'cloning' and ships_colors(path, name) then
      pcall(vim.cmd.packadd, { vim.fn.escape(p.name, ' '), bang = true })
      ui.colors_done = pcall(vim.cmd.colorscheme, name)
      return
    end
  end
end

---@param w cinch.ui.InstallHost
---@param d { names: string[] }
function M.installing(w, d)
  -- Only once Neovim has started: an install during init.lua has no screen to draw
  -- on, and the message feature shows its progress instead.
  if vim.v.vim_did_enter == 0 then
    return
  end
  local install = { total = #d.names, done = 0, status = {} }
  for _, name in ipairs(d.names) do
    install.status[name] = 'cloning'
  end
  w.ui.ctx.install = install
  M.colorscheme(w)
  if w.opts.open_on_install ~= false then
    w.open('plugins')
    -- On screen before vim.pack.add holds the loop.
    vim.cmd.redraw()
  end
end

---@param w cinch.ui.InstallHost
---@param d { title: string, name?: string, done?: integer, handled?: boolean }
function M.progress(w, d)
  local install = w.ui.ctx.install
  if not (install and d.title:find('^Installing')) then
    return
  end
  install.current = d.name or install.current
  if d.name and install.status[d.name] == 'cloning' then
    install.status[d.name] = 'installed'
    install.done = install.done + 1
    M.colorscheme(w)
  end
  -- The window shows it, so the command line does not.
  d.handled = w.is_open()
  w.redraw()
end

---@param w cinch.ui.InstallHost
---@param d { names: string[], failed: string[], ms: number }
function M.installed(w, d)
  local install = w.ui.ctx.install
  if not install then
    return
  end
  for _, name in ipairs(d.names) do
    install.status[name] = vim.list_contains(d.failed, name) and 'failed' or 'installed'
  end
  install.done = install.total
  install.message = ('Installed %d of %d plugin%s in %s%s'):format(
    #d.names - #d.failed,
    #d.names,
    #d.names == 1 and '' or 's',
    require('cinch.features.ui.canvas').ms(d.ms),
    #d.failed > 0 and (' · ' .. #d.failed .. ' failed') or ''
  )
  w.render()
  -- Plugins load next. Give focus back to your editor first, so one that opens a
  -- buffer or a window as it loads (a dashboard, say) does it there.
  w.focus('editor')
  local editor = vim.api.nvim_get_current_win()
  -- A moment to read it, then the same rows settle into the Plugins view.
  vim.defer_fn(function()
    w.ui.ctx.install = nil
    M.colorscheme(w)
    w.render()
    w.animate()
    -- Back to the list, unless a plugin moved focus somewhere else meanwhile.
    if w.is_open() and vim.api.nvim_get_current_win() == editor then
      w.focus('list')
    end
  end, 1200)
end

return M
