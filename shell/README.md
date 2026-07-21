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

```sh
./install.sh          # or, from the repo root:  ./bootstrap.sh --with-shell
```

Idempotent; backs up any existing `~/.zshrc`, `~/.zprofile`, or `~/.zshenv` first.
Open a new terminal (or `source ~/.zshrc`) to load it.
