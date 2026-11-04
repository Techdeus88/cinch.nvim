# cinch.nvim

A plugin manager for Neovim, built on `vim.pack`.

`vim.pack` owns the disk: installing, the lockfile, updating and deleting. cinch owns the session. It decides when each plugin loads, runs builds, measures what everything costs, and shows it all in one window. Every spec is a `vim.pack.Spec`, so anything you write for cinch also works with `vim.pack.add`.

- **Four ways to load.** `now` loads during startup. `later` loads once the UI is up, a few plugins per tick. `now_if_args` is `now` when Neovim starts with a file and `later` when it doesn't. `trigger` loads on an event, a filetype, a command or a key.
- **A first start you can watch.** On a new machine, cinch waits until the UI is up, opens its window, and installs everything in one parallel batch while each plugin's row goes from cloning to installed. Your colorscheme applies the moment its plugin lands.
- **Builds that never block.** A shell build runs in the background. A plugin whose build is still running loads when the build ends, and a key or command that fired meanwhile is replayed after.
- **Your messages.** cinch shows `vim.pack`'s progress and errors as its own, without Lua stack noise, and logs every step it takes: each install, build, load and trigger.
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

cinch fields can sit at the top level, as above, or inside `data`, the way `vim.pack.Spec` holds extra fields. cinch moves top-level fields into `data` before anything else reads the spec, and when both places set a field, `data` wins. `vim.pack.add` receives `src`, `name`, `version` and a copy of `data`, so `vim.pack.get()` and the `PackChanged` events show your cinch fields. The copy is made so Neovim can pass it through autocmd event data: a table with both list items and named fields, like a lazy-style key `{ 'gx', fn, desc = '…' }`, keeps its list items under `"1"`, `"2"` and so on, and anything that can't cross, such as a cycle or a timer, becomes text. cinch itself reads your spec as you wrote it.

### Fields

| Field | What it does |
| --- | --- |
| `[1]` or `src` | Where the plugin comes from |
| `name` | The plugin's name. Defaults to the last part of `src`, the same way `vim.pack` names it |
| `version` | A branch, tag, commit, or `vim.version.range()`. Passed to `vim.pack` unchanged. A range must be a range object: `vim.pack` reads a string like `'^1.2'` as a branch or tag name, so cinch warns when a string looks like a range |
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

`now` plugins load while `init.lua` runs, in the order you declared them, dependencies first. On a first start they load right after the install instead (see below). Neovim then sources their `plugin/` files in its normal startup pass, so a `now` plugin's `config` runs before its own `plugin/` files. A plugin whose `config` needs something its `plugin/` file defines should use `later`.

### The first start

When plugins are missing, cinch doesn't install them while `init.lua` runs, because there's no screen to show the install on yet. It waits for `UIEnter`, opens its window, and installs then. Exactly what waits depends on why plugins are missing:

| Situation | What happens |
| --- | --- |
| Nothing missing | A normal start. Nothing waits |
| A new spec, or one whose `src` doesn't exist | Plugins already on disk start during `init.lua` as usual. Only the missing ones wait for the UI |
| Your lockfile lists plugins that aren't on disk, as on a new machine with your dotfiles | Everything waits. `vim.pack`'s first call would install those during `init.lua` anyway |
| Headless Neovim, or `defer = false` | Installs during `init.lua`, as `vim.pack` does |

While the batch installs, the keys you press are held until it's done: `vim.pack.add` waits for git, and so does Neovim's input.

## Setup

```lua
require('cinch').setup({
  spec = { 'plugins' },          -- module paths, folders, or specs; default lua/plugins/
  confirm = true,                -- ask before installing, with vim.pack's prompt
  budget = 5,                    -- ms of `later` loading per event-loop tick
  defer = true,                  -- install missing plugins once the UI is up
  features = { 'messages', 'stats', 'updates', 'ui' },

  -- each feature's options, under its name
  messages = { level = vim.log.levels.INFO, progress = true, history = 1000 },
  stats = { persist = true, history = 50 },
  updates = { fresh = 300 },     -- seconds before opening the window checks again
  ui = {
    size = 0.75,                 -- share of the editor
    wide = 0.95,                 -- share after `=`
    split = 0.58,                -- the list's share of the width beside the pane
    side_by_side = 130,          -- frame width from which the pane sits beside the list, not under it
    border = nil,                -- default: your 'winborder', or rounded
    open_on_install = true,      -- open the window when plugins install
    colorscheme = nil,           -- e.g. 'tokyonight': applied as soon as its plugin is on disk
    icons = {},                  -- your own for any of: now, later, event, ft, cmd, keys, dep, trigger
  },
})
```

`require('cinch').add(specs)` takes the same list `vim.pack.add` does, with cinch fields allowed, and works without `setup()`.

### Your own code on the same schedule

`now`, `later` and `now_if_args` also take a function, for config that isn't a plugin spec: options, keymaps, autocmds.

```lua
local cinch = require('cinch')

cinch.now(function() vim.o.number = true end)
cinch.later(function() require('my.keymaps') end)
cinch.now_if_args(function() vim.cmd.colorscheme('tokyonight') end)
```

- `now(fn)` runs at once. Called before `setup()`, it runs right after the `now` plugins load, so it can `require()` them. On a first start, when every plugin waits for the UI, it waits too.
- `later(fn)` joins the `later` queue once the UI is up, in turn with `later` plugins, in the order you call it.
- `now_if_args(fn)` is `now` when Neovim starts with a file argument and `later` when it doesn't.

An error in one of these functions is reported with the file and line where you defined it, and the others still run. Each one that runs is in the log.

## Commands

| Command | Does |
| --- | --- |
| `:Cinch` | Open the window |
| `:Cinch open [plugins\|stats\|log]` | Open it on a view |
| `:Cinch load {names}` | Load plugins now |
| `:Cinch build {names}` | Run their builds again |
| `:Cinch check [names]` | Check for updates in the background |
| `:Cinch update [names]` | Update with `vim.pack`'s review tab. `:Cinch update!` applies without it |
| `:Cinch del {names}` | Delete plugins from disk. One your specs list is in use, so it needs `:Cinch del!`, and it installs again on the next start |
| `:Cinch clean` | Delete every plugin on disk that no spec names |
| `:Cinch stats` | Print this session's stats |

## The window

A frame at 75% of the editor. Its top border holds the plugin count, startup time, and the three views: plugins, stats and log. The bottom border holds the keys for the view you're in.

The **Plugins** view is two panes. The list on the left groups plugins into working, failed, loaded, waiting and disabled, with what is happening now on top. Each row puts its parts one after the other: a status light (lit once loaded, a spinner while it works), the name, its load time and a load-time bar once it has loaded, then how it loads: a Nerd Font icon and its name for `now` and `later`, and for a trigger plugin each trigger type with its icon and values, the value that loaded it on a chip. A plugin that is only a dependency shows the plugins that need it. Pending commits and a message come last, and only when there is something to say: an error, the newest line a build is printing, why it is off. The pane on the right follows the cursor and shows that plugin in full: how and when it loaded, its folder and url, the branch it follows or the version you pinned, the commit on disk, its readme, pending commits, its dependencies and what needs it, the config and opts it received, the last lines of its build output, live while it builds, and where its spec is. `gx` opens the url. Plugins still on disk that no spec names any more sit last, under "not in your specs", where `d` deletes them. In a frame narrower than 130 columns, where the list could not fit a whole row beside the pane, the pane sits under the list instead.

**Stats** shows a startup timeline split into Neovim's own time, each of cinch's phases and `later`, then counts, the slowest plugins, and startup times from past sessions. **Log** shows every step and message, oldest first.

| Key | Does |
| --- | --- |
| `j`, `k` | Move between plugins; the pane follows |
| `<CR>` | Fold or open the section under the cursor |
| `/` | Filter plugins by name, or the log by text. An empty filter clears it |
| `l` | Load the plugin under the cursor |
| `b` | Run its build |
| `u` | Apply its pending update |
| `U` | Apply every pending update |
| `c` | Check for updates |
| `d` | Delete the plugin under the cursor from disk, once you confirm |
| `gf` | Open the plugin's spec file at its line |
| `r` | Read what `vim.pack` knows again |
| `G` | Jump to the newest log entry |
| `?` | Show every key |
| `<Tab>`, `<S-Tab>` | Next or previous view |
| `=` | Switch between 75% and 95% of the editor |
| `q`, `Q`, `<Esc>` | Close |

Opening the window starts an update check when the last one is more than 5 minutes old.

## Features

The core installs, loads and updates plugins on its own. Everything else is a feature under `lua/cinch/features/`, loaded by name from `features`. `features = {}` turns them all off, and reports then go to `vim.notify`.

| Feature | What it adds |
| --- | --- |
| `messages` | Takes over every message cinch sends and `vim.pack`'s output while cinch calls it. Progress updates in place. Every step cinch takes, notices, and git warnings go to the log |
| `stats` | Counts, startup phases, load times, `:Cinch stats`, and one summary per session in `stdpath('state')/cinch/stats.json` |
| `updates` | `:Cinch check`, and applying updates from the window |
| `ui` | The window, and the first start shown in it |

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
| `LoadWait` | `plugin`, `reason`, `build`: the load waits for `build`'s build to end, the plugin's own or a dependency's |
| `LoadPre` | `plugin`, `reason`. Set `cancel = true` to stop the load |
| `Load` | `plugin`, `reason`, `ms = { packadd, config }` |
| `LoadError` | `plugin`, `reason`, `err` |
| `PackPre`, `Pack` | `kind`, `name`, `plugin`, `spec`, `path`: from `PackChangedPre` and `PackChanged`, after cinch has updated its state |
| `PackOpPre`, `PackOp` | `op`, `names`, and after the call `ok`, `ms`, `err` |
| `Build` | `plugin`, `ok`, `ms`, `err`, `output` |
| `BuildOutput` | `plugin`, `lines`: new lines from a shell build as it runs |
| `Phase` | `name`, `ms`: a startup step finished |
| `Later` | The `later` queue is empty |
| `Run` | `when`, `where`, `ok`, `ms`, `err`: one of your `now`/`later` functions ran |
| `Installing`, `Installed` | `names`, and after the batch `failed` and `ms`: a batch of installs starts and ends |
| `Report` | `msg`, `level`: something for you to read |

The message feature adds `Progress` (`title`, `done`, `total`, `name`: `vim.pack`'s progress, one plugin at a time) and `Message` (an entry added to the log).

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
cinch.del(names, opts)    -- vim.pack.del through cinch; says why when it refuses
cinch.clean()             -- delete every plugin on disk that no spec names
cinch.now(fn)
cinch.later(fn)
cinch.now_if_args(fn)
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

The cases live in `tests/cases/`. The runner builds local git repos to install from, so the suite needs no network, and gives every case its own data, state and config folders. A first line of `-- phases: N` runs a case N times over the same folders, to test what carries from one session to the next. A header line of `-- args: notes.md` opens that file, as if you passed it on the command line.
