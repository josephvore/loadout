#!/usr/bin/env bash
# Install Hone (AI text refinement) into ~/.hammerspoon.
# Idempotent. Backs up anything it would replace.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
. "${DIR}/../../lib/install-common.sh"

ld_install_core "${DIR}/../.."
ld_link "${DIR}/hone.lua" "${HAMMER_DIR}/hone.lua"

echo
echo "Hone reads API keys from the macOS Keychain — no key is stored in the repo."
echo "Add OpenAI for Hone's manual hotkeys; Groq/Cerebras are optional"
echo "alternatives for Murmur's dictation cleanup:"
echo "  ${DIR}/setup-keys.sh"
echo
ld_reload_hint
