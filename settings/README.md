# Loadout Settings

Per-app settings schemas. Palette (Caps+K) renders each one as the **Settings**
tab of that app's page, so you edit settings in place and press ⌘S.

## How it works

- **`<app>.schema.json`** (this dir) — declares the app's editable fields
  (string, int, bool, enum, or folder), where saved values live, and what to
  run after a save.
- **`lib/settings/loadout-settings`** — a schema-driven helper that reads and
  writes those values. Palette's installer builds it from the Swift source
  beside it (needs the Xcode Command Line Tools); without it, Caps+K can't
  save these settings. Run on its own, it opens a small native settings
  window for one app.
- **`lib/settings_overlay/settings_overlay.lua`** — linked into
  `~/.hammerspoon` by every app installer. Each app calls it at the top of
  `start()` to merge saved values over its in-file defaults.

Saved values live outside the clone, in `~/.hammerspoon/settings/<app>.json`.
Only keys that already exist in the app's `config`, with a value of the same
type, are applied. No file means pure defaults. Saving from Caps+K reloads
Hammerspoon so changes apply.

A schema can also use `"format": "shell"` to rewrite `KEY=VALUE` lines in a
conf file, preserving comments and unknown lines.

Other options in an app's `config` table (Caps+K's **Advanced** group) and key
bindings are stored separately in Hammerspoon's `hs.settings`, not here.

## Headless use

From the clone:

```sh
lib/settings/loadout-settings murmur --dump                 # print resolved values
lib/settings/loadout-settings murmur --set stopGraceMs=200  # write + postSave
lib/settings/loadout-settings murmur --set ... --no-post-save
```

## Adding an app

1. Drop `<app>.schema.json` here (copy an existing one) and point its
   `target` at `~/.hammerspoon/settings/<app>.json`.
2. Add the one-line overlay call at the top of the app's `start()`:
   `pcall(function() require("settings_overlay").apply("<app>", config) end)`
   (see Murmur, Hone, or Unsub).
3. Make sure the app is in Palette's `APPS` list so its page shows the tab.

## Current apps

- **QuickShots** — screenshot folder, clipboard format, auto-paste,
  default last-N, retention days.
- **Murmur** — Parakeet final-pass (off/v2/v3), streaming ASR
  (off/eou160/eou320), punctuation, mic idle timeout, stop grace.
- **Hone** — refine model, auto-refine model, reasoning effort,
  restore-clipboard.
- **Relay** — quick-capture note, Claude command, skip-permissions,
  auto-start Wispr.
- **Unsub** — send vs. compose unsubscribe emails, AI on unsubscribe
  pages, AI model.

Note on overlays: saving stores only the fields you changed from the schema
default; untouched fields keep following the app's own config. Delete
`~/.hammerspoon/settings/<app>.json` to reset an app.
