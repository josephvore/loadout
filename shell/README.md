# shell

An optional, personal zsh setup shared as an example — not one of the Loadout
apps. Read `.zshrc` before installing and delete anything you don't want.

## What's here

| File | Installed at | Purpose |
|---|---|---|
| `.zshrc` | `~/.zshrc` | interactive shell — prompt, fzf, aliases, completion, plugins |
| `.zprofile` | `~/.zprofile` | login shell — Homebrew, pyenv, bun, ulimit |
| `.zshenv.example` | copied to `~/.zshenv` only if absent | all shells — cargo, bun on PATH |

Every tool integration is guarded, so shells won't error on a machine that doesn't
have the tool installed. See [../PREREQUISITES.md](../PREREQUISITES.md) for the
optional tool list (and the [Brewfile](../Brewfile) to install them).

## Install

```sh
./install.sh          # or, from the repo root:  ./bootstrap.sh --with-shell
```

Idempotent; backs up existing `~/.zshrc` and `~/.zprofile` before linking them.
An existing `~/.zshenv` is always preserved, including symlinks. New environment
files are private copies with owner-only permissions; they never link into Git.
Open a new terminal (or `source ~/.zshrc`) to load it.

## Private settings

Keep credentials in the macOS Keychain or your private `~/.zshenv`. Never put
secrets in the tracked `.zshenv.example`, `.zshrc`, or `.zprofile` files.
Personal aliases, paths, certificate overrides, and other preferences belong in
`~/.zshrc.local` or `~/.zprofile.local`; the shared config loads them automatically.
These filenames and `.zshenv` are ignored at every depth of this repository.

If an older installation linked `~/.zshenv` to a tracked file, preserve its
contents in a private regular file outside the repo and replace the symlink
with that file (mode `600`). Remove the old target from Git tracking and check
staged changes before committing. The installer preserves existing environments
rather than performing this migration automatically.
