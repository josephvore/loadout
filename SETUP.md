# Setup

The full checklist for putting Loadout on a fresh Mac. It's split into what an AI
coding agent (or `bootstrap.sh`) can do for you, and the handful of steps only a
human can do — completing system installer dialogs, granting macOS permissions,
typing secret keys, and approving a keyboard remap.

## Hand it to an agent

Point an AI coding agent (Claude Code, etc.) at a clone of this repo with a prompt
like:

> Read SETUP.md and PREREQUISITES.md. Install any missing prerequisites you can
> (use Homebrew if it's already installed; do **not** install Homebrew itself —
> ask me to). You may trigger `xcode-select --install`, but stop while I finish
> its macOS dialog. Then run `./bootstrap.sh`. Hand back the remaining human-only
> steps (API keys, Caps Lock remap, macOS permission grants), listing exactly
> what I need to click.

The agent can perform the command-line work below, but the Xcode tools dialog is
a human gate inside that sequence. It also cannot grant macOS permissions, type
your API keys, or remap your keyboard without your say-so.

## Automatable

1. **Install prerequisites** that are missing (see [PREREQUISITES.md](PREREQUISITES.md)).
   With Homebrew already present:
   ```sh
   xcode-select --install                      # agent may trigger; human finishes dialog
   brew install --cask hammerspoon raycast
   ```
   Installing Homebrew itself is a human step (paste their script yourself).
2. **Clone and bootstrap:**
   ```sh
   git clone https://github.com/josephvore/loadout.git ~/loadout
   cd ~/loadout
   ./bootstrap.sh                 # add --with-shell to also link the zsh config
   ```
   This links every app into `~/.hammerspoon`, copies Murmur's example data,
   builds the dictation daemon, and clones + wires in QuickShots. It's idempotent
   and backs up anything it replaces. Keep the clone: its files are the symlink
   targets. A Murmur build failure returns exit 1 after the other apps install.
3. **Run the tests** (optional sanity check):
   ```sh
   ./test.sh
   ```

## Human-only

1. **Add API keys** (for Hone refinement + Murmur's optional cleanup pass):
   ```sh
   apps/hone/setup-keys.sh
   ```
   Create an [OpenAI key](https://platform.openai.com/api-keys) for Hone's manual
   refinement hotkeys. Optionally add [Groq](https://console.groq.com/keys) or
   [Cerebras](https://cloud.cerebras.ai/) for Murmur's cleanup path. macOS
   `security` prompts invisibly and stores them in Keychain. No `.env` file or
   API-key environment variable is used. Provider billing and data policies
   apply to text sent for cleanup.
   Murmur's default **Auto** profile uses cloud cleanup automatically when one
   of these keys is available. Select Murmur's **Literal** profile before
   dictating if you want transcripts to remain local while retaining Hone's
   manual refinement hotkeys.
2. **Launch Hammerspoon and grant permissions:**
   ```sh
   open -a Hammerspoon
   ```
   Optionally enable **Launch Hammerspoon at login** from its menu. In System
   Settings → Privacy & Security grant Hammerspoon:
   - **Accessibility** — hotkeys, pasting, and reading selection/context.
   - **Screen Recording** — QuickShots captures.
   - **Microphone** — Murmur dictation.
   Then reload Hammerspoon (menu-bar icon → Reload Config).
3. **Remap Caps Lock to a modifier** (powers Caps+A, Caps+K, Caps+C, …):
   ```sh
   ~/code/quickshots/caps-setup.sh
   ```
   This remaps Caps Lock to F18 and installs a LaunchAgent so it survives reboots.
   Log out and back in (or reboot) for it to take full effect. Undo any time with
   `caps-uninstall.sh`.
4. **Register Reap with Raycast** (optional dropdown UI): open Raycast Settings →
   Script Commands → **Add Script Directory**, then choose
   `~/.config/raycast/scripts`. Reap always works from the terminal without
   Raycast.

## Verify it worked

- Menu bar shows the Hammerspoon icon; **Caps+K** opens the Palette menu listing
  every installed app's shortcuts.
- **Caps+A** starts a QuickShots drag-capture.
- Hold **Right-Command** and speak — Murmur transcribes and pastes on release.
  The first use downloads about 600 MB of speech models; keep at least 2 GB free
  for models and build caches.
- **Caps+C** refines the clipboard via Hone.

If an app doesn't load, open the Hammerspoon Console or check
`~/.hammerspoon/logs/init.log` — each app logs whether it loaded.
