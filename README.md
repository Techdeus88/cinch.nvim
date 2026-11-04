# cinch.nvim

A plugin manager for Neovim, built on `vim.pack`.

`vim.pack` owns the disk: installing, the lockfile, updating and deleting. cinch owns the session. It decides when each plugin loads, runs builds, measures what everything costs, and shows it all in one window. Every spec is a `vim.pack.Spec`, so anything you write for cinch also works with `vim.pack.add`.

- **Four ways to load.** `now` loads during startup. `later` loads once the UI is up, a few plugins per tick. `now_if_args` is `now` when Neovim starts with a file and `later` when it doesn't. `trigger` loads on an event, a filetype, a command or a key.
- **One install batch.** Missing plugins go to a single `vim.pack.add` call, which clones them in parallel.
- **Builds that never block.** A shell build runs in the background. A plugin whose build is still running loads when the build ends, and a key or command that fired meanwhile is replayed after.
- **Your messages.** cinch shows `vim.pack`'s progress and errors as its own, without Lua stack noise, and keeps a log of everything.
- **Stats.** Startup time measured from when the process began, each phase of cinch's startup, every plugin's load time, and a history across sessions.
- **Update checks** fetch in the background and list each plugin's new commits. You apply them from the window.

## Requirements

- Neovim 0.13 or newer, which is a nightly build until it is released.
- `git` on your `PATH`.

## Install

Put this at the top of your `init.lua`:

```lua
vim.loader.enable()

local path = vim.fn.stdpath('data') .. '/site/pack/core/opt/cinch.nvim'
if not vim.uv.fs_stat(path) then
  local out = vim.fn.system({ 'git', 'clone', '--filter=blob:none', 'https://github.com/Techdeus88/cinch.nvim', path })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({ { 'Failed to clone cinch.nvim:\n', 'ErrorMsg' }, { out } }, true, {})
    return
  end
end
vim.cmd.packadd('cinch.nvim')

require('cinch').setup({ confirm = false })
```

cinch is cloned with `git` rather than installed with `vim.pack.add` for one reason. The first `vim.pack.add` of a session reads your lockfile and installs every plugin it lists that is missing on disk. That call should be cinch's, so the install carries your `confirm` setting and cinch shows its progress.

To keep cinch itself updated, add it to your specs like any other plugin: `{ 'Techdeus88/cinch.nvim', load = 'now' }`. `vim.pack` adopts the folder `git` cloned rather than cloning it again. The first time, it says once that it repaired the lock data for `cinch.nvim`. That is `vim.pack` adding it to your lockfile.

## Specs

By default cinch reads every file under `lua/plugins/`, in subfolders too, in alphabetical order. A file returns one spec or a list of them.

```lua
-- lua/plugins/editor.lua
return {
  { 'folke/tokyonight.nvim', load = 'now', config = function() vim.cmd.colorscheme('tokyonight') end },
  { 'nvim-telescope/telescope.nvim', cmd = 'Telescope', deps = { 'nvim-lua/plenary.nvim' }, opts = {} },
  { 'lewis6991/gitsigns.nvim', event = 'BufReadPre', opts = {} },
  { 'folke/which-key.nvim', opts = {} },
}
```

`owner/repo` expands to a GitHub URL. Any other `src` goes to `vim.pack` as it is.

cinch fields can sit at the top level, as above, or inside `data`, the way `vim.pack.Spec` holds extra fields. cinch moves top-level fields into `data` before anything else reads the spec, and when both places set a field, `data` wins. `vim.pack.add` only ever receives `src`, `name` and `version`.

### Fields

| Field | What it does |
| --- | --- |
| `[1]` or `src` | Where the plugin comes from |
| `name` | The plugin's name. Defaults to the last part of `src`, the same way `vim.pack` names it |
| `version` | A branch, tag, commit, or `vim.version.range()`. Passed to `vim.pack` unchanged |
| `commit`, `tag`, `branch` | Become `version`. When more than one is set, `commit` beats `tag`, which beats `version`, which beats `branch`, and the losers are named in a warning |
| `load` | `'now'`, `'later'`, `'now_if_args'` or `'trigger'`. See below |
| `event` | `'BufReadPost'`, or `'User MyEvent'` for an event with a pattern. A string or a list |
| `ft` | A filetype or a list of them |
| `cmd` | A command or a list of them |
| `keys` | `'<leader>f'`, or `{ '<leader>f', rhs, mode = 'n', desc = '...' }` for a mapping the spec defines, or a list of either |
| `deps` | Plugins that load before this one. `'owner/repo'` or a table is a spec. A bare name like `'plenary.nvim'` refers to a spec declared elsewhere. `dependencies` works too |
| `enabled`, `cond` | `false`, or a function returning `false`, turns the plugin off: it is not installed and never loads. A function that raises leaves the plugin on, with a warning |
| `init` | `function(plugin)`, run at every startup before the plugin loads |
| `build` | Runs after an install or an update. A shell command runs in the background from the plugin's folder. `':Cmd'` runs an Ex command once the plugin has loaded. `function(plugin)` runs with the plugin on the runtimepath but not loaded, and `function(plugin, done)` finishes when it calls `done(ok, msg)` |
| `opts` | A table, or `function(plugin, opts)` that returns one or fills in the table it is given |
| `main` | The module whose `setup()` gets `opts`. cinch guesses it from the plugin's name, or takes the only module in its `lua/` folder |
| `config` | `function(plugin, opts)`, run after the plugin loads, in place of `require(main).setup(opts)`. `config = true` calls `setup()` with no opts |
| `after` | `function(plugin)`, run after `config` |

A field cinch does not know gets a warning naming the spec file, and is ignored. That includes lazy.nvim's `lazy`: use `load` instead.

The `plugin` table your hooks receive has `name`, `src`, `version`, `load`, `path` and `rev`, the commit that is checked out.

### When a plugin loads

When `load` is not set:

| The spec has | It loads |
| --- | --- |
| A trigger: `event`, `ft`, `cmd`, `keys`, or a custom one | `trigger`: when one of them fires |
| Nothing, and it is only ever named as another plugin's dependency | `trigger`, with no triggers of its own: when the plugin that needs it loads |
| Anything else | `later` |

`event = 'VeryLazy'` from lazy.nvim means `later`.

An explicit `load` always wins. `load = 'now'` with a `cmd` loads at startup, and cinch warns that the `cmd` is ignored.

`now` plugins load while `init.lua` runs, in the order you declared them, dependencies first. Neovim then sources their `plugin/` files in its normal startup pass, so a `now` plugin's `config` runs before its own `plugin/` files. A plugin whose `config` needs something its `plugin/` file defines should use `later`.

## Setup

```lua
require('cinch').setup({
  spec = { 'plugins' },          -- module paths, folders, or specs; default lua/plugins/
  confirm = true,                -- ask before installing, with vim.pack's prompt
  budget = 5,                    -- ms of `later` loading per event-loop tick
  features = { 'messages', 'stats', 'updates', 'ui' },

  -- each feature's options, under its name
  messages = { level = vim.log.levels.INFO, progress = true, history = 200 },
  stats = { persist = true, history = 50 },
  updates = { fresh = 300 },     -- seconds before opening the window checks again
  ui = { size = 0.75, wide = 0.95, border = nil },
})
```

`require('cinch').add(specs)` takes the same list `vim.pack.add` does, with cinch fields allowed, and works without `setup()`.

## Commands

| Command | Does |
| --- | --- |
| `:Cinch` | Open the window |
| `:Cinch open [plugins\|stats\|log]` | Open it on a view |
| `:Cinch load {names}` | Load plugins now |
| `:Cinch build {names}` | Run their builds again |
| `:Cinch check [names]` | Check for updates in the background |
| `:Cinch update [names]` | Update with `vim.pack`'s review tab. `:Cinch update!` applies without it |
| `:Cinch stats` | Print this session's stats |

## The window

A float at 75% of the editor, centered.

| Key | Does |
| --- | --- |
| `<Tab>`, `<S-Tab>` | Next or previous view: plugins, stats, log |
| `=` | Switch between 75% and 95% of the editor |
| `<CR>` | Show the plugin's details: its error, its pending commits, and three tables: its spec as cinch read it, what `vim.pack` knows, and the opts and config it received |
| `l` | Load the plugin under the cursor |
| `b` | Run its build |
| `u` | Apply its pending update |
| `U` | Apply every pending update |
| `c` | Check for updates |
| `r` | Read what `vim.pack` knows again |
| `q`, `Q`, `<Esc>` | Close |

Opening the window starts an update check when the last one is more than 5 minutes old.

## Features

The core installs, loads and updates plugins on its own. Everything else is a feature under `lua/cinch/features/`, loaded by name from `features`. `features = {}` turns them all off, and reports then go to `vim.notify`.

| Feature | What it adds |
| --- | --- |
| `messages` | Takes over every message cinch sends and `vim.pack`'s output while cinch calls it. Progress updates in place, and notices and git warnings go to a log |
| `stats` | Counts, startup phases, load times, `:Cinch stats`, and one summary per session in `stdpath('state')/cinch/stats.json` |
| `updates` | `:Cinch check`, and applying updates from the window |
| `ui` | The window |

stats asks the OS when Neovim started. Its startup time is a few milliseconds higher than `--startuptime`, which starts its clock after the binary has loaded.

## Events

Everything cinch does goes out on an event bus. Subscribers run in priority order, lower first, and get the payload.

```lua
local cinch = require('cinch')

-- Keep a heavy plugin from loading over SSH
cinch.on('LoadPre', function(ev)
  if vim.env.SSH_TTY and ev.plugin.name == 'copilot.lua' then
    ev.cancel, ev.cancel_reason = true, 'over ssh'
  end
end)
```

| Event | Payload |
| --- | --- |
| `Register` | `plugin` |
| `State` | `plugin`, `from`, `to`, `reason` |
| `Activity` | `plugin`, `from`, `to`: `installing`, `updating`, `deleting`, `building`, `checking` |
| `LoadPre` | `plugin`, `reason`. Set `cancel = true` to stop the load |
| `Load` | `plugin`, `reason`, `ms = { packadd, config }` |
| `LoadError` | `plugin`, `reason`, `err` |
| `PackPre`, `Pack` | `kind`, `name`, `plugin`, `spec`, `path`: from `PackChangedPre` and `PackChanged`, after cinch has updated its state |
| `PackOpPre`, `PackOp` | `op`, `names`, and after the call `ok`, `ms`, `err` |
| `Build` | `plugin`, `ok`, `ms`, `err`, `output` |
| `Phase` | `name`, `ms`: a startup step finished |
| `Later` | The `later` queue is empty |
| `Report` | `msg`, `level`: something for you to read |

`Load`, `LoadError` and `Later` also fire as `User CinchLoad`, `User CinchLoadError` and `User CinchLater` autocmds.

### Custom triggers

A trigger's name is also its spec field.

```lua
require('cinch').trigger('lsp', {
  arm = function(plugin, servers)
    vim.api.nvim_create_autocmd('LspAttach', {
      callback = function(ev)
        local client = vim.lsp.get_client_by_id(ev.data.client_id)
        if client and vim.list_contains(servers, client.name) then
          require('cinch.handler').fire(plugin, 'lsp ' .. client.name)
          return true
        end
      end,
    })
  end,
})

-- spec: { 'some/plugin', lsp = { 'lua_ls' } }
```

A trigger can also define `parse(value)`, `disarm(plugin, values)` to remove what `arm` set up, and `loaded(plugin, values)`.

## Lua API

```lua
local cinch = require('cinch')
cinch.setup(opts)
cinch.add(specs, { confirm = false })
cinch.load(names, reason)
cinch.build(names)
cinch.get(name)           -- one plugin record, or all of them
cinch.update(names, opts) -- vim.pack.update through cinch
cinch.del(names, opts)    -- vim.pack.del through cinch
cinch.on(event, fn, { priority = 50, once = false })
cinch.trigger(name, def)
```

## Things to know

- Lua modules cannot be unloaded. Updating a plugin that has already loaded takes effect when you restart, and cinch says so.
- A `':Cmd'` build needs the plugin's own command, so cinch loads the plugin first. During startup that waits for `VimEnter`.
- A build that fails, or is cut off by quitting, runs again at the next startup.

## Development

```sh
nvim -l tests/run.lua [case]   # each case is the init.lua of its own headless Neovim
stylua --check lua plugin tests
luacheck lua plugin tests
VIMRUNTIME=$(nvim --clean --headless +'lua io.write(vim.env.VIMRUNTIME)' +qa) lua-language-server --check . --checklevel=Warning
```

The cases live in `tests/cases/`. The runner builds local git repos to install from, so the suite needs no network, and gives every case its own data, state and config folders. A first line of `-- phases: N` runs a case N times over the same folders, to test what carries from one session to the next.
