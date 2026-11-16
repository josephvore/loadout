# Repository Guidelines

## Project Structure & Module Organization

Loadout is a macOS utility monorepo. Each standalone app lives in `apps/<name>/` with its Lua or shell source, `README.md`, `LICENSE`, and `install.sh`. Murmur also contains deterministic Lua tests in `apps/murmur/tests/` and a SwiftPM helper in `apps/murmur/hs-dictate/`. Shared installer functions, logging, and the settings tool and overlay live under `lib/`, with per-app settings schemas in `settings/`; `hammerspoon/init.lua` is the canonical module loader. Root documents cover prerequisites and setup, while `shell/` contains the optional zsh configuration.

Keep app-specific behavior inside its app directory. Do not make installers edit `init.lua`; use `lib/install-common.sh` to link shared files into `~/.hammerspoon`.

## Build, Test, and Development Commands

- `./bootstrap.sh`: install all Hammerspoon apps and QuickShots; it is idempotent and backs up replaced files.
- `./bootstrap.sh --with-shell`: also link the optional shell configuration.
- `apps/<name>/install.sh`: install or refresh one app during development.
- `cd apps/murmur/hs-dictate && swift build -c release`: compile Murmur's Swift daemon. Run `./build.sh` there to compile and copy it to `~/bin/hs-dictate`.
- `lua apps/murmur/tests/test_murmur.lua`: run the pure-Lua regression suite.
- `./test.sh`: the single entrypoint CI runs. It checks `git diff --check` whitespace, runs the Murmur suite, parses every tracked Lua and Python file and the listed shell scripts, runs installer safety checks against a scratch `$HOME`, does a Reap dry run on stock Bash and a bare-zsh startup smoke, then runs ShellCheck on the scripts in its `SHELL_FILES` list (`--skip-shellcheck` skips that step). Add new shell scripts to `SHELL_FILES`.

## Coding Style & Naming Conventions

Follow the surrounding file: two-space indentation for Lua and shell, four spaces for Swift, and concise comments that explain behavior or safety constraints. Lua modules use lowercase filenames and `local` camelCase helpers; public module methods belong on `M`. Shell scripts must use `set -euo pipefail`, quote expansions, and reuse `ld_*` helpers. Read runtime paths from `hs.configdir` or `$HOME`, never a clone-specific absolute path. Register new shortcuts in Palette's `REGISTRY`.

## Testing Guidelines

Add table-driven replay cases to `apps/murmur/tests/replay_cases.lua` for transcript behavior. Keep testable logic free of Hammerspoon dependencies in core modules. Run `./test.sh` before every PR; CI runs the same script and requires it to pass. For UI or hotkey changes, also reload Hammerspoon and manually verify the affected flow.

## Commit & Pull Request Guidelines

History favors short, imperative subjects, sometimes with scopes such as `docs:` or `feat:`. Keep each commit focused on one app or suite concern. Use the PR template: identify affected apps, explain what changed and why, link relevant issues, and include screenshots for visible UI changes. Update the app README or `CHANGELOG.md` when behavior changes. Never commit API keys, generated models, user data, or machine-specific paths.
