# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
- Renamed the shared logger to **litelog**; the canonical `hammerspoon/init.lua`
  now `pcall`-loads whichever apps are installed and owns loading (installers no
  longer append their own loader block).
- Modules read data/logs from `~/.hammerspoon` (`hs.configdir`) instead of a
  hard-coded repo path, so they work wherever the repo is cloned.
- Relay launches Claude Code permission-respecting by default; the
  `--dangerously-skip-permissions` flag is now opt-in.
- Shell config guards every tool init so it no longer errors on a bare machine,
  and machine-specific paths were removed.

### Migrated from
- The former personal `dotfiles` repo. History is preserved.
