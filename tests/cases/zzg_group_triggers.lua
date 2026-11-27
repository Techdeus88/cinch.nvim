-- Group triggers, batch 1: follows, delay, root, lsp, visible, and together. Each is set
-- on a group, so its plugins get it; one is set on a plugin, which works the same.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
vim.opt.rtp:prepend(assert(vim.env.CINCH_GROUPS_ROOT))

local proj = vim.fs.joinpath(H.home, 'proj')
H.write(vim.fs.joinpath(proj, 'rootmark.txt'), { '' })
H.write(vim.fs.joinpath(proj, 'sub', 'a.txt'), { 'a' })

require('cinch-groups').setup({
  confirm = false,
  features = { 'messages' },
  spec = {
    {
      { group = 'base', cmd = 'AlphaCmd', { H.src('alpha.nvim') } },
      { group = 'chain', follows = 'base', { H.src('beta.nvim') } },
      { group = 'proj', root = 'rootmark.txt', { H.src('gamma') } },
      { group = 'soon', delay = 50, { H.src('delta.nvim') } },
      { group = 'tools', lsp = 'fakels', { H.src('oncy') } },
      { group = 'pair', together = true, delay = 600000, { H.src('dup-first') }, { H.src('dup-second') } },
      { group = 'seen', visible = true, { H.src('opy') } },
      { H.src('vimmy'), follows = 'oncy' },
      { H.src('early'), delay = 'soon' },
    },
  },
})

H.after_startup(function()
  local function loaded(name)
    return H.plugin(name).state == 'loaded'
  end
  local function reason(name)
    return H.plugin(name).reason
  end
  H.eq(H.noted('unknown field'), false, 'cinch knows every trigger, and together is no plugin field')

  H.wait(function()
    return loaded('opy')
  end, 'visible to load opy', 2000)
  H.eq(reason('opy'), 'visible true', 'visible: once the first frame is drawn')

  H.wait(function()
    return loaded('delta.nvim')
  end, 'delay to load delta.nvim', 2000)
  H.eq(reason('delta.nvim'), 'delay 50', 'delay: ms after the UI is up')
  H.eq(H.noted('`delay = "soon"`: each value should be a number of ms'), true, 'a bad value warns')

  H.eq(H.plugin('beta.nvim').state, 'pending', 'follows: waits for its group')
  vim.cmd('AlphaCmd')
  H.wait(function()
    return loaded('beta.nvim')
  end, 'follows to load beta.nvim', 2000)
  H.eq(reason('beta.nvim'), 'follows base', 'and loads once that group has')

  H.eq(H.plugin('gamma').state, 'pending', 'root: waits for a file under its marker')
  vim.cmd.edit(vim.fs.joinpath(proj, 'sub', 'a.txt'))
  H.eq({ loaded('gamma'), reason('gamma') }, { true, 'root rootmark.txt' }, 'loads when one opens')
  H.eq(vim.g.gamma_saw, 1, 'and its own BufReadPost runs for that buffer')

  vim.lsp.start({
    name = 'fakels',
    root_dir = proj,
    cmd = function()
      return {
        request = function(method, _, callback)
          if method == 'initialize' then
            vim.schedule(function()
              callback(nil, { capabilities = {} })
            end)
          end
          return true, 1
        end,
        notify = function()
          return true
        end,
        is_closing = function()
          return false
        end,
        terminate = function() end,
      }
    end,
  })
  H.wait(function()
    return loaded('oncy')
  end, 'lsp to load oncy', 3000)
  H.eq(reason('oncy'), 'lsp fakels', 'lsp: when that server attaches')
  H.wait(function()
    return loaded('vimmy')
  end, 'follows to load vimmy', 2000)
  H.eq(reason('vimmy'), 'follows oncy', 'follows a plugin, set on the plugin itself')

  H.eq(H.plugin('dup-second').state, 'pending', 'together: waits like the rest')
  require('cinch').load({ 'dup-first' })
  H.wait(function()
    return loaded('dup-second')
  end, 'together to load dup-second', 2000)
  H.eq(reason('dup-second'), 'together pair with dup-first', 'one loading brings the group')
end)
