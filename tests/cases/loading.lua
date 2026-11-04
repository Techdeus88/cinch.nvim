-- loader.lua: opts, config, after, the main module, failures, deps and LoadPre.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')
local cinch, events = require('cinch'), require('cinch.events')

local loads, errors = 0, {}
vim.api.nvim_create_autocmd('User', {
  pattern = 'CinchLoad',
  callback = function()
    loads = loads + 1
  end,
})
events.on('LoadError', function(d)
  errors[#errors + 1] = d.plugin.name
end)
events.on('LoadPre', function(d)
  if d.plugin.name == 'gamma' then
    d.cancel, d.cancel_reason = true, 'vetoed'
  end
end)

cinch.setup({
  confirm = false,
  spec = {
    {
      { H.src('alpha.nvim'), opts = { x = 1 } },
      {
        H.src('beta.nvim'),
        load = 'now',
        opts = function(p, o)
          o.filled = p.name
        end,
        config = function(_, o)
          vim.g.beta_cfg = o.filled
        end,
        after = function(p)
          vim.g.beta_after = p.state
        end,
      },
      { H.src('twomods'), opts = {} },
      { src = (H.own('twomods')), name = 'twomods-main', main = 'one', opts = {} },
      { H.src('broken.nvim'), opts = {} },
      { H.src('delta.nvim'), cmd = 'DeltaGo', deps = { H.src('early') } },
      { H.src('gamma'), cmd = 'GammaX' },
    },
  },
})

H.after_startup(function()
  local alpha = H.plugin('alpha.nvim')
  H.eq(vim.g.alpha_opts, { x = 1 }, 'opts go to require(main).setup()')
  H.eq({ alpha.main_used, alpha.opts_used }, { 'alpha', { x = 1 } }, 'and are recorded')
  H.eq(vim.g.beta_cfg, 'beta.nvim', 'opts as a function fills the table it gets, config receives it')
  H.eq(vim.g.beta_after, 'loading', 'after runs as part of the load')

  local two = H.plugin('twomods')
  H.eq(two.state, 'failed', 'two modules and no main')
  H.eq(two.err:find('one, two', 1, true) ~= nil, true, 'names the candidates')
  H.eq(H.plugin('twomods-main').main_used, 'one', 'main picks one')

  local broken = H.plugin('broken.nvim')
  H.eq({ broken.state, broken.failed_in }, { 'failed', 'load' }, 'setup() that raises')
  H.eq(errors, { 'twomods', 'broken.nvim' }, 'LoadError for each')

  cinch.load('delta.nvim')
  H.eq(H.plugin('early').reason, 'dep of delta.nvim', 'deps load first')
  H.eq(H.plugin('early').order < H.plugin('delta.nvim').order, true, 'in order')
  H.eq(H.plugin('delta.nvim').reason, 'manual', 'cinch.load is manual')

  cinch.load('gamma')
  H.eq(H.plugin('gamma').state, 'pending', 'LoadPre can cancel a load')
  H.eq(H.noted('`gamma` not loaded: vetoed'), true, 'and says why')
  H.eq(loads, 5, 'User CinchLoad for every load')
end)
