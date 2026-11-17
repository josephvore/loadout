#!/usr/bin/env bash
# Loadout update: pull the latest code, relink, rebuild what changed, reload.
#
#   ./update.sh             fast-forward pull, then refresh everything
#   ./update.sh --no-pull   refresh after your own local edits
#
# Rebuilds Murmur's hs-dictate and the settings tool only when their Swift
# sources are newer than the built binaries. Never touches your settings,
# keys, or ~/.hammerspoon/loadout.local.lua.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${ROOT}/lib/install-common.sh"

PULL=1
for arg in "$@"; do
  case "$arg" in
    --no-pull) PULL=0 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "== Loadout update =="
if [ "$PULL" -eq 1 ]; then
  if git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    before="$(git -C "$ROOT" rev-parse HEAD)"
    git -C "$ROOT" pull --ff-only
    after="$(git -C "$ROOT" rev-parse HEAD)"
    if [ "$before" = "$after" ]; then
      echo "-- already up to date --"
    else
      echo "-- updated ${before:0:7} -> ${after:0:7} --"
      git -C "$ROOT" log --oneline "${before}..${after}" | sed 's/^/  /'
    fi
  else
    echo "-- no upstream branch; skipping pull --"
  fi
fi

# Relink every app (cheap and idempotent). Builds and reloads happen below.
echo "-- relinking apps --"
for app in hone murmur relay unsub palette reap; do
  if ! LOADOUT_SKIP_BUILD=1 LOADOUT_NO_RELOAD=1 \
      "${ROOT}/apps/${app}/install.sh" >/dev/null; then
    echo "  ! ${app} installer failed; run apps/${app}/install.sh to see why" >&2
  fi
done

# newer_than BINARY SOURCE... : true when BINARY is missing or any SOURCE is newer.
newer_than() {
  local bin="$1"; shift
  [ -e "$bin" ] || return 0
  local src
  for src in "$@"; do
    [ "$src" -nt "$bin" ] && return 0
  done
  return 1
}

echo "-- rebuilding changed tools --"
dictate_dir="${ROOT}/apps/murmur/hs-dictate"
if newer_than "${HOME}/bin/hs-dictate" "${dictate_dir}"/*.swift "${dictate_dir}/Package.swift"; then
  if command -v swift >/dev/null 2>&1; then
    "${dictate_dir}/build.sh"
  else
    echo "  ! swift not found; hs-dictate not rebuilt" >&2
  fi
else
  echo "  hs-dictate up to date"
fi

settings_dir="${ROOT}/lib/settings"
if newer_than "${settings_dir}/loadout-settings" "${settings_dir}/loadout-settings.swift"; then
  ld_build_settings "$ROOT"
else
  echo "  settings tool up to date"
fi

echo
ld_reload_hint
echo "Run ./doctor.sh if anything looks off."
