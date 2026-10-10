# Setup

The full checklist for putting Loadout on a fresh Mac. It's split into what an AI
coding agent (or `bootstrap.sh`) can do for you, and the handful of steps only a
human can do — granting macOS permissions, typing secret keys, and a keyboard
remap that needs a re-login.

## Hand it to an agent

Point an AI coding agent (Claude Code, etc.) at a clone of this repo with a prompt
like:

> Read SETUP.md and PREREQUISITES.md. Install any missing prerequisites you can
> (use Homebrew if it's already installed; do **not** install Homebrew itself —
> ask me to). Then run `./bootstrap.sh`. Stop and hand back to me for the
> human-only steps (API keys, Caps Lock remap, macOS permission grants), listing
> exactly what I need to click.

The agent can do everything in "Automatable" below. It cannot grant macOS
permissions, cannot type your API keys, and should not remap your keyboard without
your say-so — those are in "Human-only."

## Automatable

1. **Install prerequisites** that are missing (see [PREREQUISITES.md](PREREQUISITES.md)).
   With Homebrew already present:
   ```sh
   xcode-select --install                      # Swift toolchain (for Murmur)
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
   builds the dictation daemon (if the Swift toolchain is present), and clones +
   wires in QuickShots. It's idempotent and backs up anything it replaces.
3. **Run the tests** (optional sanity check):
   ```sh
   lua apps/murmur/tests/test_murmur.lua
   ```

## Human-only

1. **Add API keys** (for Hone refinement + Murmur's cleanup pass):
   ```sh
   apps/hone/setup-keys.sh
   ```
   You'll be prompted for each key by macOS `security` — they're stored in your
   Keychain, never in the repo. At least OpenAI; add Groq/Cerebras for speed.
2. **Remap Caps Lock to a modifier** (powers Caps+A, Caps+K, Caps+C, …):
   ```sh
   ~/code/quickshots/caps-setup.sh
   ```
   This remaps Caps Lock to F18 and installs a LaunchAgent so it survives reboots.
   Log out and back in (or reboot) for it to take full effect. Undo any time with
   `caps-uninstall.sh`.
3. **Grant Hammerspoon macOS permissions** — System Settings → Privacy & Security:
   - **Accessibility** — every hotkey, pasting, reading selection/context.
   - **Screen Recording** — QuickShots captures (screenshots come back blank
     without it).
   - **Microphone** — Murmur dictation.
   Then reload Hammerspoon (menu-bar icon → Reload Config).

## Verify it worked

- Menu bar shows the Hammerspoon icon; **Caps+K** opens the Palette menu listing
  every installed app's shortcuts.
- **Caps+A** starts a QuickShots drag-capture.
- Hold **Right-Command** and speak — Murmur transcribes and pastes on release.
- **Caps+C** refines the clipboard via Hone.

If an app doesn't load, open the Hammerspoon Console or check
`~/.hammerspoon/logs/init.log` — each app logs whether it loaded.

## Local configuration

Keep your own paths, account settings, and device choices outside tracked files.
Create `~/.hammerspoon/loadout.local.lua`; the loader runs it before apps start
and before Palette applies saved hotkey bindings. For example:

```lua
local relay = require("relay").config
relay.quickCaptureFile = os.getenv("HOME") .. "/Documents/Notes/Inbox.md"

local murmur = require("murmur").config
murmur.preferredInputDevices = {} -- system default; or list your device names
murmur.contentHint = "default" -- "far-field" for a distant microphone

-- Set require("hone").config.model to a model available to your account.
```

Only configure apps you installed. API keys belong in the macOS Keychain via
`apps/hone/setup-keys.sh`, not in Lua files. Edit vocabulary and snippets in
`~/.hammerspoon/murmur/`; the repository's data files are generic examples.

For shell settings, use `~/.zshrc.local`, `~/.zprofile.local`, and a private
`~/.zshenv` (see [shell setup](shell/README.md)). These local filenames are
ignored by Git even if accidentally placed inside a checkout.
