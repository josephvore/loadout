# Hone

Rewrite the clipboard or your current selection for clarity and concision with
an LLM — in place, with one keypress. Hone also serves as the cleanup engine for
its sibling dictation app, [Murmur](../murmur).

It replaces the paid, closed rewrite tools you'd otherwise reach for — Raycast
AI, Grammarly's rewrite, MacGPT-style "refine" commands — with a free,
open-source, keychain-backed alternative that runs on your own API keys.

## How it works

Two hotkeys, backed by OpenAI:

| Hotkey   | Action                                                          |
| -------- | -------------------------------------------------------------- |
| `Caps+C` | Refine the clipboard contents, then paste the result.          |
| `Caps+S` | Refine the current selection, replacing it in place.           |

Hone binds into [QuickShots'](https://github.com/josephvore/quickshots) shared Caps (F18) event tap, so the
bindings never collide with normal typing. If QuickShots isn't loaded, it falls
back to standard global hotkeys: `Ctrl+Alt+Cmd+R` (clipboard) and
`Ctrl+Alt+Cmd+S` (selection).

## Providers

Hone speaks to three backends. Manual refinement uses OpenAI; the optional
dictation-cleanup path picks the first configured provider in this preference
order: Cerebras → Groq → OpenAI.

| Provider | Models | Notes |
| -------- | ------ | ----- |
| OpenAI | `gpt-5.4`, `gpt-5.4-nano` | Responses API; manual refine and cleanup. |
| Groq | `qwen/qwen3.6-27b` | Cleanup with `reasoning_effort: none`. |
| Cerebras | `zai-glm-4.7` | Cleanup with `reasoning_effort: none`. |

An OpenAI key is required for Hone's manual refinement hotkeys. Groq and
Cerebras are optional alternatives for Murmur's dictation cleanup. Provider
availability, pricing, and latency can change independently of Hone.

## Requirements

- Complete Loadout's [base-app prerequisites](../../PREREQUISITES.md#base-hammerspoon-apps) first.
- macOS 13 or later with [Hammerspoon](https://www.hammerspoon.org) 1.1.1 or later.
- macOS Accessibility permission for Hammerspoon.
- Network access and an OpenAI API key for the manual refinement hotkeys.

## Install

```sh
git clone https://github.com/josephvore/loadout.git ~/loadout
cd ~/loadout
apps/hone/install.sh
apps/hone/setup-keys.sh
open -a Hammerspoon
```

The installer symlinks `hone.lua` into `~/.hammerspoon` and wires up the loader.
`setup-keys.sh` then stores your API keys (see below).
Keep the clone at this path; it is the live symlink target.

## API keys

Keys are read from the macOS Keychain — one service name per provider:

| Provider | Create a key | Keychain service |
| -------- | ------------ | ---------------- |
| OpenAI | [API keys](https://platform.openai.com/api-keys) | `openai-refine` |
| Groq | [API keys](https://console.groq.com/keys) | `groq-api` |
| Cerebras | [Cloud console](https://cloud.cerebras.ai/) | `cerebras-api` |

No key is ever written to the repo. Run `apps/hone/setup-keys.sh` to store them;
it uses the macOS `security` prompt, so keys never touch your shell history,
process arguments, or any file. Re-run it any time to update a key.

Hone does not read API keys from environment variables and does not use an
`.env` file. When you invoke Hone, the selected or clipboard text is sent to the
chosen cloud provider; audio is never involved. The software is free, but the
provider may charge for API use and applies its own retention/privacy policy.

## Permissions

Hone needs macOS **Accessibility** access (granted to Hammerspoon) to read the
current selection and to paste. macOS prompts the first time; enable it under
System Settings → Privacy & Security → Accessibility, then reload Hammerspoon.

## Configuration

Edit the `config` table at the top of `hone.lua`:

- **`vocabulary`** — a list of names, brands, and jargon the model is told to
  correct toward (for example `"post gres"` → `"Postgres"`).
- **Shared glossary** — if Murmur is installed, Hone also reads its glossary at
  `~/.hammerspoon/murmur/dictation_glossary.txt`, so both apps bias corrections
  toward the same custom terms.

Both are optional; leave `vocabulary` empty for a plain rewrite.

## Verify and test

Grant Accessibility, reload Hammerspoon, then try `Ctrl+Alt+Cmd+R` with text on the
clipboard (the fallback works without QuickShots). From the repo root, run the
full source and installer checks with `./test.sh`.

Suite-wide update and safe-uninstall guidance is in the
[Loadout README](../../README.md#update-and-uninstall).

## About

Hone is part of the **Loadout** suite. See the [Loadout README](../../README.md),
[changelog](../../CHANGELOG.md), and [contributor guide](../../CONTRIBUTING.md).

Licensed under [MIT](./LICENSE).
