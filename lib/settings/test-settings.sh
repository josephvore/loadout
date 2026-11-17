#!/usr/bin/env bash
# Round-trip checks for loadout-settings' --set/--dump modes, against throwaway
# schemas in a scratch directory (never your real settings). macOS + swiftc.
#
#   lib/settings/test-settings.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/loadout-settings-test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

fail() { echo "settings test FAILED: $*" >&2; exit 1; }

mkdir -p "$SCRATCH/root/settings" "$SCRATCH/root/lib/settings"
BIN="$SCRATCH/root/lib/settings/loadout-settings"
swiftc -O -o "$BIN" "$HERE/loadout-settings.swift"

cat > "$SCRATCH/root/settings/shtest.schema.json" <<EOF
{"app": "shtest", "title": "t", "format": "shell", "target": "$SCRATCH/out.conf",
 "fields": [
   {"key": "NOTE", "label": "n", "type": "string", "default": "plain"},
   {"key": "DIR", "label": "d", "type": "folder", "default": "~/Somewhere"}
 ]}
EOF
cat > "$SCRATCH/root/settings/jstest.schema.json" <<EOF
{"app": "jstest", "title": "t", "format": "json", "target": "$SCRATCH/out/settings.json",
 "fields": [
   {"key": "mode", "label": "m", "type": "enum", "options": ["a", "b"], "default": "a"},
   {"key": "count", "label": "c", "type": "int", "default": "3"},
   {"key": "on", "label": "o", "type": "bool", "default": "true"}
 ]}
EOF
export LOADOUT_ROOT="$SCRATCH/root"

echo "-- shell format: hostile value round-trips without running anything --"
# shellcheck disable=SC2016  # the $(...) must reach the tool unexpanded
hostile='it'"'"'s "quoted" $(touch '"$SCRATCH"'/PWNED) `id` \back'
"$BIN" shtest --set "NOTE=$hostile" --no-post-save
[ ! -e "$SCRATCH/PWNED" ] || fail "writing executed the value"
got="$(bash -c '. "$1"; printf %s "$NOTE"' _ "$SCRATCH/out.conf")"
[ ! -e "$SCRATCH/PWNED" ] || fail "sourcing the conf executed the value"
[ "$got" = "$hostile" ] || fail "sourced NOTE was [$got]"
dumped="$("$BIN" shtest --dump | sed -n 's/^NOTE=//p')"
[ "$dumped" = "$hostile" ] || fail "--dump NOTE was [$dumped]"
"$BIN" shtest --dump | grep -qx "DIR=$HOME/Somewhere" || fail "~ default did not expand"

echo "-- json format: only changed values are saved --"
"$BIN" jstest --set mode=b count=3 --no-post-save
python3 -I - "$SCRATCH/out/settings.json" <<'PY' || fail "json overlay content"
import json, sys
data = json.load(open(sys.argv[1]))
assert data == {"mode": "b"}, data
PY

echo "settings tests passed"
