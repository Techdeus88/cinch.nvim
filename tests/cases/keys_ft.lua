-- A key with `ft`, as in lazy.nvim, maps only in buffers of those filetypes: its stub
-- and, once the plugin loads, the mapping the spec defines. Elsewhere the key is untouched.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local api = vim.api

-- A buffer-local mapping of yours on the same key, made before cinch's stub.
api.nvim_create_autocmd('FileType', {
  pattern = 'lua',
  callback = function(ev)
    vim.keymap.set('n', 'gY', function()
      vim.g.yours = (vim.g.yours or 0) + 1
    end, { buffer = ev.buf })
  end,
})

require('cinch').setup({
  confirm = false,
  spec = {
    {
      {
        H.src('alpha.nvim'),
        keys = {
          {
            'gZ',
            function()
              vim.g.hit = vim.bo.filetype
            end,
            ft = 'lua',
            desc = 'lua only',
          },
        },
      },
      -- No rhs: only a trigger, in Lua buffers.
      { H.src('beta.nvim'), keys = { { 'gY', ft = { 'lua' } } } },
    },
  },
})

---@param ft string
---@return integer buf
local function open(ft)
  -- A new buffer each time: :enew would reuse an empty one.
  local buf = api.nvim_create_buf(true, false)
  api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = ft
  return buf
end

H.after_startup(function()
  local alpha, beta = H.plugin('alpha.nvim'), H.plugin('beta.nvim')
  H.eq(vim.fn.maparg('gZ', 'n'), '', 'no global mapping')

  open('text')
  H.eq(vim.fn.maparg('gZ', 'n'), '', 'none in a text buffer')
  H.press('gZ')
  H.eq(alpha.state, 'pending', 'and the key there loads nothing')
  H.eq(vim.g.hit, nil, 'nor runs the mapping')

  open('lua')
  local stub = vim.fn.maparg('gZ', 'n', false, true)
  H.eq({ stub.buffer, stub.desc }, { 1, 'lua only' }, 'a Lua buffer gets a buffer-local stub')
  H.press('gZ')
  H.eq(alpha.state, 'loaded', 'pressing it loads the plugin')
  H.eq(vim.g.hit, 'lua', 'and runs the mapping the spec defines')

  local again = open('lua')
  local map = vim.fn.maparg('gZ', 'n', false, true)
  H.eq(map.buffer, 1, 'a Lua buffer opened after the load gets the mapping, buffer-local')
  vim.g.hit = nil
  H.press('gZ')
  H.eq(vim.g.hit, 'lua', 'and it works')
  open('text')
  H.eq(vim.fn.maparg('gZ', 'n'), '', 'a text buffer still has none')

  -- The stub sat on top of your buffer-local mapping; it comes back when the stub goes.
  api.nvim_set_current_buf(again)
  H.eq(vim.fn.maparg('gY', 'n', false, true).desc, 'cinch: load beta.nvim', 'the stub replaced yours')
  H.press('gY')
  H.eq(beta.state, 'loaded', 'pressing it loads the plugin')
  H.eq(vim.g.yours, 1, 'and replays the key onto your mapping, which is back')
  H.eq(vim.fn.maparg('gY', 'n', false, true).desc, nil, 'yours, not a stub')

  -- A plugin added while a Lua buffer is open maps there at once.
  require('cinch').add({
    {
      H.src('gamma'),
      keys = {
        {
          'gW',
          function()
            vim.g.w = true
          end,
          ft = 'lua',
        },
      },
    },
  })
  H.eq(vim.fn.maparg('gW', 'n', false, true).buffer, 1, 'the open Lua buffer gets the stub')
  H.press('gW')
  H.eq({ H.plugin('gamma').state, vim.g.w }, { 'loaded', true }, 'which loads it and runs the mapping')
end)
