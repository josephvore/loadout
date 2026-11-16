#!/usr/bin/env bash
# Run Loadout's deterministic checks without launching Hammerspoon or changing
# the user's configuration. ShellCheck is required unless explicitly skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_SHELLCHECK=0

for arg in "$@"; do
  case "$arg" in
    --skip-shellcheck) SKIP_SHELLCHECK=1 ;;
    -h|--help)
      echo "usage: ./test.sh [--skip-shellcheck]"
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT"

if command -v lua >/dev/null 2>&1; then
  LUA=lua
elif command -v lua5.4 >/dev/null 2>&1; then
  LUA=lua5.4
else
  echo "Lua 5.4+ is required (brew install lua)." >&2
  exit 1
fi
"$LUA" -e '
  local major, minor = _VERSION:match("Lua (%d+)%.(%d+)")
  assert(tonumber(major) > 5 or (tonumber(major) == 5 and tonumber(minor) >= 4),
    "Lua 5.4+ is required; found " .. _VERSION)
'

TEST_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/loadout-test.XXXXXX")"
cleanup() {
  case "$(basename "$TEST_SCRATCH")" in
    loadout-test.*) rm -rf "$TEST_SCRATCH" ;;
    *) echo "refusing to remove unexpected test path: $TEST_SCRATCH" >&2 ;;
  esac
}
trap cleanup EXIT

echo "-- whitespace integrity --"
git diff --check

echo "-- Murmur replay tests --"
"$LUA" apps/murmur/tests/test_murmur.lua

if command -v luac >/dev/null 2>&1; then
  LUAC=luac
elif command -v luac5.4 >/dev/null 2>&1; then
  LUAC=luac5.4
else
  echo "luac is required (it is installed with Lua)." >&2
  exit 1
fi

echo "-- Lua parse checks --"
while IFS= read -r file; do
  "$LUAC" -p "$file"
done < <(git ls-files '*.lua')

SHELL_FILES=(
  bootstrap.sh
  test.sh
  shell/install.sh
  lib/install-common.sh
  apps/hone/install.sh
  apps/hone/setup-keys.sh
  apps/murmur/install.sh
  apps/murmur/hs-dictate/build.sh
  apps/palette/install.sh
  apps/reap/install.sh
  apps/reap/reap.sh
  apps/relay/install.sh
)

echo "-- shell parse checks --"
for file in "${SHELL_FILES[@]}"; do
  bash -n "$file"
done

echo "-- installer scratch-home safety --"
env HOME="$TEST_SCRATCH/install-home" bash -s -- "$ROOT" "$TEST_SCRATCH" <<'INSTALL_SAFETY'
set -euo pipefail
root="$1"
scratch="$2"
data_dest="$HOME/.hammerspoon/murmur/dictation_glossary.txt"
broken_target="$scratch/must-not-be-created"
mkdir -p "$(dirname "$data_dest")"
ln -s "$broken_target" "$data_dest"
# shellcheck source=lib/install-common.sh
. "$root/lib/install-common.sh"
if ld_copy_if_absent \
    "$root/apps/murmur/data/dictation_glossary.txt" "$data_dest" \
    >/dev/null 2>&1; then
  echo "broken user-data symlink was accepted" >&2
  exit 1
fi
[ -L "$data_dest" ]
[ ! -e "$broken_target" ]
INSTALL_SAFETY

env HOME="$TEST_SCRATCH/managed-hammer-home" \
  bash -s -- "$ROOT" "$TEST_SCRATCH" <<'HAMMER_SAFETY'
set -euo pipefail
root="$1"
scratch="$2"
managed_hammer="$scratch/managed-hammer-target"
mkdir -p "$HOME" "$managed_hammer"
ln -s "$managed_hammer" "$HOME/.hammerspoon"
# shellcheck source=lib/install-common.sh
. "$root/lib/install-common.sh"
if ld_install_core "$root" >/dev/null 2>&1; then
  echo "symlinked Hammerspoon directory was accepted" >&2
  exit 1
fi
[ -z "$(find "$managed_hammer" -mindepth 1 -print -quit)" ]
HAMMER_SAFETY

echo "-- Reap stock-Bash dry run --"
if [ "$(uname -s)" = "Darwin" ]; then
  /bin/bash apps/reap/reap.sh dry
else
  bash apps/reap/reap.sh dry
fi

if command -v zsh >/dev/null 2>&1; then
  echo "-- bare-zsh startup smoke --"
  mkdir -p "$TEST_SCRATCH/zsh-home"
  # shellcheck disable=SC2016  # $1 expands inside the child zsh, not here
  env HOME="$TEST_SCRATCH/zsh-home" \
    BREW_PREFIX="$TEST_SCRATCH/no-homebrew" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    zsh -f -c 'source "$1"; eval "ls -d / >/dev/null"' \
    loadout-zsh "$ROOT/shell/.zshrc"
else
  echo "SKIP: zsh is unavailable."
fi

if [ "$SKIP_SHELLCHECK" -eq 1 ]; then
  echo "SKIP: ShellCheck explicitly disabled."
else
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "ShellCheck is required (brew install shellcheck)." >&2
    exit 1
  fi
  echo "-- ShellCheck --"
  shellcheck -x "${SHELL_FILES[@]}"
fi

echo "All Loadout checks passed."
