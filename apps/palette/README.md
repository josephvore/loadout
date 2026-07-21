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

Only apps you've actually installed show up. Nothing to configure.

## How rebinding works

Rebinds are persisted in `hs.settings` and re-applied on every reload, before
the modules bind their keys. Your source `.lua` files stay the shipped
defaults; your overrides layer on top. Any row with an active override is
marked **custom**, so you can always tell what you've changed.

## Hotkey

Press **Caps+K** to open the window — this rides on QuickShots' shared
Caps/F18 tap. If that tap isn't active, Palette falls back to
**Ctrl+Alt+Cmd+K**.

## Install

From the repo root:

```sh
apps/palette/install.sh
```

The installer links `palette.lua` into `~/.hammerspoon/` and wires it into your
config. Reload Hammerspoon afterward, then press Caps+K.

## Permissions

macOS **Accessibility** — Hammerspoon needs it to watch and send keystrokes.
Grant it under System Settings → Privacy & Security → Accessibility, then
reload the config.

## Note

Palette currently hard-references the other apps' modules directly; a future
version may move to a self-registration API so it can run fully standalone.

## License

Palette is part of the [Loadout](../../README.md) suite and is licensed MIT.
See [LICENSE](./LICENSE).
