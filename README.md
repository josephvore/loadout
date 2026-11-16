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
| [Murmur](https://github.com/josephvore/murmur) | On-device, push-to-talk dictation with an optional LLM cleanup pass | Wispr Flow · Superwhisper |
| [Hone](apps/hone) | Rewrite the clipboard or a selection for clarity, in place, one keypress | Raycast AI · Grammarly rewrite |
| [Relay](apps/relay) | Quick-launch / voice flows into your other tools | Alfred · Raycast workflows |
| [Unsub](apps/unsub) | Caps+U in Apple Mail unsubscribes from the selected message | Clean Email · Leave Me Alone |
| [Palette](apps/palette) | Searchable Caps+K menu of every shortcut and app setting, with rebind | CheatSheet · KeyCue |
| [Reap](apps/reap) | Reap leaked MCP + dev-server processes (safe dry-run default) | — |

Two apps also have standalone repos for discovery: [QuickShots](https://github.com/josephvore/quickshots)
(its own source of truth — the bootstrap script clones and wires it in for you) and
[Murmur](https://github.com/josephvore/murmur) (mirrored from `apps/murmur`, kept in sync from here).

The software is free. Hone and Murmur's optional cleanup send text—not audio—to
the API provider you configure, whose billing and data policies apply. Unsub
contacts the sender's unsubscribe link and, if you store an OpenAI key, sends
unsubscribe-page text to OpenAI; see its [privacy notes](apps/unsub/README.md#privacy).

## Quick start

First install the required system software: macOS 26 or later, Hammerspoon
1.1.1 or later, and the Xcode 26 Command Line Tools (Swift 6 + macOS 26 SDK).
Murmur is tested on Apple Silicon; Intel is currently unverified. Keep at least
2 GB free for Murmur's build cache and on-device speech models.
See [PREREQUISITES.md](PREREQUISITES.md) for exact checks and optional tools.

```sh
xcode-select --install              # finish the macOS installer dialog first
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# Follow Homebrew's printed PATH instructions, then:
brew install --cask hammerspoon
git clone https://github.com/josephvore/loadout.git ~/loadout
cd ~/loadout
./bootstrap.sh                 # installs the Hammerspoon apps + QuickShots
# ./bootstrap.sh --with-shell  # also symlink the zsh config (optional)
```

`bootstrap.sh` is idempotent and non-destructive — it backs up anything it would
replace and **never installs system software for you**. It finishes independent
installs but exits nonzero if Hammerspoon, QuickShots, or Murmur is unavailable.

The installers use symlinks, so the clone is the live installation. It can live
anywhere (`~/loadout` is just the default these docs use), but keep it at the
cloned path; re-run the relevant installer after moving it.

Then finish the human-only steps — launch Hammerspoon, grant permissions, enter
optional API keys, remap Caps Lock, and register Reap's Raycast script directory.
The bootstrap prints them, and [SETUP.md](SETUP.md) is the full checklist.

## Test

With Lua 5.4+ and ShellCheck installed:

```sh
./test.sh
```

This runs Murmur's deterministic suite, parses every Lua/Python/shell source, checks
the bare-zsh fallback, runs Reap in dry mode, and enforces ShellCheck. See
[CONTRIBUTING.md](CONTRIBUTING.md) and [CHANGELOG.md](CHANGELOG.md).

## Update and uninstall

The clone is the live install. Update both sources, then re-run the same
idempotent bootstrap command:

```sh
git -C ~/loadout pull --ff-only
git -C ~/code/quickshots pull --ff-only
cd ~/loadout && ./bootstrap.sh
```

If you used a custom `--quickshots-dir` or `--with-shell`, use those same values
again. To uninstall, first run QuickShots' `caps-uninstall.sh` if you enabled the
Caps Lock remap, quit Hammerspoon, and remove only symlinks whose `readlink`
targets are inside the Loadout or QuickShots clone. `~/bin/hs-dictate` can then
be removed separately. Murmur's glossary, corrections, snippets, model cache,
rotating logs, and the settings saved in `~/.hammerspoon/settings/` are
intentionally retained unless you explicitly remove them. Remove either clone only after its live symlinks are gone.

## Why Caps Lock

Most of these tools bind to **Caps Lock as a modifier** (Caps+A to capture, Caps+K
for the menu, and so on). QuickShots remaps Caps Lock to a spare key (F18) and owns
a shared event tap the other apps hook into (Murmur dictates on Caps+M, Unsub
unsubscribes on Caps+U). Apps that
don't use Caps (Relay on Ctrl+Alt+Cmd) bind their own collision-free hotkeys. See
each app's README for its bindings.

## Repo layout

```
loadout/
  bootstrap.sh          # install the whole suite
  PREREQUISITES.md      # what to install yourself first
  SETUP.md              # full setup checklist / AI-agent runbook
  Brewfile              # optional: `brew bundle` to install CLI tools
  apps/<name>/          # each app: source, README, LICENSE, install.sh
  settings/             # per-app settings schemas (Caps+K → Settings)
  lib/litelog/          # shared logging micro-library
  lib/settings/         # settings tool that reads/writes those schemas
  lib/settings_overlay/ # merges saved settings over each app's defaults
  lib/install-common.sh # shared installer helpers
  hammerspoon/init.lua  # canonical loader (loads whichever apps are installed)
  shell/                # optional zsh config
```

## License

MIT — see [LICENSE](LICENSE). Each app carries its own copy.
