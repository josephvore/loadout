#!/usr/bin/env bash
# Shared install helpers for Loadout apps. Source this from an app's install.sh:
#
#   DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${DIR}/../../lib/install-common.sh"
#   ld_install_core "${DIR}/../.."          # canonical init.lua + litelog
#   ld_link "${DIR}/murmur.lua" "${HAMMER_DIR}/murmur.lua"
#
# Everything here is idempotent and non-destructive: real files are backed up
# (once, timestamped) before being replaced with a symlink; user data files are
# copied only if absent, never clobbered.
set -euo pipefail

HAMMER_DIR="${HOME}/.hammerspoon"
LD_BACKUP_DIR="${HOME}/.loadout-backup-$(date +%Y%m%d-%H%M%S)"

# Symlink src -> dest. Backs up an existing real file first. Idempotent.
ld_link() {
  local src="$1" dest="$2"
  if [ ! -e "$src" ]; then echo "skip (missing in repo): $src"; return; fi
  mkdir -p "$(dirname "$dest")"
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    echo "ok (already linked): $dest"; return
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    mkdir -p "$LD_BACKUP_DIR"
    mv "$dest" "${LD_BACKUP_DIR}/$(basename "$dest")"
    echo "backed up existing: $dest -> ${LD_BACKUP_DIR}/"
  fi
  ln -s "$src" "$dest"
  echo "linked: $dest -> $src"
}

# Copy src -> dest only if dest does not already exist. For user-editable data
# (glossaries, snippets) that the app also writes to — never overwrite it.
ld_copy_if_absent() {
  local src="$1" dest="$2"
  if [ ! -e "$src" ]; then echo "skip (missing in repo): $src"; return; fi
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ]; then
    echo "keep (already present): $dest"
  else
    cp "$src" "$dest"
    echo "installed data: $dest"
  fi
}

# Install the pieces every Loadout app shares: the canonical loader and litelog.
# Safe to call from multiple app installers — the links are identical.
ld_install_core() {
  # Canonicalize the root so the symlink target is a clean absolute path (not
  # one containing ".." from the calling app's dir) — otherwise every app would
  # re-link the shared files with a different-looking target and churn backups.
  local root; root="$(cd "$1" && pwd)"
  ld_link "${root}/hammerspoon/init.lua"    "${HAMMER_DIR}/init.lua"
  ld_link "${root}/lib/litelog/litelog.lua" "${HAMMER_DIR}/litelog.lua"
}

# Ask Hammerspoon to reload its config, if the `hs` CLI is available.
ld_reload_hint() {
  if command -v hs >/dev/null 2>&1; then
    hs -c 'hs.reload()' >/dev/null 2>&1 && echo "Reloaded Hammerspoon config." && return
  fi
  echo "Reload Hammerspoon (menu-bar icon -> Reload Config) to pick up changes."
}
