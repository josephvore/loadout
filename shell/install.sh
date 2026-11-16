#!/usr/bin/env bash
# Symlink the zsh config into place. Idempotent; backs up existing real files.
#
# This is a personal shell setup shared as an example — read .zshrc before you
# install it and delete anything you don't want. It expects a number of tools
# (oh-my-zsh, fzf, eza, zoxide, fnm, pyenv, direnv, …) but degrades gracefully
# when they're absent. See ../PREREQUISITES.md.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
. "${DIR}/../lib/install-common.sh"

ld_link "${DIR}/.zshrc"    "${HOME}/.zshrc"
ld_link "${DIR}/.zprofile" "${HOME}/.zprofile"
# Environment files may hold credentials. Never link them into the repository
# or replace an existing environment (including a symlink).
if [ -e "${HOME}/.zshenv" ] || [ -L "${HOME}/.zshenv" ]; then
  echo "keep (private environment): ${HOME}/.zshenv"
else
  (umask 077; cp "${DIR}/.zshenv.example" "${HOME}/.zshenv")
  echo "created private environment: ${HOME}/.zshenv"
fi

echo
echo "Open a new terminal (or 'source ~/.zshrc') to load the new shell config."
