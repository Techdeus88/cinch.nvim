-- Shared by every case: put cinch on the runtimepath, catch what it reports,
-- and run the case's checks once startup is done. Modeled on wrappack's helpers.

local H = {}

H.root = assert(vim.env.CINCH_ROOT)
H.home = vim.env.CINCH_HOME
H.phase = tonumber(vim.env.CINCH_PHASE)
vim.opt.rtp:prepend(H.root)

---@type { msg: string, level: integer? }[] everything cinch reported, and every vim.notify
H.notes = {}
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level)
  H.notes[#H.notes + 1] = { msg = tostring(msg), level = level }
end
--- Stop listening to Report, so reports fall back to vim.notify as without features.
H.unreport = require('cinch.events').on('Report', function(d)
  H.notes[#H.notes + 1] = { msg = d.msg, level = d.level }
end, { priority = 1 })

--- A fixture repo as a src.
---@param name string
---@return string
function H.src(name)
  return 'file://' .. vim.fs.joinpath(vim.env.CINCH_FIXTURES, name)
end

--- A copy of a fixture that only this case uses, so it can add commits to it.
---@param name string
---@return string src, string dir
function H.own(name)
  local dir = vim.fs.joinpath(H.home, 'repos', name)
  if not vim.uv.fs_stat(dir) then
    vim.fn.mkdir(vim.fs.dirname(dir), 'p')
    H.sh({ 'git', 'clone', '-q', vim.fs.joinpath(vim.env.CINCH_FIXTURES, name), dir })
  end
  return 'file://' .. dir, dir
end

--- Run a command; raise when it fails.
---@param cmd string[]
---@param cwd? string
---@return string stdout
function H.sh(cmd, cwd)
  local r = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(r.code == 0, table.concat(cmd, ' ') .. '\n' .. (r.stderr or ''))
  return vim.trim(r.stdout or '')
end

--- Add an empty commit to a repo.
---@param dir string
---@param msg string
function H.commit(dir, msg)
  H.sh({
    'git',
    '-c',
    'user.name=t',
    '-c',
    'user.email=t@t',
    '-c',
    'commit.gpgsign=false',
    'commit',
    '-q',
    '--allow-empty',
    '-m',
    msg,
  }, dir)
end

function H.eq(actual, expected, what)
  if not vim.deep_equal(actual, expected) then
    error(('%s: expected %s, got %s'):format(what or 'value', vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

--- Whether anything noted matches `pattern`.
---@param pattern string
---@return boolean
function H.noted(pattern)
  for _, n in ipairs(H.notes) do
    if n.msg:find(pattern) then
      return true
    end
  end
  return false
end

---@param name string
---@return cinch.Plugin
function H.plugin(name)
  return require('cinch.state').plugins[name]
end

--- Wait until `cond` holds, or fail after `ms`.
---@param cond fun(): boolean
---@param what string
---@param ms? integer
function H.wait(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 10) then
    error('timed out waiting for ' .. what, 2)
  end
end

--- Type keys as the user would, then let scheduled redraws run.
---@param keys string
function H.press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), 'xt', false)
  vim.wait(30)
end

--- Write `lines` to `path`; relative paths are under the config dir.
function H.write(path, lines)
  if not path:find('^/') then
    path = vim.fs.joinpath(vim.fn.stdpath('config') --[[@as string]], path)
  end
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end

--- Run `fn` once startup is done, then exit 0, or 1 with the error on stderr.
function H.after_startup(fn)
  vim.api.nvim_create_autocmd('VimEnter', {
    once = true,
    callback = function()
      -- Twice, so the `later` queue that starts on VimEnter has drained.
      vim.schedule(function()
        vim.schedule(function()
          local ok, err = xpcall(fn, debug.traceback)
          if ok then
            -- The runner passes a case only with this line, so one that exits
            -- early without running its checks fails.
            io.stdout:write('cinch: case done\n')
            vim.cmd('qa!')
          else
            io.stderr:write(err, '\n', 'notes: ', vim.inspect(H.notes), '\n')
            vim.cmd('cq 1')
          end
        end)
      end)
    end,
  })
end

return H
