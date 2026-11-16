#!/usr/bin/env bash
# Loadout bootstrap — install the whole suite into ~/.hammerspoon.
#
# Idempotent and non-destructive: safe to re-run. Checks for prerequisites and
# tells you what's missing — it never installs system software for you (install
# Homebrew, Hammerspoon, etc. yourself; see PREREQUISITES.md).
#
# Usage:
#   ./bootstrap.sh                     # install the Hammerspoon apps + QuickShots
#   ./bootstrap.sh --with-shell        # also symlink the zsh config
#   ./bootstrap.sh --quickshots-dir=DIR
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/install-common.sh"

WITH_SHELL=0
MURMUR_FAILED=0
QUICKSHOTS_FAILED=0
HAMMERSPOON_MISSING=0
QUICKSHOTS_DIR="${HOME}/code/quickshots"
QUICKSHOTS_REPO="https://github.com/josephvore/quickshots.git"

for arg in "$@"; do
  case "$arg" in
    --with-shell) WITH_SHELL=1 ;;
    --quickshots-dir=*) QUICKSHOTS_DIR="${arg#*=}" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "== Loadout bootstrap =="

# 1. Prerequisites — report only, never install.
echo "-- checking prerequisites --"
[ -d "/Applications/Hammerspoon.app" ] || [ -d "${HOME}/Applications/Hammerspoon.app" ] || {
  HAMMERSPOON_MISSING=1
  echo "  ! Hammerspoon not found — install it: https://www.hammerspoon.org"
}
command -v git   >/dev/null 2>&1 || echo "  ! git not found (needed to fetch QuickShots)"
command -v swift >/dev/null 2>&1 \
  || echo "  ! swift not found — Murmur's daemon won't build until you install Xcode CLT"

# 2. Hammerspoon apps. Each installer links the shared loader + litelog, so
#    running them in any order converges to the same state. Hone before Murmur
#    (Hone is Murmur's cleanup engine).
echo "-- installing apps --"
"${ROOT}/apps/hone/install.sh"
if ! "${ROOT}/apps/murmur/install.sh"; then
  MURMUR_FAILED=1
  echo "WARNING: Murmur is linked but its daemon did not build; continuing with the other apps." >&2
fi
"${ROOT}/apps/relay/install.sh"
"${ROOT}/apps/palette/install.sh"
"${ROOT}/apps/reap/install.sh"

# 3. QuickShots — its own repo; clone (or reuse) then link its module. The
#    canonical init.lua already loads it, so we do NOT run QuickShots' own
#    installer (which would append a duplicate loader).
if command -v git >/dev/null 2>&1; then
  if [ ! -d "${QUICKSHOTS_DIR}/.git" ]; then
    echo "-- cloning QuickShots into ${QUICKSHOTS_DIR} --"
    mkdir -p "$(dirname "${QUICKSHOTS_DIR}")"
    if ! git clone "${QUICKSHOTS_REPO}" "${QUICKSHOTS_DIR}"; then
      QUICKSHOTS_FAILED=1
      echo "WARNING: QuickShots could not be cloned; continuing with the other apps." >&2
    fi
  else
    echo "-- QuickShots already present at ${QUICKSHOTS_DIR} --"
  fi
  if [ -e "${QUICKSHOTS_DIR}/quickshots.lua" ]; then
    ld_link "${QUICKSHOTS_DIR}/quickshots.lua" "${HAMMER_DIR}/quickshots.lua"
  else
    QUICKSHOTS_FAILED=1
    echo "WARNING: QuickShots source is missing: ${QUICKSHOTS_DIR}/quickshots.lua" >&2
  fi
else
  QUICKSHOTS_FAILED=1
  echo "-- skipping QuickShots (git unavailable) --"
fi

# 4. Shell config (opt-in).
if [ "${WITH_SHELL}" -eq 1 ]; then
  echo "-- installing shell config --"
  "${ROOT}/shell/install.sh"
fi

# 5. Reload + the steps only you can do.
echo
ld_reload_hint
cat <<EOF

== Almost there — a few steps only you can do ==
1. Optional API keys (Hone refine + Murmur's cloud cleanup; see privacy notes):
     ${ROOT}/apps/hone/setup-keys.sh
2. Launch Hammerspoon, then grant macOS permissions:
     open -a Hammerspoon
     Accessibility (hotkeys + pasting), Screen Recording (QuickShots),
     and Microphone (Murmur) under System Settings > Privacy & Security.
3. Caps Lock as a modifier (QuickShots / Hone / Palette hotkeys):
     ${QUICKSHOTS_DIR}/caps-setup.sh        # remaps Caps -> F18; survives reboot
4. For Reap's Raycast dropdown, add this Script Directory in Raycast Settings:
     ${HOME}/.config/raycast/scripts

Full checklist: SETUP.md
EOF

if [ "$HAMMERSPOON_MISSING" -ne 0 ] || [ "$MURMUR_FAILED" -ne 0 ] \
    || [ "$QUICKSHOTS_FAILED" -ne 0 ]; then
  echo >&2
  echo "Bootstrap finished with degraded components:" >&2
  [ "$HAMMERSPOON_MISSING" -eq 0 ] || echo "  - Hammerspoon is not installed." >&2
  [ "$MURMUR_FAILED" -eq 0 ] || echo "  - Murmur's daemon did not build." >&2
  [ "$QUICKSHOTS_FAILED" -eq 0 ] || echo "  - QuickShots is not installed." >&2
  echo "Fix the items above and re-run ./bootstrap.sh." >&2
  exit 1
fi
