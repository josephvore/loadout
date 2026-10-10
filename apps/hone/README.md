# Hone

Rewrite the clipboard or your current selection for clarity and concision with
an LLM — in place, with one keypress. Hone also serves as the cleanup engine for
its sibling dictation app, [Murmur](../murmur).

It replaces the paid, closed rewrite tools you'd otherwise reach for — Raycast
AI, Grammarly's rewrite, MacGPT-style "refine" commands — with a free,
open-source, keychain-backed alternative that runs on your own API keys.

## How it works

Two hotkeys, backed by whichever provider you've configured:

| Hotkey   | Action                                                          |
| -------- | -------------------------------------------------------------- |
| `Caps+C` | Refine the clipboard contents, then paste the result.          |
| `Caps+S` | Refine the current selection, replacing it in place.           |

Hone binds into [QuickShots'](../quickshots) shared Caps (F18) event tap, so the
bindings never collide with normal typing. If QuickShots isn't loaded, it falls
back to standard global hotkeys: `Ctrl+Alt+Cmd+R` (clipboard) and
`Ctrl+Alt+Cmd+S` (selection).

## Providers

Hone speaks to three backends. For manual refinement it uses OpenAI; for the
fast dictation-cleanup path it auto-picks the fastest provider whose key exists,
in order Cerebras → Groq → OpenAI.

| Provider | Models                        | Notes                                  |
| -------- | ----------------------------- | -------------------------------------- |
| OpenAI   | `gpt-5.4`, `gpt-5.4-nano`     | Responses API. Works everywhere.       |
| Groq     | `llama-3.3-70b`               | Optional. Faster cleanup.              |
| Cerebras | `gemma-4-31b`                 | Optional. Fastest cleanup.             |

Adding a Groq or Cerebras key drops cleanup latency from roughly 1.3–2s down to
0.3–0.7s. At least one provider is required; OpenAI is the safe default.

## Install

From the repo root:

```sh
apps/hone/install.sh
apps/hone/setup-keys.sh
```

The installer copies `hone.lua` into `~/.hammerspoon` and wires up the loader.
`setup-keys.sh` then stores your API keys (see below).

## API keys

Keys are read from the macOS Keychain — one service name per provider:

| Provider | Keychain service |
| -------- | ---------------- |
| OpenAI   | `openai-refine`  |
| Groq     | `groq-api`       |
| Cerebras | `cerebras-api`   |

No key is ever written to the repo. Run `apps/hone/setup-keys.sh` to store them;
it uses the macOS `security` prompt, so keys never touch your shell history,
process arguments, or any file. Re-run it any time to update a key.

## Permissions

Hone needs macOS **Accessibility** access (granted to Hammerspoon) to read the
current selection and to paste. macOS prompts the first time; enable it under
System Settings → Privacy & Security → Accessibility, then reload Hammerspoon.

## Configuration

Set `require("hone").config` fields in your private
`~/.hammerspoon/loadout.local.lua` (see [local configuration](../../SETUP.md#local-configuration)):

- **`vocabulary`** — a list of names, brands, and jargon the model is told to
  correct toward (for example `"post gres"` → `"Postgres"`).
- **Shared glossary** — if Murmur is installed, Hone also reads its glossary at
  `~/.hammerspoon/murmur/dictation_glossary.txt`, so both apps bias corrections
  toward the same custom terms.

Both are optional; leave `vocabulary` empty for a plain rewrite.

## About

Hone is part of the **Loadout** suite. See the [Loadout README](../../README.md)
for the other tools.

Licensed under [MIT](./LICENSE).
