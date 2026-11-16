# Palette

A searchable pop-up listing every Loadout keyboard shortcut, with **Run**,
**Rebind**, and **Reset** for each — so you never lose track of your hotkeys.

Palette rolls two tools into one. It's the shortcut cheat-sheet you'd reach for
CheatSheet or KeyCue to get, plus a hotkey manager that actually rebinds the
keys. One window, every binding, live.

## What it does

Palette is the Loadout suite's aggregator. It knows the shortcuts of every
installed Loadout app — QuickShots, Murmur, Hone, Relay, and itself — and reads
their live bindings straight from each module's config. Every row shows the key,
what it does, and where it comes from.

- **Run** fires the action without leaving the window.
- **Rebind** waits for you to press a new combo and captures it.
- **Reset** drops back to the app's default binding.

Only apps you've actually installed show up.

## Configuring apps

Each app has its own page (⇥ or click it in the sidebar) with two tabs:
**Shortcuts** and **Settings** (⌘O or ←/→ switches between them). Settings shows
the app's main options (from `settings/<app>.schema.json`) under **General**,
then every other value in the app's `config` table under **Advanced** or its own
group: toggles, numbers (with units), text, prompts, and lists. Search finds
settings too. Edit in place, then press ⌘S. Saving reloads Hammerspoon and
reopens the window on that app.

Option edits are stored in `hs.settings` (`palette.config.v1`) and applied
before the apps start, the same way rebinds are. Your `.lua` files are never
rewritten. A changed option shows an orange dot; ⌘⌫ (or right-click) puts it
back to the file's default. Nested provider tables and similar structures
aren't shown; change those in the app's `.lua`.

Keys: ↑↓ select · ↵ run or edit · ⌘R change key · ⌘O Shortcuts/Settings ·
⌘S save · ⌘⌫ reset · esc close. Right-click any row for the same actions.
The window can be resized from its edges or the bottom-right corner, and the
green button (or a double-click on the top bar) expands it. It remembers its size.

## How rebinding works

Rebinds are persisted in `hs.settings` and re-applied on every reload, before
the modules bind their keys. Your source `.lua` files stay the shipped
defaults; your overrides layer on top. Any row with an active override is
marked **custom**, so you can always tell what you've changed.

## Hotkey

Press **Caps+K** to open the window — this rides on QuickShots' shared
Caps/F18 tap. If that tap isn't active, Palette falls back to
**Ctrl+Alt+Cmd+K**.

## Requirements

- Complete Loadout's [base-app prerequisites](../../PREREQUISITES.md#base-hammerspoon-apps) first.
- macOS 13 or later with [Hammerspoon](https://www.hammerspoon.org) 1.1.1 or later.
- Accessibility permission for Hammerspoon.
- QuickShots is optional; without it Palette uses the fallback hotkey above.

Palette reads only the standard `$HOME` path through Hammerspoon. It has no
project-specific environment variables, `.env` file, API keys, account, model
download, or network request; bindings remain in local `hs.settings` storage.

## Install

```sh
git clone https://github.com/josephvore/loadout.git ~/loadout
cd ~/loadout
apps/palette/install.sh
open -a Hammerspoon
```

The installer links `palette.lua` into `~/.hammerspoon/` and wires it into your
config. Reload Hammerspoon afterward, then press Caps+K.
Keep the clone at this path because it is the live symlink target.

## Permissions

macOS **Accessibility** — Hammerspoon needs it to watch and send keystrokes.
Grant it under System Settings → Privacy & Security → Accessibility, then
reload the config.

## Verify and test

Launch/reload Hammerspoon and press `Ctrl+Alt+Cmd+K`; Palette should show its own
entry plus every other installed Loadout app. Run `./test.sh` from the repo root
for source, installer, and shell checks.

Suite-wide update and safe-uninstall guidance is in the
[Loadout README](../../README.md#update-and-uninstall).

## License

Palette is part of the [Loadout](../../README.md) suite. See the
[changelog](../../CHANGELOG.md) and [contributor guide](../../CONTRIBUTING.md).
Licensed MIT; see [LICENSE](./LICENSE).
