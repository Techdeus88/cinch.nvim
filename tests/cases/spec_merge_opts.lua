-- opts functions across merged specs: each gets the opts merged so far, what it returns
-- merges in, and tables build the base first. Your own tables stay as written.
local H = dofile(vim.env.CINCH_ROOT .. '/tests/helpers.lua')

local function noop() end
local shared = { list = { 1 }, nested = { x = 1 } }
local order = {}

require('cinch').setup({
  confirm = false,
  spec = {
    {
      -- Table, then a function that fills in what it is given.
      { H.src('alpha.nvim'), load = 'now', config = noop, opts = { a = 1, nested = { x = 1 } } },
      {
        H.src('alpha.nvim'),
        opts = function(_, opts)
          opts.b = 2
          opts.nested.y = 2
        end,
      },
      -- Table, then a function that returns a table of its own.
      { H.src('beta.nvim'), load = 'now', config = noop, opts = { a = 1 } },
      {
        H.src('beta.nvim'),
        opts = function(_, opts)
          return { seen = opts.a, b = 2 }
        end,
      },
      -- A function, then a table over what it made.
      {
        H.src('delta.nvim'),
        load = 'now',
        config = noop,
        opts = function()
          return { a = 1, nested = { x = 1, y = 1 } }
        end,
      },
      { H.src('delta.nvim'), opts = { nested = { y = 2 } } },
      -- Three functions run in the order declared, each seeing the last.
      {
        H.src('modly'),
        load = 'now',
        config = noop,
        opts = function(p, opts)
          order[#order + 1] = 'first'
          opts.name = p.name
        end,
      },
      {
        H.src('modly'),
        opts = function(_, opts)
          order[#order + 1] = 'second'
          opts.count = 1
        end,
      },
      {
        H.src('modly'),
        opts = function(_, opts)
          order[#order + 1] = 'third'
          opts.count = opts.count + 1
        end,
      },
      -- A shared table that a function changes.
      { H.src('twomods'), load = 'now', config = noop, opts = shared },
      {
        H.src('twomods'),
        opts = function(_, opts)
          table.insert(opts.list, 2)
          opts.nested.x = 2
        end,
      },
      -- One function alone gets an empty table, as ever.
      {
        H.src('gamma'),
        load = 'now',
        config = noop,
        opts = function(_, opts)
          vim.g.gamma_given = vim.tbl_count(opts)
          opts.only = true
        end,
      },
      -- Read first and nested in `deps`, it still extends the own spec read after it.
      {
        H.src('oncy'),
        load = 'now',
        deps = {
          {
            H.src('vimmy'),
            deps = { H.src('opy') },
            opts = function(_, opts)
              table.insert(opts.sources.default, 'copilot')
              opts.sources.providers.copilot = { module = 'copilot' }
              return opts
            end,
          },
        },
      },
      {
        H.src('vimmy'),
        config = noop,
        deps = { H.src('early') },
        opts = function()
          return { sources = { default = { 'lsp' }, providers = { lsp = {} } } }
        end,
      },
      -- Top-level and read first, a function that takes opts still extends what comes after.
      {
        H.src('opy'),
        config = noop,
        opts = function(_, opts)
          table.insert(opts.sources.default, 'copilot')
          opts.shared = 'function'
          return opts
        end,
      },
      {
        H.src('opy'),
        opts = function()
          return { sources = { default = { 'lsp' } }, shared = 'base' }
        end,
      },
      { H.src('opy'), opts = { shared = 'table', extra = true } },
      -- An extender ahead of a table.
      {
        H.src('early'),
        config = noop,
        opts = function(_, opts)
          opts.sum = opts.a + 1
        end,
      },
      { H.src('early'), opts = { a = 1 } },
      -- A function with no opts argument adds to the table before it.
      { H.src('dup-first'), load = 'now', config = noop, opts = { a = 1 } },
      {
        H.src('dup-first'),
        opts = function()
          return { b = 2 }
        end,
      },
      -- A list in a returned table replaces, like any later list.
      { H.src('dup-second'), load = 'now', config = noop, opts = { list = { 1, 2 }, keep = true } },
      {
        H.src('dup-second'),
        opts = function(_, _)
          return { list = { 3 } }
        end,
      },
      -- Returning the table it was given keeps it as it is: a key it removed stays
      -- removed, and an object inside keeps its metatable.
      {
        H.src('builder'),
        load = 'now',
        config = noop,
        opts = { gone = true, keep = true, object = setmetatable({ v = 1 }, { __index = {} }) },
      },
      {
        H.src('builder'),
        opts = function(_, opts)
          opts.gone = nil
          return opts
        end,
      },
      -- A new table that leaves a key out does not remove it.
      { H.src('colory'), load = 'now', config = noop, opts = { a = 1 } },
      {
        H.src('colory'),
        opts = function(_, _)
          return { b = 2 }
        end,
      },
      -- A function that raises fails the plugin, whichever spec it came from.
      { H.src('cmdy'), load = 'now', config = noop, opts = { a = 1 } },
      {
        H.src('cmdy'),
        opts = function()
          error('opts boom')
        end,
      },
    },
  },
})

H.after_startup(function()
  H.eq(H.plugin('alpha.nvim').opts_used, { a = 1, b = 2, nested = { x = 1, y = 2 } }, 'a function fills in the table')
  H.eq(H.plugin('beta.nvim').opts_used, { a = 1, seen = 1, b = 2 }, 'a table a function returns merges in')
  H.eq(H.plugin('dup-first').opts_used, { a = 1, b = 2 }, 'from a function with no opts argument too')
  H.eq(H.plugin('dup-second').opts_used, { list = { 3 }, keep = true }, 'a list in a returned table replaces')
  H.eq(H.plugin('builder').opts_used.gone, nil, 'a key set to nil on opts is gone')
  H.eq(getmetatable(H.plugin('builder').opts_used.object) ~= nil, true, 'and returning opts keeps objects whole')
  H.eq(H.plugin('colory').opts_used, { a = 1, b = 2 }, 'a smaller table returned removes nothing')
  H.eq(H.plugin('delta.nvim').opts_used, { a = 1, nested = { x = 1, y = 2 } }, 'a table merges over a function')

  H.eq(H.plugin('modly').opts_used, { name = 'modly', count = 2 }, 'each function sees the one before it')
  H.eq(order, { 'first', 'second', 'third' }, 'in the order declared')

  H.eq(H.plugin('twomods').opts_used, { list = { 1, 2 }, nested = { x = 2 } }, 'a function can change nested values')
  H.eq(shared, { list = { 1 }, nested = { x = 1 } }, 'without changing your table')

  H.eq(vim.g.gamma_given, 0, 'a single function still gets an empty table')
  H.eq(H.plugin('gamma').opts_used, { only = true }, 'and its result')

  H.eq(
    H.plugin('vimmy').opts_used,
    { sources = { default = { 'lsp', 'copilot' }, providers = { lsp = {}, copilot = { module = 'copilot' } } } },
    'a nested spec extends the own spec read after it'
  )
  H.eq(H.plugin('vimmy').deps, { 'opy', 'early' }, 'deps from both')
  H.eq(
    { H.plugin('opy').state, H.plugin('early').state, H.plugin('vimmy').state },
    { 'loaded', 'loaded', 'loaded' },
    'and every one of them loads'
  )

  H.eq(
    H.plugin('opy').opts_used,
    { sources = { default = { 'lsp', 'copilot' } }, shared = 'function', extra = true },
    'base first, in order, then functions that take opts'
  )
  H.eq(H.plugin('early').opts_used, { a = 1, sum = 2 }, 'a table read after an extender is still its base')

  H.eq(H.plugin('cmdy').state, 'failed', 'a function that raises fails the plugin')
  H.eq(H.noted('opts boom'), true, 'and is reported')
end)
