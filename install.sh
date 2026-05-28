#!/usr/bin/env bash
# Idempotent dotfiles installer: symlinks tracked configs into place.
# Re-runnable. Backs up any existing real file before replacing it with a link.
set -euo pipefail

DOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BK="${HOME}/.dotfiles-backup-${TS}"

# repo-relative-path  ->  absolute target in $HOME
link() {
  local src="${DOT}/$1" dest="$2"
  if [ ! -e "$src" ]; then echo "skip (missing in repo): $1"; return; fi
  mkdir -p "$(dirname "$dest")"
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    echo "ok (already linked): $dest"; return
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    mkdir -p "$BK"; mv "$dest" "${BK}/$(basename "$dest").$1.bak" 2>/dev/null \
      || cp -a "$dest" "${BK}/" && rm -rf "$dest"
    echo "backed up existing: $dest -> ${BK}/"
  fi
  ln -s "$src" "$dest"
  echo "linked: $dest -> $src"
}

link ".zshrc"                            "${HOME}/.zshrc"
link ".zprofile"                         "${HOME}/.zprofile"
link ".zshenv"                           "${HOME}/.zshenv"
link "hammerspoon/init.lua"              "${HOME}/.hammerspoon/init.lua"
link "hammerspoon/flows.lua"             "${HOME}/.hammerspoon/flows.lua"
link "raycast-scripts/kill-dev-servers.sh" "${HOME}/.config/raycast/scripts/kill-dev-servers.sh"

echo
echo "Done. QuickShots itself lives in its own repo (github.com/josephvore/quickshots)"
echo "and is symlinked separately: ~/.hammerspoon/quickshots.lua -> /Volumes/Code/quickshots/quickshots.lua"
