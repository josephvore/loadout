#!/bin/bash
#
# @raycast.schemaVersion 1
# @raycast.title Kill Dev / MCP Servers
# @raycast.mode compact
# @raycast.packageName Dev Tools
# @raycast.icon 🧹
# @raycast.argument1 { "type": "dropdown", "placeholder": "mode", "data": [ {"title":"Dry run (preview)","value":"dry"}, {"title":"Kill ALL matched","value":"all"}, {"title":"MCP servers only","value":"mcp"}, {"title":"Dev servers only","value":"servers"} ] }
# @raycast.description Clean up stale Codex/Claude Code MCP subprocesses and stray dev servers. Defaults to a safe dry-run preview.
#
# ----------------------------------------------------------------------------
# WHAT THIS DOES
# ----------------------------------------------------------------------------
# Codex's background `codex app-server` spawns a fresh set of MCP servers PER
# session and leaks them across sessions. They stack up (30+ over a day). This
# reaps them. It also optionally kills stray local dev servers (next/vite/etc).
#
# MODES (argument1):
#   dry      -> preview only. Prints a table of what WOULD be killed. Kills NOTHING.
#   all      -> kill MCP-server patterns + dev-server patterns.
#   mcp      -> kill MCP-server patterns only.
#   servers  -> kill dev-server patterns only.
#
# Signals TERM (kill) first; a single TERM is almost always enough for node
# processes. A second pass with TERM is attempted for stragglers; we never -9.
#
# ----------------------------------------------------------------------------
# SAFETY MODEL (read before editing patterns)
# ----------------------------------------------------------------------------
# We only ever target a small, explicit allow-list of SUBPROCESS command-line
# patterns (TARGET_* regexes below). Everything else is ignored by default.
# On top of that, three hard exclusions are applied to every candidate:
#
#   1. SELF + ANCESTOR CHAIN. We compute this script's own PID ($$) and walk
#      up the parent (ppid) chain to PID 1, excluding every PID along the way.
#      This guarantees we never kill the Raycast script runner, the shell that
#      launched us, or any parent we depend on to keep running.
#
#   2. MAIN GUI APPS. Any process whose command line contains an absolute path
#      of the form  /Applications/<Name>.app/Contents/MacOS/   (or the same
#      under /System/Applications) is excluded. That protects Codex.app,
#      Claude.app, ChatGPT.app, VS Code, iTerm, Chrome, Raycast, etc.
#      NOTE: this exclusion is deliberately ANCHORED to a top-level app bundle
#      reached by an absolute path. It does NOT match:
#        - /Applications/Codex.app/Contents/Resources/node_repl  (Resources,
#          not MacOS -> a leaked subprocess we DO want to reap)
#        - ./Codex Computer Use.app/.../MacOS/SkyComputerUseClient mcp (a
#          relative-path nested helper -> a leaked subprocess we DO want to reap)
#
#   3. WHEN IN DOUBT, EXCLUDE. The TARGET patterns are intentionally narrow and
#      tied to the exact strings observed in `ps`. We do not pattern-match bare
#      "node" or bare "npm" — only the specific MCP/dev-server invocations.
#
# Verify the live picture any time with:
#   ps -axo pid,ppid,etime,command
# ----------------------------------------------------------------------------

set -u

MODE="${1:-dry}"

# --- TARGET PATTERNS (extended regex, matched against the full command line) ---
#
# MCP-server patterns (Codex app-server leaks one set of these per session):
#   - npx/npm-exec launcher + resolved process for chrome-devtools-mcp
#   - npx/npm-exec launcher + resolved node process for shadcn mcp
#   - Codex "computer use" client running in mcp mode
#   - Codex.app's leaked node_repl helper (under Contents/Resources, NOT the GUI)
#   - chrome-devtools-mcp's telemetry watchdog (build/src/telemetry/watchdog/main.js)
TARGET_MCP=(
  'chrome-devtools-mcp'                       # npm exec chrome-devtools-mcp@latest + resolved `chrome-devtools-mcp`
  'shadcn(@latest)?[[:space:]]+mcp'           # npm exec shadcn@latest mcp
  '/\.bin/shadcn[[:space:]]+mcp'              # resolved node .../.bin/shadcn mcp
  'SkyComputerUseClient[^[:space:]]*[[:space:]]+mcp'  # Codex Computer Use client, mcp mode
  'Codex\.app/Contents/Resources/node_repl'   # leaked Codex node_repl helper (Resources, not MacOS GUI)
  'telemetry/watchdog/main\.js'               # chrome-devtools-mcp watchdog
)

# Dev-server patterns (occasional strays from `npm run dev` etc.):
#   We match the *server* processes and the common launch commands. We use
#   anchored/spaced forms to avoid catching unrelated processes that merely
#   contain the substring "vite" or "next" in a path.
TARGET_SERVERS=(
  'next-server'                                # Next.js running server
  '(^|/| )next[[:space:]]+dev([[:space:]]|$)'  # `next dev` (word-anchored: not "develop")
  '(^|/| )(node[[:space:]].*)?vite([[:space:]]|$)'  # vite dev server
  'npm[[:space:]]+run[[:space:]]+dev([[:space:]]|$)'  # npm run dev (not "develop")
  '(yarn|pnpm)[[:space:]]+dev([[:space:]]|$)'  # yarn dev / pnpm dev (not "develop")
)

# --- Build the active target list based on mode ---
TARGETS=()
case "$MODE" in
  dry|all)
    TARGETS=("${TARGET_MCP[@]}" "${TARGET_SERVERS[@]}")
    ;;
  mcp)
    TARGETS=("${TARGET_MCP[@]}")
    ;;
  servers)
    TARGETS=("${TARGET_SERVERS[@]}")
    ;;
  *)
    echo "Unknown mode: '$MODE' (expected: dry | all | mcp | servers)"
    exit 1
    ;;
esac

# Join target patterns into one alternation for a single ps scan.
JOINED_TARGETS=""
for p in "${TARGETS[@]}"; do
  if [ -z "$JOINED_TARGETS" ]; then
    JOINED_TARGETS="$p"
  else
    JOINED_TARGETS="$JOINED_TARGETS|$p"
  fi
done

# --- EXCLUSION 1: self + full ancestor (ppid) chain ---
# Walk from $$ up to PID 1, collecting every PID. These are space-delimited and
# matched as whole words so we never substring-match a PID by accident.
declare -A EXCLUDE_PIDS=()
walk_pid="$$"
# guard against loops / missing data; the chain is short in practice
for _ in $(seq 1 64); do
  [ -z "$walk_pid" ] && break
  [ "$walk_pid" = "0" ] && break
  EXCLUDE_PIDS["$walk_pid"]=1
  [ "$walk_pid" = "1" ] && break
  parent="$(ps -o ppid= -p "$walk_pid" 2>/dev/null | tr -d ' ')"
  [ -z "$parent" ] && break
  walk_pid="$parent"
done

# --- EXCLUSION 2: main GUI app binaries (anchored, absolute, top-level bundle) ---
# Matches e.g. " /Applications/Codex.app/Contents/MacOS/Codex" but NOT
# "Contents/Resources/node_repl" and NOT relative "./Foo.app/.../MacOS/...".
GUI_EXCLUDE_RE='(^|[[:space:]])(/System)?/Applications/[^/]+\.app/Contents/MacOS/'

# ----------------------------------------------------------------------------
# Collect candidates.
# ps output: PID, ETIME, then the full COMMAND (which may contain spaces).
# We parse pid + etime off the front and keep the rest verbatim as the command.
# ----------------------------------------------------------------------------
MATCH_PIDS=()
MATCH_ETIME=()
MATCH_CMD=()

while IFS= read -r line; do
  # strip leading whitespace
  line="${line#"${line%%[![:space:]]*}"}"
  pid="${line%%[[:space:]]*}"
  rest="${line#*[[:space:]]}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  etime="${rest%%[[:space:]]*}"
  cmd="${rest#*[[:space:]]}"

  # numeric pid sanity
  case "$pid" in
    ''|*[!0-9]*) continue ;;
  esac

  # EXCLUSION 1: self / ancestor chain
  if [ -n "${EXCLUDE_PIDS[$pid]:-}" ]; then
    continue
  fi

  # Does the command match any active TARGET pattern?
  if ! printf '%s' "$cmd" | grep -Eq "$JOINED_TARGETS"; then
    continue
  fi

  # EXCLUSION 2: main GUI app binary
  if printf '%s' "$cmd" | grep -Eq "$GUI_EXCLUDE_RE"; then
    continue
  fi

  # EXCLUSION 3 (belt-and-suspenders): never match this script's own filename,
  # in case it is itself being scanned while running.
  case "$cmd" in
    *kill-dev-servers.sh*) continue ;;
  esac

  MATCH_PIDS+=("$pid")
  MATCH_ETIME+=("$etime")
  MATCH_CMD+=("$cmd")
done < <(ps -axo pid=,etime=,command=)

COUNT="${#MATCH_PIDS[@]}"

# --- Pretty short command for the table (truncate long node paths) ---
short_cmd() {
  local c="$1"
  if [ "${#c}" -gt 72 ]; then
    printf '%s…' "${c:0:71}"
  else
    printf '%s' "$c"
  fi
}

print_table() {
  printf '%-7s %-12s %s\n' "PID" "ETIME" "COMMAND"
  printf '%-7s %-12s %s\n' "-----" "-----" "-------"
  local i
  for i in "${!MATCH_PIDS[@]}"; do
    printf '%-7s %-12s %s\n' "${MATCH_PIDS[$i]}" "${MATCH_ETIME[$i]}" "$(short_cmd "${MATCH_CMD[$i]}")"
  done
}

if [ "$COUNT" -eq 0 ]; then
  echo "No matching processes found (mode: $MODE). Nothing to do."
  exit 0
fi

# ----------------------------------------------------------------------------
# DRY RUN: preview only.
# ----------------------------------------------------------------------------
if [ "$MODE" = "dry" ]; then
  echo "DRY RUN — would kill $COUNT process(es). Nothing was killed."
  echo
  print_table
  exit 0
fi

# ----------------------------------------------------------------------------
# KILL MODES.
# ----------------------------------------------------------------------------
echo "Killing $COUNT process(es) (mode: $MODE) with TERM…"
print_table
echo

# First pass: TERM
for pid in "${MATCH_PIDS[@]}"; do
  kill "$pid" 2>/dev/null
done

# Give them a moment to exit, then check for stragglers.
sleep 1

REMAINING=()
for pid in "${MATCH_PIDS[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    REMAINING+=("$pid")
  fi
done

# Second pass: another TERM (still not -9). Children whose parent we just
# killed often vanish here on their own.
if [ "${#REMAINING[@]}" -gt 0 ]; then
  echo "Second TERM pass for ${#REMAINING[@]} straggler(s): ${REMAINING[*]}"
  for pid in "${REMAINING[@]}"; do
    kill "$pid" 2>/dev/null
  done
  sleep 1
fi

# Final report.
STILL=()
for pid in "${MATCH_PIDS[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    STILL+=("$pid")
  fi
done

KILLED=$(( COUNT - ${#STILL[@]} ))
echo "Done. Terminated $KILLED of $COUNT."
if [ "${#STILL[@]}" -gt 0 ]; then
  echo "Still alive (left untouched, no SIGKILL): ${STILL[*]}"
  echo "Re-run if needed, or inspect with: ps -p ${STILL[*]// /,} -o pid,ppid,command"
fi
exit 0
