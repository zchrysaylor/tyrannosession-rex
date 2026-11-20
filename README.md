# Tyrannosession Rex

A simple "sessionizer" for [Rex](https://www.superlogical.com/rex/docs/installation): a floating `fzf` project picker that opens each project in its own session, optionally with startup tabs/programs.

Requires `fd` and `fzf`.

## Setup

Copy `tyrannosession-rex.lua` to `~/.config/rex/`, then add this to `~/.config/rex/init.lua`:

```lua
require("tyrannosession-rex").setup({
   roots = { "~/Code" }, -- search these dirs and their immediate subdirectories
   programs = { { "pi" }, { "zsh" } }, -- optional; one tab per program in new sessions
   executables = { fd = "/opt/homebrew/bin/fd", fzf = "/opt/homebrew/bin/fzf" }, -- if Rex's PATH lacks them
   bindings = {
      picker = "ctrl+b>f", -- the default
      new_tab = { "cmd+t", "ctrl+b>c" }, -- optional; new tab at the project root
   },
})
```

Apply changes with `rex config reload`.
