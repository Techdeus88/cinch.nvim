-- stats = { profile = 'functions' } shares LuaJIT's one debug hook: a debugger's or a
-- coverage tool's, set while the profiler runs, is not cleared when it stops, and one
-- already set when a plugin loads is not replaced.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local theirs = function() end

require('cinch').setup({
  confirm = false,
  stats = { profile = 'functions' },
  spec = {
    {
      {
        H.src('beta.nvim'),
        config = function()
          -- A debugger attaching in the middle of startup.
          debug.sethook(theirs, '', 1e9)
        end,
      },
      { H.src('alpha.nvim'), cmd = 'AlphaCmd' },
    },
  },
})

H.after_startup(function()
  H.eq(debug.gethook(), theirs, 'a hook set during startup stays once the profiler stops')
  H.eq(H.noted('functions are not profiled'), false, 'nothing to say yet')

  vim.cmd('AlphaCmd')
  H.eq(H.plugin('alpha.nvim').state, 'loaded', 'a plugin loads with it set')
  local fn, mask, count = debug.gethook()
  H.eq({ fn, mask, count }, { theirs, '', 1e9 }, 'and the hook is still theirs, as they set it')
  H.eq(H.noted('functions are not profiled: another debug hook is set'), true, 'which is reported')
  debug.sethook()
end)
