# Loadout

A free, open-source kit of macOS productivity utilities — each one a focused
replacement for a paid app. Built on [Hammerspoon](https://www.hammerspoon.org),
driven from the keyboard, and installable in one pass.

Each app stands on its own (its own folder, README, and installer). Install the
whole loadout, or just the pieces you want.

## The apps

| App | What it does | Replaces |
|---|---|---|
| [QuickShots](https://github.com/josephvore/quickshots) | Drag-area screenshots that auto-group and smart-paste (as images, files, or paths) | CleanShot X · Shottr · Xnapper |
| [Murmur](apps/murmur) | On-device, push-to-talk dictation with an LLM cleanup pass | Wispr Flow · Superwhisper |
| [Hone](apps/hone) | Rewrite the clipboard or a selection for clarity, in place, one keypress | Raycast AI · Grammarly rewrite |
| [Relay](apps/relay) | Quick-launch / voice flows into your other tools | Alfred · Raycast workflows |
| [Palette](apps/palette) | Searchable Caps+K menu of every shortcut, with rebind | CheatSheet · KeyCue |
| [Reap](apps/reap) | Reap leaked MCP + dev-server processes (safe dry-run default) | — |

QuickShots lives in [its own repo](https://github.com/josephvore/quickshots); the
bootstrap script clones and wires it in for you.

## Quick start

```sh
git clone https://github.com/josephvore/loadout.git ~/loadout
cd ~/loadout
./bootstrap.sh                 # installs the Hammerspoon apps + QuickShots
# ./bootstrap.sh --with-shell  # also symlink the zsh config (optional)
```

`bootstrap.sh` is idempotent and non-destructive — it backs up anything it would
replace and **never installs system software for you**. Make sure the
[prerequisites](PREREQUISITES.md) are in place first.

Then finish the three steps only you can do — API keys, the Caps Lock remap, and
macOS permissions. The bootstrap prints them, and [SETUP.md](SETUP.md) is the full
checklist (it also doubles as a runbook you can hand to an AI coding agent).

## Why Caps Lock

Most of these tools bind to **Caps Lock as a modifier** (Caps+A to capture, Caps+K
for the menu, and so on). QuickShots remaps Caps Lock to a spare key (F18) and owns
a shared event tap the other apps hook into. Apps that don't use Caps (Murmur on
Right-Command, Relay on Ctrl+Alt+Cmd) bind their own collision-free hotkeys. See
each app's README for its bindings.

## Repo layout

```
loadout/
  bootstrap.sh          # install the whole suite
  PREREQUISITES.md      # what to install yourself first
  SETUP.md              # full setup checklist / AI-agent runbook
  Brewfile              # optional: `brew bundle` to install CLI tools
  apps/<name>/          # each app: source, README, LICENSE, install.sh
  lib/litelog/          # shared logging micro-library
  lib/install-common.sh # shared installer helpers
  hammerspoon/init.lua  # canonical loader (loads whichever apps are installed)
  shell/                # optional zsh config
```

## License

MIT — see [LICENSE](LICENSE). Each app carries its own copy.
