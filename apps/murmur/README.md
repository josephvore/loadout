# Murmur

On-device, push-to-talk voice-to-text for macOS, with an LLM cleanup pass that
polishes each take before it pastes. A free, open-source replacement for Wispr
Flow, Superwhisper, and MacWhisper.

Hold a key, speak, release — the transcript lands in whatever app has focus.
Capture and transcription run entirely on your Mac; the optional cleanup step is
the only part that can reach the network (see [On-device vs. cloud](#on-device-vs-cloud)).

## How it works

Speech-to-text runs locally through `~/bin/hs-dictate`, a small Swift daemon.
While you speak, Apple's SpeechAnalyzer / SpeechTranscriber (macOS 26) streams
live partials into an on-screen pill. On stop, Parakeet TDT re-reads the take's
audio for a markedly more accurate final transcript (CoreML on the Neural
Engine), falling back to Apple's text automatically. Both models come from the
[FluidAudio](https://github.com/FluidInference/FluidAudio) SwiftPM package and
download on first run (~570MB total) to `~/Library/Application Support/FluidAudio/`.

The daemon stays warm between takes with the models loaded and the mic engine
hot, so takes start instantly and work offline.

## Hotkeys

| Key | Action |
| --- | --- |
| Hold **Right ⌘**, speak, release | Push-to-talk: transcribe and paste |
| Tap **Right ⌘** | Hands-free: keep listening until you tap Right ⌘ again |
| **Esc** | Cancel the current take and discard it |

Murmur watches Right ⌘ with its own `flagsChanged` event tap. A short press
counts as a tap (hands-free); a longer press is a hold. Pressing any other key
while Right ⌘ is down means you were typing a normal ⌘-shortcut, so dictation
silently cancels and the shortcut goes through untouched.

## On-device vs. cloud

Capture and transcription are fully on-device — no audio ever leaves your Mac.
The **optional cleanup pass is the exception**: it sends the transcript *text*
to a cloud LLM (via the sibling app [Hone](../hone), which supports
OpenAI / Groq / Cerebras) to fix fillers, false starts, and punctuation.

To stay fully local, use the **Literal** profile or disable AI cleanup. Nothing
is sent to the network in that mode.

### Cleanup profiles

- **Auto** — pick the treatment based on context.
- **Prompt** — tuned for prompts and instructions.
- **Message** — tuned for chat and email.
- **Literal** — no AI cleanup; local polish only, fully on-device.

## Requirements

- macOS 26 or later.
- [Hammerspoon](https://www.hammerspoon.org).
- Xcode Command Line Tools (Swift 6 toolchain) to build the daemon.
- API key(s) for the cleanup pass — optional but recommended. Set them via
  Hone's `setup-keys.sh`.

## Install

From the repo root:

```sh
apps/murmur/install.sh
```

The installer symlinks the module into `~/.hammerspoon`, copies the example data
files, and builds the Swift daemon into `~/bin/hs-dictate`. If the Swift
toolchain isn't ready yet, the rest of the install still completes — build the
daemon later with:

```sh
~/.hammerspoon/murmur/hs-dictate/build.sh
```

Then load Murmur from `~/.hammerspoon/init.lua`:

```lua
pcall(function() require("murmur").start() end)
```

### Permissions

macOS will prompt the first time things run. Grant Hammerspoon:

- **Accessibility** — to paste and to read the surrounding context.
- **Microphone** — to capture audio.

## Configuration

Murmur uses your system microphone. Set device preferences and other overrides
in `~/.hammerspoon/loadout.local.lua`, not the linked module; see
[local configuration](../../SETUP.md#local-configuration).

## Data files

Your personal dictation data lives in `~/.hammerspoon/murmur/`:

- `dictation_glossary.txt` — canonical spellings of names and terms.
- `dictation_corrections.tsv` — learned "wrong → right" replacements.
- `dictation_snippets.tsv` — text expansions.

Murmur auto-learns frequently-seen proper nouns into the glossary so the
recognizer stops mishearing them. These files are copied on install and are
**never overwritten** on re-install, so your edits and learned terms stay put.

## Tests

```sh
lua apps/murmur/tests/test_murmur.lua
```

## About

Murmur is part of the [Loadout](../../README.md) suite. Licensed under
[MIT](./LICENSE).
