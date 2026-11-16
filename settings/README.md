# Loadout Settings

One native settings window for every Loadout app, driven by per-app schemas.
Open from ✦ → Settings → <app>, or `loadout-settings <app>` in a terminal.

## How it works

- **`~/loadout/lib/settings/loadout-settings`** — a single schema-driven
  AppKit binary (source + build.sh beside it). Renders whatever fields the
  schema declares: string, int, bool, enum, folder (with Browse…), plus an
  optional recent-outputs section.
- **`<app>.schema.json`** (this dir) — declares the app's editable fields,
  where values live, and what to run after save.
- Two backends:
  - `"format": "json"` — writes `<app>.settings.json` (this dir), an
    **overlay** merged over the app's in-file Lua defaults at start by
    `settings_overlay.lua` (one `pcall` line in each app's `start()`). Only
    keys that already exist in the app's config are applied; no overlay file
    means pure defaults. `postSave` reloads Hammerspoon so changes apply.
  - `"format": "shell"` — rewrites `KEY=VALUE` lines in a conf file (snag's
    `snag.conf`), preserving comments and unknown lines. No reload needed.

## Headless use

```sh
loadout-settings murmur --dump                 # print resolved values
loadout-settings murmur --set stopGraceMs=200  # write + postSave
loadout-settings murmur --set ... --no-post-save
```

## Adding an app

1. Drop `<app>.schema.json` here (copy an existing one).
2. json format: add the one-line overlay `pcall` at the top of the app's
   `start()` (see murmur/hone/quickshots).
3. Add a line to the ✦ SwiftBar plugin's Settings submenu.

## Current apps

- **snag** — output folder, pipeline mode, max recording, dry run (+ recent
  outputs list). Shell backend → `snag.conf`.
- **murmur** — Parakeet final-pass (off/v2/v3), streaming ASR
  (off/eou160/eou320), punctuation, mic idle timeout, stop grace.
- **hone (Refine)** — refine model, auto-refine model, reasoning effort,
  restore-clipboard.
- **quickshots** — screenshot folder, clipboard format, auto-paste,
  default last-N, retention days.
- **relay** — quick-capture note, Claude command, skip-permissions,
  auto-start Wispr.
- **unsub** — send vs. compose unsubscribe emails, AI on unsubscribe
  pages, AI model.

Palette (Caps+K) renders every schema here as an inline settings page per
app, so most of these can be changed without opening this window.

Note on overlays: the overlay stores every schema field on save, so it
*pins* those values — later edits to an app's in-file defaults won't show
through until the overlay is deleted (or re-saved). Palette's hotkey
rebinding is separate and stays in Palette (Caps+K).
