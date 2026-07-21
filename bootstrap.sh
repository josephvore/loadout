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
[ -d "/Applications/Hammerspoon.app" ] \
  || echo "  ! Hammerspoon not found — install it: https://www.hammerspoon.org"
command -v git   >/dev/null 2>&1 || echo "  ! git not found (needed to fetch QuickShots)"
command -v swift >/dev/null 2>&1 \
  || echo "  ! swift not found — Murmur's daemon won't build until you install Xcode CLT"

# 2. Hammerspoon apps. Each installer links the shared loader + litelog, so
#    running them in any order converges to the same state. Hone before Murmur
#    (Hone is Murmur's cleanup engine).
echo "-- installing apps --"
"${ROOT}/apps/hone/install.sh"
"${ROOT}/apps/murmur/install.sh"
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
    git clone "${QUICKSHOTS_REPO}" "${QUICKSHOTS_DIR}"
  else
    echo "-- QuickShots already present at ${QUICKSHOTS_DIR} --"
  fi
  ld_link "${QUICKSHOTS_DIR}/quickshots.lua" "${HAMMER_DIR}/quickshots.lua"
else
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
1. API keys (Hone refine + Murmur cleanup):
     ${ROOT}/apps/hone/setup-keys.sh
2. Caps Lock as a modifier (QuickShots / Hone / Palette hotkeys):
     ${QUICKSHOTS_DIR}/caps-setup.sh        # remaps Caps -> F18; survives reboot
3. Grant Hammerspoon macOS permissions (System Settings > Privacy & Security):
     - Accessibility     (hotkeys + pasting)
     - Screen Recording  (QuickShots captures)
     - Microphone        (Murmur dictation)

Full checklist: SETUP.md
EOF
