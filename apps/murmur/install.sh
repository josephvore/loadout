#!/usr/bin/env bash
# Install Murmur (on-device dictation) into ~/.hammerspoon.
# Idempotent. Backs up anything it would replace; never clobbers your data.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
. "${DIR}/../../lib/install-common.sh"

# Shared loader + logging.
ld_install_core "${DIR}/../.."

# Module + pure core.
ld_link "${DIR}/murmur.lua"      "${HAMMER_DIR}/murmur.lua"
ld_link "${DIR}/murmur_core.lua" "${HAMMER_DIR}/murmur_core.lua"

# Example data — copied (not linked) so your edits/auto-learned terms stay
# local and are never overwritten on re-install.
ld_copy_if_absent "${DIR}/data/dictation_glossary.txt"    "${HAMMER_DIR}/murmur/dictation_glossary.txt"
ld_copy_if_absent "${DIR}/data/dictation_corrections.tsv" "${HAMMER_DIR}/murmur/dictation_corrections.tsv"
ld_copy_if_absent "${DIR}/data/dictation_snippets.tsv"    "${HAMMER_DIR}/murmur/dictation_snippets.tsv"

# Daemon source, so it can be rebuilt from ~/.hammerspoon later. Link instead
# of deleting/copying the directory: re-installs are non-destructive and the
# checked-out source remains the single source of truth.
ld_link "${DIR}/hs-dictate" "${HAMMER_DIR}/murmur/hs-dictate"

# Build the Swift daemon into ~/bin/hs-dictate. Requires the Swift 6 toolchain
# (Xcode CLT) and the macOS 26 SDK — see PREREQUISITES.md. The links and data
# remain installed if the build fails, but this command returns a failure so a
# caller cannot mistake a degraded Murmur install for a working one.
echo
build_status=0
if command -v swift >/dev/null 2>&1; then
  echo "Building hs-dictate (the first build downloads Swift package sources; speech models download on first use)..."
  if "${HAMMER_DIR}/murmur/hs-dictate/build.sh"; then
    echo "Built ~/bin/hs-dictate"
  else
    build_status=1
    echo "WARNING: hs-dictate build failed. Fix the Swift toolchain, then run:" >&2
    echo "  ~/.hammerspoon/murmur/hs-dictate/build.sh" >&2
  fi
else
  build_status=1
  echo "WARNING: 'swift' not found — skipping the hs-dictate build." >&2
  echo "Install the Xcode Command Line Tools, then run:" >&2
  echo "  ~/.hammerspoon/murmur/hs-dictate/build.sh" >&2
fi

echo
ld_reload_hint
exit "$build_status"
