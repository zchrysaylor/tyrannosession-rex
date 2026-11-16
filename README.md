# Tyrannosession Rex

A simple "sessionizer" for [Rex](https://www.superlogical.com/rex/docs/installation), consisting of a floating `fzf` project picker and optional auto-launched commands/tabs.

Requires `fd` and `fzf`.

## Setup

Copy `tyrannosession-rex.lua` to `~/.config/rex/`, then add this to your Rex config (`~/.config/rex/init.lua`), adjusting the project directories:

```lua
local home = assert(os.getenv("HOME"))
local path = home .. "/.config/rex/tyrannosession-rex.lua"

dofile(path).setup({
   script_path = path,
   roots = { home .. "/Code" }, -- search root dirs; includes their immediate subdirectories
   programs = { { "pi" }, { "zsh" } }, -- optional; the tabs/programs you want on new session creation
   bindings = {
      picker = "ctrl+b>f",
      new_tab = { "cmd+t", "ctrl+b>c" }, -- optional
   },
})
```

Apply changes with `rex config reload`.

