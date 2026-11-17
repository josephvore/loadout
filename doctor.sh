#!/usr/bin/env bash
# Loadout doctor: check that the suite is installed and healthy.
#
#   ./doctor.sh            all checks, including one API call per AI provider
#   ./doctor.sh --offline  skip the provider checks (no network)
#
# Read-only: it never changes files, settings, or Keychain items, and it only
# checks that keys exist (their values stay in the Keychain, except for the
# provider check, which sends each key to its own provider's model list).
# Exit status is the number of problems found (0 = healthy).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_DIR="${HOME}/.hammerspoon"
OFFLINE=0
for arg in "$@"; do
  case "$arg" in
    --offline) OFFLINE=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

problems=0
ok()   { echo "  ok    $*"; }
warn() { echo "  note  $*"; }
bad()  { echo "  FAIL  $*"; problems=$((problems + 1)); }

# hs_eval SECONDS LUA: run Lua in Hammerspoon, giving up after SECONDS (the
# hs tool can wait forever when Hammerspoon's message port is busy).
hs_eval() {
  local out pid killer
  out="$(mktemp "${TMPDIR:-/tmp}/loadout-doctor.XXXXXX")"
  hs -c "$2" >"$out" 2>/dev/null &
  pid=$!
  ( sleep "$1"; kill "$pid" 2>/dev/null ) &
  killer=$!
  wait "$pid" 2>/dev/null || true
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  cat "$out"
  rm -f "$out"
}

echo "== Loadout doctor =="

echo "-- Hammerspoon --"
if [ -d /Applications/Hammerspoon.app ] || [ -d "${HOME}/Applications/Hammerspoon.app" ]; then
  ok "Hammerspoon installed"
else
  bad "Hammerspoon not installed (https://www.hammerspoon.org)"
fi
# -a: when Caps+K runs this, Hammerspoon is our ancestor, which pgrep skips by default.
if pgrep -axq Hammerspoon; then ok "Hammerspoon running"; else bad "Hammerspoon is not running (open -a Hammerspoon)"; fi
HS_CLI=0
if command -v hs >/dev/null 2>&1 && pgrep -axq Hammerspoon \
    && [ "$(hs_eval 5 'return 1')" = 1 ]; then
  HS_CLI=1
  ok "hs command-line tool answers"
else
  warn "hs command-line tool unavailable; skipping live checks (add hs.ipc.cliInstall() once)"
fi

echo "-- linked files in ~/.hammerspoon --"
for f in init.lua litelog.lua settings_overlay.lua hone.lua murmur.lua murmur_core.lua \
    relay.lua unsub.lua unsub.py palette.lua quickshots.lua; do
  path="${HAMMER_DIR}/${f}"
  if [ -L "$path" ] && [ ! -e "$path" ]; then
    bad "${f} is a broken link -> $(readlink "$path")"
  elif [ -e "$path" ]; then
    ok "$f"
  else
    warn "$f not installed"
  fi
done
while IFS= read -r link; do
  bad "broken link: ${link#"${HAMMER_DIR}"/} -> $(readlink "$link")"
done < <(find "$HAMMER_DIR" -maxdepth 2 -type l ! -exec test -e {} \; -print 2>/dev/null)

echo "-- built tools --"
dictate="${HOME}/bin/hs-dictate"
if [ -x "$dictate" ]; then
  stale=0
  for src in "${ROOT}"/apps/murmur/hs-dictate/*.swift; do
    [ "$src" -nt "$dictate" ] && stale=1
  done
  if [ "$stale" -eq 1 ]; then bad "hs-dictate is older than its source (run ./update.sh --no-pull)"
  else ok "hs-dictate"; fi
else
  bad "$HOME/bin/hs-dictate missing (apps/murmur/hs-dictate/build.sh)"
fi
settings_bin="${ROOT}/lib/settings/loadout-settings"
if [ -x "$settings_bin" ]; then
  if [ "${ROOT}/lib/settings/loadout-settings.swift" -nt "$settings_bin" ]; then
    bad "settings tool is older than its source (run ./update.sh --no-pull)"
  else ok "settings tool"; fi
else
  bad "settings tool missing (lib/settings/build.sh); Caps+K can't edit settings"
fi

echo "-- your settings --"
if [ -f "${HAMMER_DIR}/loadout.local.lua" ]; then
  if command -v luac >/dev/null 2>&1; then
    if luac -p "${HAMMER_DIR}/loadout.local.lua" 2>/dev/null; then ok "loadout.local.lua parses"
    else bad "loadout.local.lua has a syntax error: $(luac -p "${HAMMER_DIR}/loadout.local.lua" 2>&1 | head -1)"; fi
  else
    ok "loadout.local.lua present"
  fi
fi
for json in "${HAMMER_DIR}"/settings/*.json; do
  [ -e "$json" ] || continue
  if python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" 2>/dev/null; then
    ok "settings/$(basename "$json")"
  else
    bad "settings/$(basename "$json") is not valid JSON"
  fi
done

echo "-- API keys (existence only) --"
any_key=0
for service in openai-refine groq-api cerebras-api; do
  if /usr/bin/security find-generic-password -s "$service" >/dev/null 2>&1; then
    ok "Keychain: $service"; any_key=1
  else
    warn "Keychain: $service not set (optional)"
  fi
done
[ "$any_key" -eq 1 ] || warn "no AI keys: Hone and Murmur's cleanup are off (apps/hone/setup-keys.sh)"

echo "-- recent errors (since the last reload) --"
since_reload() {
  local log="${HAMMER_DIR}/logs/$1.log" marker="$2"
  [ -f "$log" ] || return 0
  awk -v m="$marker" 'index($0, m) { buf = ""; next } { buf = buf $0 "\n" } END { printf "%s", buf }' "$log"
}
failed="$(since_reload init "reload started" | grep -E 'ERROR' | sed -E 's/ error=.*//' | cut -c1-160)"
if [ -n "$failed" ]; then
  while IFS= read -r line; do bad "init: $line"; done <<< "$failed"
else
  ok "every installed app loaded"
fi
disabled="$(since_reload hone "INFO started" | grep 'provider disabled until reload' | cut -c1-160)"
if [ -n "$disabled" ]; then
  while IFS= read -r line; do bad "hone: $line"; done <<< "$disabled"
fi

if [ "$OFFLINE" -eq 1 ]; then
  echo "-- AI providers: skipped (--offline) --"
elif [ "$HS_CLI" -eq 1 ] && [ "$any_key" -eq 1 ]; then
  echo "-- AI providers (one model-list request each) --"
  hone_json="$(hs_eval 8 'local ok, h = pcall(require, "hone"); if not ok then return "" end
    return hs.json.encode({ providers = h.config.providers, order = h.config.autoRefineProviderOrder,
      model = h.config.model, autoRefineModel = h.config.autoRefineModel })')"
  if [ -z "$hone_json" ]; then
    warn "Hone isn't loaded; skipping"
  else
    out="$(printf '%s' "$hone_json" | python3 -I -c '
import json, subprocess, sys, urllib.request
cfg = json.load(sys.stdin)
for name in cfg.get("order") or []:
    p = (cfg.get("providers") or {}).get(name)
    if not p:
        continue
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s",
                        p.get("keychainService", ""), "-w"], capture_output=True, text=True)
    key = r.stdout.strip()
    if not key:
        continue
    url = p["url"].rsplit("/", 2)[0] + "/models" if p.get("api") == "chat" \
        else "https://api.openai.com/v1/models"
    models = [p["model"]] if p.get("model") else \
        sorted({m for m in (cfg.get("autoRefineModel"), cfg.get("model")) if m})
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + key})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            ids = {m.get("id") for m in json.load(resp).get("data", [])}
    except Exception as e:
        print("bad %s: model list failed (%s)" % (name, str(e)[:80]))
        continue
    missing = [m for m in models if m not in ids]
    if missing:
        print("bad %s: model %s not offered; set a current one in loadout.local.lua "
              "(offered: %s)" % (name, ", ".join(missing), ", ".join(sorted(i for i in ids if i))[:200]))
    else:
        print("ok %s: %s" % (name, ", ".join(models)))
' 2>&1)"
    while IFS= read -r line; do
      case "$line" in
        ok\ *) ok "${line#ok }" ;;
        bad\ *) bad "${line#bad }" ;;
        "") ;;
        *) bad "provider check: $line" ;;
      esac
    done <<< "$out"
  fi
else
  echo "-- AI providers: skipped (needs the hs tool and at least one key) --"
fi

echo
if [ "$problems" -eq 0 ]; then
  echo "Healthy: no problems found."
else
  echo "${problems} problem(s) found."
fi
exit "$problems"
