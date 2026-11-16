# Reap

Reap the leaked MCP subprocesses and stray dev servers that pile up in the
background — Codex/Claude Code MCP servers, `next`/`vite` dev servers, `npm run
dev`, and friends. Codex's `codex app-server` spawns a fresh set of MCP servers
per session and leaks them across sessions; over a day you can accumulate dozens.
Reap finds them and shuts them down cleanly.

It ships primarily as a Raycast Script Command with a dropdown, but the same
script runs from a terminal.

## Modes

Reap takes a single argument selecting what to act on. It defaults to a safe
dry run.

| Mode      | Behavior |
|-----------|----------|
| `dry`     | Preview only. Prints a table of what *would* be killed. Kills nothing. (default) |
| `all`     | Terminate matched MCP servers **and** dev servers. |
| `mcp`     | Terminate matched MCP servers only. |
| `servers` | Terminate matched dev servers only. |

An unrecognized mode exits with an error rather than doing anything.

## Safety

Reap is conservative by design.

- **Dry run by default.** Run it with no argument (or `dry`) and it only shows
  you a table. Nothing is signaled until you explicitly ask for `all`, `mcp`, or
  `servers`.
- **SIGTERM only, never `-9`.** Kill modes send `TERM`, wait a second, and send
  a second `TERM` to any stragglers. Processes that survive are reported and left
  running — Reap never escalates to `SIGKILL`.
- **Narrow allow-list.** It matches only an explicit set of command-line patterns
  (`chrome-devtools-mcp`, `shadcn mcp`, the Codex Computer Use client in mcp mode,
  Codex's leaked `node_repl` helper, the chrome-devtools telemetry watchdog, plus
  `next-server`, `next dev`, `vite`, `npm run dev`, `yarn`/`pnpm dev`). Bare
  `node` and bare `npm` are never matched.
- **Self and ancestors are excluded.** Reap computes its own PID and walks the
  parent chain up to PID 1, excluding every PID along the way, so it can't kill
  the Raycast runner or the shell that launched it.
- **Top-level GUI apps are excluded.** Any process whose command line points at
  `/Applications/<Name>.app/Contents/MacOS/…` (or the same under
  `/System/Applications`) is skipped, protecting Codex.app, Claude.app, VS Code,
  Chrome, Raycast, and the like. The exclusion is anchored to that path, so
  leaked helpers under `Contents/Resources/` are still reaped.

No API keys, no network access, and it writes no files.

## Requirements

- macOS and its built-in Bash 3.2 or later for terminal use.
- Git is needed only to clone Loadout. If `git --version` is unavailable on a
  fresh Mac, run `xcode-select --install` and finish the installer dialog.
- [Raycast](https://raycast.com) only for the optional dropdown UI.
- After cloning, no Hammerspoon, API key, environment variable, or additional
  runtime package is needed.

## Install

```sh
xcode-select --install  # only if git --version is unavailable; finish the dialog
git clone https://github.com/josephvore/loadout.git ~/loadout
cd ~/loadout
apps/reap/install.sh
```

This symlinks `reap.sh` into `~/.config/raycast/scripts/`. The install is
idempotent and backs up anything it would replace. Keep the clone at this path
because it is the live symlink target.

For the dropdown UI, install the current macOS release of
[Raycast](https://raycast.com), then open Raycast Settings → Script Commands →
**Add Script Directory** and choose `~/.config/raycast/scripts`. Raycast does not
automatically index an arbitrary script directory.

Raycast is required for the dropdown UI, but not for the script itself. From a
terminal:

```sh
apps/reap/reap.sh [dry|all|mcp|servers]   # default: dry
```

The terminal mode needs only macOS's built-in Bash 3.2 and standard command-line
tools; it has no API keys, environment variables, network calls, or data files.

To see the live picture Reap is working from:

```sh
ps -axo pid,ppid,etime,command
```

## Verify and test

Run `apps/reap/reap.sh dry`; it must say that nothing was killed. Run the full
repository checks with `./test.sh`.

Suite-wide update and safe-uninstall guidance is in the
[Loadout README](../../README.md#update-and-uninstall).

## Part of Loadout

Reap is part of the [Loadout](../../README.md) suite. See the
[changelog](../../CHANGELOG.md) and [contributor guide](../../CONTRIBUTING.md).
Licensed [MIT](./LICENSE).
