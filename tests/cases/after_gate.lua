-- source_after: a plugin without after/ never globs after/plugin/, one with it
-- does, once, and its files run once.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

require('cinch').setup({
  confirm = false,
  spec = { { { H.src('alpha.nvim'), cmd = 'AlphaCmd' }, { H.src('delta.nvim'), cmd = 'DeltaGo' } } },
})

H.after_startup(function()
  local cinch = require('cinch')
  local globbed = {}
  local glob = vim.fn.glob
  vim.fn.glob = function(pat, ...)
    globbed[#globbed + 1] = pat
    return glob(pat, ...)
  end
  cinch.load('delta.nvim')
  cinch.load('alpha.nvim')
  vim.fn.glob = glob

  ---@param p cinch.Plugin
  ---@return integer
  local function after_globs(p)
    return #vim
      .iter(globbed)
      :filter(function(pat)
        return pat:find(p.path .. '/after/plugin/', 1, true) ~= nil
      end)
      :totable()
  end
  H.eq(after_globs(H.plugin('delta.nvim')), 0, 'no after/ in delta: no glob for it')
  H.eq(after_globs(H.plugin('alpha.nvim')), 1, 'alpha has after/: globbed once')
  H.eq(vim.g.alpha_after, 1, 'and its after/plugin/ ran once')
end)
