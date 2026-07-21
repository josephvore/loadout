#!/usr/bin/env bash
# Install Murmur (on-device dictation) into ~/.hammerspoon.
# Idempotent. Backs up anything it would replace; never clobbers your data.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Daemon source, so it can be rebuilt from ~/.hammerspoon later.
rm -rf "${HAMMER_DIR}/murmur/hs-dictate"
mkdir -p "${HAMMER_DIR}/murmur/hs-dictate"
cp -R "${DIR}/hs-dictate/" "${HAMMER_DIR}/murmur/hs-dictate/"

# Build the Swift daemon into ~/bin/hs-dictate. Requires the Swift 6 toolchain
# (Xcode CLT) and the macOS 26 SDK — see PREREQUISITES.md. Non-fatal: if the
# toolchain is missing, the rest of the install still completes.
echo
if command -v swift >/dev/null 2>&1; then
  echo "Building hs-dictate (first build downloads FluidAudio + models; this takes a while)..."
  if "${HAMMER_DIR}/murmur/hs-dictate/build.sh"; then
    echo "Built ~/bin/hs-dictate"
  else
    echo "WARNING: hs-dictate build failed. Fix the Swift toolchain, then run:" >&2
    echo "  ~/.hammerspoon/murmur/hs-dictate/build.sh" >&2
  fi
else
  echo "WARNING: 'swift' not found — skipping the hs-dictate build." >&2
  echo "Install the Xcode Command Line Tools, then run:" >&2
  echo "  ~/.hammerspoon/murmur/hs-dictate/build.sh" >&2
fi

echo
ld_reload_hint
