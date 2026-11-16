#!/usr/bin/env bash
# Install Unsub (Caps+U: unsubscribe from the selected Apple Mail message)
# into ~/.hammerspoon. Idempotent. Backs up anything it would replace.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
. "${DIR}/../../lib/install-common.sh"

ld_install_core "${DIR}/../.."
ld_link "${DIR}/unsub.lua" "${HAMMER_DIR}/unsub.lua"
ld_link "${DIR}/unsub.py" "${HAMMER_DIR}/unsub.py"

echo
echo "Select an email in Apple Mail and press Caps+U (Ctrl+Alt+Cmd+U without the"
echo "Caps tap). The first run asks to let Hammerspoon control Mail."
echo "Optional: store an OpenAI key with apps/hone/setup-keys.sh so Unsub can"
echo "judge unfamiliar unsubscribe pages. Dry run: open -g 'hammerspoon://unsub'"
echo
ld_reload_hint
