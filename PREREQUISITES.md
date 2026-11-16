# Prerequisites

Loadout doesn't install system software for you — it tells you what's missing and
stops short of touching your machine. Install what you need from this list, then
run `./bootstrap.sh`. Everything here is a one-time setup.

## Base Hammerspoon apps

Hone, Palette, and Relay do not require Murmur's newer speech stack. To install
any of them on its own, start with these base system requirements, then follow
that app's README for permissions, keys, or optional integrations:

| Need | Why | Install |
|---|---|---|
| **macOS 13 or later** | supported baseline for the base utilities | System Settings → General → Software Update |
| **[Hammerspoon](https://www.hammerspoon.org) 1.1.1+** | app runtime | `brew install --cask hammerspoon` |
| **git** | clones the repository | included with the Xcode Command Line Tools; run `xcode-select --install` if `git --version` is unavailable |

## Additional requirements for the full suite

| Need | Why | Install |
|---|---|---|
| **macOS 26 or later** | Murmur uses SpeechAnalyzer and the macOS 26 SDK | System Settings → General → Software Update |
| **Apple Silicon (tested)** | Murmur's on-device speech stack is verified on arm64; Intel is currently unverified | check with `uname -m` (`arm64` is the tested result) |
| **2 GB free storage** | SwiftPM build cache plus about 600 MB of speech models | check with `df -h "$HOME"` |

[Homebrew](https://brew.sh) is the recommended installer, not an application
runtime. Install Homebrew yourself, then use the commands in this document.

## Required to build Murmur's dictation daemon

| Need | Why | Install |
|---|---|---|
| **Xcode 26 Command Line Tools** | Swift 6 + macOS 26 SDK to build `hs-dictate` | `xcode-select --install` (finish the macOS dialog before continuing) |

Verify the toolchain before bootstrapping:

```sh
swift --version                         # Apple Swift 6.x
xcrun --sdk macosx --show-sdk-version  # 26.x
```

The first **build** downloads the
[FluidAudio](https://github.com/FluidInference/FluidAudio) Swift package and its
dependencies into SwiftPM's build cache. The first **Murmur launch** downloads
the roughly 480 MB batch model and 120 MB streaming model to
`~/Library/Application Support/FluidAudio/`. Audio and speech recognition stay
local; only optional LLM cleanup sends text to a provider.

If the daemon build fails, bootstrap finishes the other installs and exits 1.
Fix the toolchain, run `~/.hammerspoon/murmur/hs-dictate/build.sh`, then re-run
`./bootstrap.sh`.

## Required only for tests

| Need | Why | Install |
|---|---|---|
| **Lua 5.4+** | Murmur tests and Lua parse checks | `brew install lua` |
| **ShellCheck** | shell safety checks | `brew install shellcheck` |
| **zsh** | bare-shell smoke test | included with macOS |

## Optional

| Need | Why | Install |
|---|---|---|
| **[Raycast](https://raycast.com)** | Reap's dropdown UI; Relay's optional deeplink | `brew install --cask raycast` |
| **[OpenAI key](https://platform.openai.com/api-keys)** | Hone manual refinement and optional Murmur cleanup | store with `apps/hone/setup-keys.sh` |
| **[Groq key](https://console.groq.com/keys)** | optional Murmur cleanup provider | store with `apps/hone/setup-keys.sh` |
| **[Cerebras key](https://cloud.cerebras.ai/)** | optional Murmur cleanup provider | store with `apps/hone/setup-keys.sh` |

Murmur works without a key and can stay fully local; Hone's manual refinement
requires an OpenAI key. Loadout does not use API-key environment variables or an
`.env` file. Keys live in macOS Keychain. Provider billing, retention, and usage
policies apply to the text sent to them.

## Optional — for the shell config (`--with-shell`)

The zsh config expects these but degrades gracefully when they're absent. Install
them with Homebrew, or run `brew bundle` against the repo's [Brewfile](Brewfile):

```sh
brew bundle --file=Brewfile
```

CLI tools: `fzf`, `eza`, `zoxide`, `fnm`, `pyenv`, `direnv`, `bat`, and `fd`.
Shell integrations: `pure`, `zsh-autosuggestions`, `zsh-completions`, and
`zsh-syntax-highlighting`. The Brewfile includes all of them plus the test tools.
[Oh My Zsh](https://ohmyz.sh) is optional and installed via its own instructions.
Every integration is guarded; missing optional tools leave the stock command or
prompt in place.
