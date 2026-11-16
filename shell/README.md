# shell

An optional, personal zsh setup shared as an example — not one of the Loadout
apps. Read `.zshrc` before installing and delete anything you don't want.

## What's here

| File | Symlinked to | Purpose |
|---|---|---|
| `.zshrc` | `~/.zshrc` | interactive shell — prompt, fzf, aliases, completion, plugins |
| `.zprofile` | `~/.zprofile` | login shell — Homebrew, pyenv, bun, ulimit |
| `.zshenv` | `~/.zshenv` | all shells — cargo, bun on PATH |

Every tool integration is guarded, so shells won't error on a machine that doesn't
have the tool installed. See [../PREREQUISITES.md](../PREREQUISITES.md) for the
optional tool list (and the [Brewfile](../Brewfile) to install them).

## Install

Review the optional dependencies in [PREREQUISITES.md](../PREREQUISITES.md), then
from the repository root:

```sh
git clone https://github.com/josephvore/loadout.git ~/loadout
cd ~/loadout
shell/install.sh      # or install the suite with: ./bootstrap.sh --with-shell
```

Idempotent; backs up any existing `~/.zshrc`, `~/.zprofile`, or `~/.zshenv` first.
Keep the clone because it is the live symlink target. Open a new terminal (or
`source ~/.zshrc`) to load it; `zsh -lic 'echo shell loaded'` should print
`shell loaded` without a missing-tool error. Verify all repository checks with
`./test.sh`; changes are recorded in the root [changelog](../CHANGELOG.md).
