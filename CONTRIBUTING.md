# Contributing

Thanks for your interest. Loadout is a monorepo of small, independent macOS apps
that share a little plumbing. Issues and PRs are welcome for any app.

## Layout

- `apps/<name>/` — one app: its module(s), `README.md`, `LICENSE`, `install.sh`,
  and any data/tests. Each is meant to read and install as its own product.
- `lib/litelog/litelog.lua` — shared logging micro-library. Every module uses it.
- `lib/install-common.sh` — shared installer helpers (`ld_link`,
  `ld_copy_if_absent`, `ld_install_core`). Source it from an app's `install.sh`.
- `hammerspoon/init.lua` — the canonical loader. It `pcall`-loads whichever app
  modules are present in `~/.hammerspoon`, so a partial install still works.

## How modules fit together

Modules co-locate in `~/.hammerspoon`, which is how cross-app calls resolve:
`require("litelog")`, Murmur → Hone for cleanup, Palette → every app to build its
menu. QuickShots owns the shared Caps (F18) event tap and exposes
`registerCapsAction` / `registerCapsReleaseHook`; Hone and Palette bind into it and
fall back to global hotkeys if QuickShots isn't loaded.

**App installers never edit `init.lua`.** They only drop their files into
`~/.hammerspoon` (and link the canonical `init.lua` + `litelog`). The loader owns
loading — this is what keeps installs composable and avoids duplicate loaders.

## Adding or changing an app

1. Keep it self-contained under `apps/<name>/` with its own README, LICENSE, and
   `install.sh` (start from an existing one).
2. Read config/paths from `hs.configdir` (i.e. `~/.hammerspoon`), never from a
   hard-coded repo path — the code must work wherever it's cloned.
3. Never commit secrets. Keys come from the macOS Keychain; data files that the
   app writes to are copied (not linked) and never overwritten on re-install.
4. If you add a shortcut, add it to Palette's `REGISTRY` so it shows in Caps+K.
   (Longer term, Palette should move to a self-registration API so it no longer
   hard-references each app — a good contribution if you're looking for one.)
5. Match the surrounding code's style: comment density, naming, and idiom.

## Before you open a PR

```sh
lua apps/murmur/tests/test_murmur.lua   # Lua tests
shellcheck -x bootstrap.sh apps/*/install.sh lib/install-common.sh shell/install.sh
```

CI runs both on every PR. Keep documentation clear and concise — match the tone of
the existing READMEs.
