# Relay

A small set of global "flows" — quick-launch and voice shortcuts that jump you
straight into the tools you already use. One keystroke captures a note, opens
Claude Code in the right repo, or drops you into a search.

Relay is a personal automation pack, not a paid app. The closest analog is a
handful of Alfred or Raycast workflows: a few opinionated hotkeys wired to the
apps on this machine. It isn't a one-to-one replacement for any product — it's
the glue between the ones you have.

It runs on [Hammerspoon](https://www.hammerspoon.org) and uses ordinary global
hotkeys. QuickShots owns the Caps Lock tap, so Relay uses collision-free
triple-modifier combos (Ctrl+Alt+Cmd) that apps essentially never bind.

## Flows

| Hotkey             | Action                                                             |
| ------------------ | ----------------------------------------------------------------- |
| `Ctrl+Alt+Cmd+N`   | Quick-capture a note — appended to a markdown inbox file.         |
| `Ctrl+Alt+Cmd+C`   | Open a new iTerm window in the current repo running Claude Code.  |
| `Ctrl+Alt+Cmd+D`   | Focus Chrome and toggle the Claude side panel.                    |
| `Ctrl+Alt+Cmd+G`   | Focus Chrome and open a new tab to search.                        |

## Claude Code permissions

The Voice Claude Code flow (`Ctrl+Alt+Cmd+C`) launches Claude Code
permission-respecting by default — it runs plain `claude`, so tools still ask
for per-action approval.

An opt-in config flag, `claudeDangerouslySkipPermissions`, appends
`--dangerously-skip-permissions` to that command. It's convenient — tools run
without stopping for approval — but it removes a safety gate: Claude Code can
edit files and run commands without asking. Leave it `false` unless you
understand and accept that tradeoff. The default is off.

## Install

From the repo root:

```sh
apps/relay/install.sh
```

The installer links `relay.lua` into `~/.hammerspoon/`, backing up anything it
would replace. After it runs, reload Hammerspoon (menu-bar icon → **Reload
Config**, or `hs -c 'hs.reload()'`).

## Configuration

Set `require("relay").config` fields in your private
`~/.hammerspoon/loadout.local.lua` (see [local configuration](../../SETUP.md#local-configuration)):

- `quickCaptureFile` — path to your notes inbox. Point it at wherever you keep
  quick notes, e.g. an Obsidian vault under iCloud. The parent dir and file are
  created on demand.
- `hotkeys` — the `{ {modifiers}, key }` pair for each flow. Set any to `nil`
  to disable it.
- `claudeCommand` / `claudeDangerouslySkipPermissions` — see above.
- `wisprDeeplink` and the dogfood delays — tune the dictation and side-panel
  timing.

## External tools

These flows drive apps Relay expects to find, but doesn't bundle or replace.
Everything here is optional — a flow that targets a missing app just won't do
anything useful:

- **iTerm** — the terminal the Claude Code flow opens.
- **Google Chrome** — target of the side-panel and search flows.
- **Obsidian** (or any markdown editor) — opens your quick-capture inbox.
- **A dictation deeplink** (Raycast / Wispr Flow) — used to start voice input.

## Permissions

Relay sends keystrokes and activates apps, so macOS needs **Accessibility**
granted to Hammerspoon: System Settings → Privacy & Security → Accessibility →
toggle Hammerspoon on, then reload its config.

## About

Relay is part of the [Loadout](../../README.md) suite. Licensed under
[MIT](./LICENSE).
