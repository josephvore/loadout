# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Hone** now prompts for Keychain secrets correctly and uses current Groq and
  Cerebras cleanup models without hidden reasoning.
- **Murmur** creates `~/bin`, backs up a differing daemon, links daemon source
  non-destructively, and reports a degraded build as failure.
- Installers now refuse symlinked Hammerspoon config directories and unusable
  user-data destinations instead of writing through managed paths or claiming
  success with broken state.
- **Reap** runs on macOS's built-in Bash 3.2 and explains Raycast's required
  Script Directory registration.
- The optional zsh config leaves missing pyenv/eza/plugins alone, and the loader
  skips apps that are not installed.
- `~/.hammerspoon/loadout.local.lua` now actually runs; previously the loader
  never executed it.

### Added
- **Unsub** (Caps+U): unsubscribe from the message selected in Apple Mail via
  one-click, an unsubscribe email, or the sender's web page (optionally judged
  by OpenAI), falling back to the browser. Never moves or deletes mail;
  `hammerspoon://unsub` is always a dry run.
- **Palette** Shortcuts and Settings tabs per app, with settings edited in the
  window; a resizable window with close and zoom buttons, a right-click menu,
  and Esc to close.
- Shared settings schemas (`settings/<app>.schema.json`), the
  `lib/settings/loadout-settings` tool (built by Palette's installer), and
  `settings_overlay.lua`, linked by every app installer to merge saved values
  over each app's defaults.
- `loadout.local.lua` can start private modules (`return { apps = { ... } }`)
  and list their shortcuts in Caps+K with `require("palette").addApp`.
- **Loadout** suite structure: each tool is now a self-contained, individually
  named app under `apps/` — **Murmur** (dictation), **Hone** (AI text refine),
  **Relay** (flows), **Palette** (Caps+K menu), **Reap** (process reaper) —
  alongside the existing **QuickShots** screenshotter.
- One-pass `bootstrap.sh` that installs every app, clones + wires in QuickShots,
  and prints the human-only steps. Idempotent and non-destructive.
- Per-app `install.sh`, `README.md`, and `LICENSE`; shared `lib/install-common.sh`.
- `PREREQUISITES.md` and `SETUP.md` (the latter doubles as an AI-agent runbook).
- `apps/hone/setup-keys.sh` to store API keys in the macOS Keychain safely.
- MIT `LICENSE`, `CONTRIBUTING.md`, issue/PR templates, and CI (Lua tests +
  shellcheck).

### Changed
- Fresh-Mac requirements, model downloads, local/cloud boundaries, API-key
  provisioning, automatic-cleanup defaults, local transcript logs, updates,
  uninstall behavior, tests, and human-only steps are documented explicitly.
- `./test.sh` is the single local/CI test entrypoint, with an additional macOS
  smoke job for built-in Bash and zsh.
- Shell environment files are private copies, never tracked symlink targets;
  existing environments are preserved when installing or reinstalling.
- Machine-specific shell and Hammerspoon settings have local override files.
- Murmur uses the system microphone and ships generic vocabulary examples.
- Renamed the shared logger to **litelog**; the canonical `hammerspoon/init.lua`
  now `pcall`-loads whichever apps are installed and owns loading (installers no
  longer append their own loader block).
- Modules read data/logs from `~/.hammerspoon` (`hs.configdir`) instead of a
  hard-coded repo path, so they work wherever the repo is cloned.
- Relay launches Claude Code permission-respecting by default; the
  `--dangerously-skip-permissions` flag is now opt-in.
- Shell config guards every tool init so it no longer errors on a bare machine,
  and machine-specific paths were removed.
- Settings saved from Caps+K are stored in `~/.hammerspoon/settings/<app>.json`
  instead of inside the clone, and the clone can live anywhere (`~/loadout`
  remains the documented default).
- **Murmur**'s nightly self-eval is off by default (enable with
  `selfEval = true` in `loadout.local.lua`), and the fixtures it collects are
  written to `~/.hammerspoon/murmur/` instead of the repository.

### Migrated from
- The former personal `dotfiles` repo. History is preserved.
