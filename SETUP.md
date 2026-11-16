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
   builds the dictation daemon and the shared settings tool, and clones + wires
   in QuickShots. It's idempotent
   and backs up anything it replaces. `~/loadout` is only the documented
   default; clone anywhere, but keep the clone where it is afterward, because
   its files are the symlink targets. A Murmur build failure returns exit 1
   after the other apps install.
3. **Run the tests** (optional sanity check):
   ```sh
   ./test.sh
   ```

## Human-only

1. **Add API keys** (for Hone refinement, Murmur's optional cleanup pass, and
   Unsub's optional page judging):
   ```sh
   apps/hone/setup-keys.sh
   ```
   Create an [OpenAI key](https://platform.openai.com/api-keys) for Hone's manual
   refinement hotkeys; Unsub uses the same key. Optionally add [Groq](https://console.groq.com/keys) or
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
   - **Automation → Mail** — Unsub; macOS asks the first time you press Caps+U.
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
- Hold **Caps+M** and speak — Murmur transcribes and pastes when you release
  Caps (tap Caps+M for hands-free; Right-Command is the fallback if the Caps
  tap is unavailable). The first use downloads about 600 MB of speech models;
  keep at least 2 GB free for models and build caches.
- **Caps+C** refines the clipboard via Hone.
- Select a newsletter in Apple Mail and run `open -g "hammerspoon://unsub"` —
  Unsub reports, without acting, how it would unsubscribe.

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

Most options can also be changed in Caps+K → an app → **Settings**, which
saves them to `~/.hammerspoon/settings/<app>.json` (the main options) or
Hammerspoon's `hs.settings` (the **Advanced** options and key bindings).
Values saved there are applied after this file runs, so they win for the same
key; only values you changed from their defaults are saved. Don't edit the
`.lua` files linked into `~/.hammerspoon`: they are your git checkout.

### Private apps

The same file can start modules of your own and list their shortcuts in
Caps+K. Put `myapp.lua` (a module with a `start()` function and a `config`
table) in `~/.hammerspoon`, then:

```lua
require("palette").addApp(
  { id = "myapp", name = "Does X", product = "MyApp" },
  { { id = "myapp.go", module = "myapp", path = { "capsGo" }, kind = "caps",
      label = "Do X", desc = "Runs MyApp's main action",
      run = function(m) m.go() end } })

return { apps = { "myapp" } } -- started after the built-in apps
```

`path` points at the `{ mods, key }` binding in `myapp`'s `config`, so Caps+K
shows its live key and can rebind it. Keep the `return` as the file's last
statement.

For shell settings, use `~/.zshrc.local`, `~/.zprofile.local`, and a private
`~/.zshenv` (see [shell setup](shell/README.md)). These local filenames are
ignored by Git even if accidentally placed inside a checkout.
