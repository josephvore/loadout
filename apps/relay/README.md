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

Complete Loadout's [base-app prerequisites](../../PREREQUISITES.md#base-hammerspoon-apps) first.

```sh
git clone https://github.com/josephvore/loadout.git ~/loadout
cd ~/loadout
apps/relay/install.sh
open -a Hammerspoon
```

The installer links `relay.lua` into `~/.hammerspoon/`, backing up anything it
would replace. After it runs, reload Hammerspoon (menu-bar icon → **Reload
Config**, or `hs -c 'hs.reload()'`).
Keep the clone at this path because it is the live symlink target.

## Configuration

The quick-capture note, Claude command, skip-permissions flag, and Wispr
auto-start are editable in Caps+K → Launchers → Settings (saved to
`~/.hammerspoon/settings/relay.json`). For anything else, set
`require("relay").config` fields in your private
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

Relay requires macOS 13 or later, [Hammerspoon](https://www.hammerspoon.org)
1.1.1 or later, and Accessibility permission. Its flows integrate with optional tools that it
does not install:

| Tool | Needed for | Setup |
|---|---|---|
| [iTerm2](https://iterm2.com/downloads.html) | Voice Claude Code window | install the current macOS release |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code/setup) (`claude`) | Voice Claude Code command | follow Anthropic's setup and authenticate |
| [Google Chrome](https://www.google.com/chrome/) | side-panel and search flows | install the current macOS release |
| Any markdown editor, optionally [Obsidian](https://obsidian.md/download) | opening the capture file | point `quickCaptureFile` at your inbox |
| [Raycast](https://raycast.com) plus a dictation extension | optional Wispr deeplink | install/configure the extension and copy its deeplink |

Missing optional tools do not stop Relay from loading; only their corresponding
flows are unavailable.

Relay reads the standard `$HOME` path but has no project-specific environment
variables, `.env` file, or stored API keys. Relay itself makes no API request;
the Chrome, Claude Code, Raycast, Wispr, and editor flows launch separately
configured apps whose own authentication, network, billing, and data policies
apply.

## Permissions

Relay sends keystrokes and activates apps, so macOS needs **Accessibility**
granted to Hammerspoon: System Settings → Privacy & Security → Accessibility →
toggle Hammerspoon on, then reload its config.

## Verify and test

Press `Ctrl+Alt+Cmd+N` and save a test capture; by default it is appended to
`~/Documents/Quick Capture.md`. Verify other flows only after installing their
tools. Run `./test.sh` from the repo root for source and installer checks.

Suite-wide update and safe-uninstall guidance is in the
[Loadout README](../../README.md#update-and-uninstall).

## About

Relay is part of the [Loadout](../../README.md) suite. See the
[changelog](../../CHANGELOG.md) and [contributor guide](../../CONTRIBUTING.md).
Licensed under [MIT](./LICENSE).
