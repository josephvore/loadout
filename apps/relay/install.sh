#!/usr/bin/env bash
# Install Relay (quick-launch / voice flows) into ~/.hammerspoon.
# Idempotent. Backs up anything it would replace.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
. "${DIR}/../../lib/install-common.sh"

ld_install_core "${DIR}/../.."
ld_link "${DIR}/relay.lua" "${HAMMER_DIR}/relay.lua"

echo
echo "Edit the config block at the top of relay.lua to point quickCaptureFile"
echo "at your notes inbox. Relay launches Claude Code permission-respecting by"
echo "default; see claudeDangerouslySkipPermissions to opt into the fast path."
echo
ld_reload_hint
