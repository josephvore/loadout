#!/usr/bin/env bash
# Install Palette (Caps+K searchable shortcut menu) into ~/.hammerspoon.
# Idempotent. Backs up anything it would replace.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${DIR}/../../lib/install-common.sh"

ld_install_core "${DIR}/../.."
ld_link "${DIR}/palette.lua" "${HAMMER_DIR}/palette.lua"

echo
echo "Palette lists every Loadout shortcut it finds installed. Press Caps+K"
echo "(or Ctrl+Alt+Cmd+K if the Caps tap isn't active) to open it."
echo
ld_reload_hint
