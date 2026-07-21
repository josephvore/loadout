# Prerequisites

Loadout doesn't install system software for you — it tells you what's missing and
stops short of touching your machine. Install what you need from this list, then
run `./bootstrap.sh`. Everything here is a one-time setup.

## Required for the core apps

| Need | Why | Install |
|---|---|---|
| **macOS 26+** | Murmur uses Apple's on-device SpeechAnalyzer | — |
| **[Homebrew](https://brew.sh)** | package manager for the tools below | see brew.sh (run their install script yourself) |
| **[Hammerspoon](https://www.hammerspoon.org)** | runtime for QuickShots, Murmur, Hone, Relay, Palette | `brew install --cask hammerspoon` |
| **git** | clones QuickShots during bootstrap | ships with the Xcode CLT below |

## Required to build Murmur's dictation daemon

| Need | Why | Install |
|---|---|---|
| **Xcode Command Line Tools** | Swift 6 toolchain + macOS SDK to build `hs-dictate` | `xcode-select --install` |

The first Murmur build downloads the [FluidAudio](https://github.com/FluidInference/FluidAudio)
package and its speech models (~570MB) to `~/Library/Application Support/FluidAudio/`.
If the toolchain is missing, bootstrap installs everything else and skips this build;
run `~/.hammerspoon/murmur/hs-dictate/build.sh` once the tools are in place.

## Optional

| Need | Why | Install |
|---|---|---|
| **[Raycast](https://raycast.com)** | Reap's dropdown UI; Relay's dictation deeplink | `brew install --cask raycast` |
| **API key** — OpenAI (and/or Groq, Cerebras) | Hone refinement + Murmur's cleanup pass | provider dashboards; store with `apps/hone/setup-keys.sh` |

Murmur and Hone work without keys in a limited way (Murmur can paste raw transcripts
via the "Literal" profile), but the LLM cleanup/refine features need at least one key.

## Optional — for the shell config (`--with-shell`)

The zsh config expects these but degrades gracefully when they're absent. Install
them with Homebrew, or run `brew bundle` against the repo's [Brewfile](Brewfile):

```sh
brew bundle --file=Brewfile
```

CLI tools: `fzf`, `eza`, `zoxide`, `fnm`, `pyenv`, `direnv`, `bat`, `fd`.
Also [Oh My Zsh](https://ohmyz.sh) and the [Pure](https://github.com/sindresorhus/pure)
prompt (installed per their own instructions, not via Homebrew).
