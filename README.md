# dotfiles

Version-controlled macOS environment configs, symlinked into place.

## What's tracked

| Repo file | Symlinked to | Purpose |
|---|---|---|
| `.zshrc` | `~/.zshrc` | Interactive shell (prompt, fzf, aliases, plugins) |
| `.zprofile` | `~/.zprofile` | Login shell (brew, pyenv, ulimit) |
| `.zshenv` | `~/.zshenv` | All shells (cargo, bun PATH) |
| `hammerspoon/init.lua` | `~/.hammerspoon/init.lua` | Loads QuickShots + flows |
| `raycast-scripts/kill-dev-servers.sh` | `~/.config/raycast/scripts/kill-dev-servers.sh` | Reap stale Codex/Claude MCP + dev-server subprocesses |

## Not tracked here (own repos / volumes)

- **QuickShots** — its own repo at `github.com/josephvore/quickshots`, symlinked
  `~/.hammerspoon/quickshots.lua -> /Volumes/Code/quickshots/quickshots.lua`.
(All Hammerspoon configs except QuickShots are now tracked here.)

## Setup on a new machine

```sh
git clone <this-repo> ~/dotfiles
~/dotfiles/install.sh          # idempotent; backs up anything it replaces
```

`install.sh` is safe to re-run; it skips already-correct links and backs up any
real file it would overwrite to `~/.dotfiles-backup-<timestamp>/`.

## Hotkey reference (current system)

- **Caps+D** — dev-capture → new Codex session (QuickShots)
- **Caps+A / V / N / F / Z / O** — QuickShots capture / paste / burst / open
- **⌃⌥⌘N** — Obsidian quick capture · **⌃⌥⌘C** — voice Claude Code
- **⌃⌥⌘D** — Claude Chrome side panel · **⌃⌥⌘G** — Chrome search · **⌃⌥⌘W** — start Wispr
