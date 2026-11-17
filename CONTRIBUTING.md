# Contributing

Thanks for your interest. Loadout is a monorepo of small, independent macOS apps
that share a little plumbing. Issues and PRs are welcome for any app.

## Layout

- `apps/<name>/` — one app: its module(s), `README.md`, `LICENSE`, `install.sh`,
  and any data/tests. Each is meant to read and install as its own product.
  Today: Hone, Murmur, Palette, Reap, Relay, and Unsub (QuickShots lives in its
  own repo).
- `lib/litelog/litelog.lua` — shared logging micro-library. Every module uses it.
- `lib/install-common.sh` — shared installer helpers (`ld_link`,
  `ld_copy_if_absent`, `ld_install_core`, `ld_build_settings`). Source it from an
  app's `install.sh`. `ld_install_core` links the loader, litelog, and
  `settings_overlay.lua`.
- `settings/<app>.schema.json` — the options shown in Caps+K's Settings tab.
  `lib/settings/` holds the tool that saves them to
  `~/.hammerspoon/settings/<app>.json`, and `lib/settings_overlay/` merges them
  over the app's defaults. See [settings/README.md](settings/README.md).
- `hammerspoon/init.lua` — the canonical loader. It `pcall`-loads whichever app
  modules are present in `~/.hammerspoon`, so a partial install still works.

## How modules fit together

Modules co-locate in `~/.hammerspoon`, which is how cross-app calls resolve:
`require("litelog")`, Murmur → Hone for cleanup, Palette → every app to build its
menu. QuickShots owns the shared Caps (F18) event tap and exposes
`registerCapsAction` / `registerCapsReleaseHook`; Hone, Murmur, Unsub, and Palette bind into it and
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
4. If you add a shortcut, add it to Palette's `REGISTRY` (and the app to
   `APPS`) so it shows in Caps+K. Private modules outside the repo use
   `require("palette").addApp` from `loadout.local.lua` instead (see
   [private apps](SETUP.md#private-apps)). Moving the built-in apps to that
   self-registration hook is a good contribution if you're looking for one.
5. If the app has user-facing options, add `settings/<app>.schema.json` and the
   one-line overlay call in its `start()` (see [settings/README.md](settings/README.md)).
6. Match the surrounding code's style: comment density, naming, and idiom.

## Before you open a PR

```sh
./test.sh
```

This runs the leak check, the Lua, Unsub, and settings-tool tests, parse
checks, a stock-Bash Reap dry run, a bare-zsh smoke, and ShellCheck. Install its
test dependencies with `brew install lua shellcheck`; CI runs the same
entrypoint on every PR. Keep documentation clear and concise — match the tone
of the existing READMEs.

`bootstrap.sh` turns on a pre-commit hook (`git config core.hooksPath
.githooks`) that runs `lib/check-leaks.sh --staged`. It rejects home-directory
paths, real email addresses, API keys, and generated or local-only files
(dictation logs, `*.local.*`, saved settings, recordings). Mark a deliberate
line with `leak-check: allow`. CI also scans every commit with gitleaks.
