#!/usr/bin/env bash
# Install Reap (dev-server / MCP process reaper) as a Raycast Script Command.
# Idempotent. Backs up anything it would replace.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${DIR}/../../lib/install-common.sh"

RAYCAST_SCRIPTS="${HOME}/.config/raycast/scripts"
chmod +x "${DIR}/reap.sh"
ld_link "${DIR}/reap.sh" "${RAYCAST_SCRIPTS}/reap.sh"

echo
echo "Reap is now available in Raycast (Script Commands). It also runs from a"
echo "terminal: ${DIR}/reap.sh [dry|all|mcp|servers]  (default: dry run)."
