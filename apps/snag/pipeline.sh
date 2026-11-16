#!/bin/bash
# snag pipeline — turn a capture dir (recording.mov + meta.json) into a
# verified GitHub issue: extract audio/frames, transcribe via Murmur's
# Parakeet daemon, slice the dev-server log, then run a headless Claude
# verifier inside the EquipFlow repo. Always exits 0 with a result.json;
# failures land in result.json + pipeline.log, never as a silent crash.
set -u

DIR="${1:?usage: pipeline.sh <capture-dir>}"
SNAG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${SNAG_CONF:-}" != "off" ] && [ -f "$SNAG_DIR/snag.conf" ] && . "$SNAG_DIR/snag.conf"
# Machine-specific values (SNAG_REPO) live in the untracked snag.local.conf.
[ "${SNAG_CONF:-}" != "off" ] && [ -f "$SNAG_DIR/snag.local.conf" ] && . "$SNAG_DIR/snag.local.conf"

# --- configuration (override via SNAG_* env vars) ---------------------------
REPO="${SNAG_REPO:-}"   # set in snag.local.conf: SNAG_REPO=/path/to/repo
DEV_LOG="${SNAG_DEV_LOG:-$REPO/tmp/dev-server.log}"
FFMPEG="${SNAG_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
FFPROBE="${SNAG_FFPROBE:-/opt/homebrew/bin/ffprobe}"
CLAUDE_BIN="${SNAG_CLAUDE:-$HOME/.local/bin/claude}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"  # hs.task spawns with a bare PATH
LOG_PAD_BEFORE=15   # seconds of dev log kept before recording start
LOG_PAD_AFTER=5     # seconds kept after recording end
FRAME_EVERY="${SNAG_FRAME_EVERY:-3}"        # one keyframe every N seconds (short clips)
MAX_FRAMES="${SNAG_MAX_FRAMES:-12}"         # cap; long videos spread these across the full length
CHUNK_SECONDS="${SNAG_CHUNK_SECONDS:-120}"  # transcription chunk length for long audio
DRY_RUN="${SNAG_DRY_RUN:-0}"
# "report" (default): distill to report.md in the capture dir, file nothing.
# "verify": triage-grade verification that auto-files GitHub issues.
# "meet": meeting notes from an ingested recording, file nothing.
# Ingested captures carry a per-capture "mode" in meta.json; it wins over conf.
CAPTURE_MODE=$(/usr/bin/jq -r '.mode // empty' "$DIR/meta.json" 2>/dev/null)
MODE="${CAPTURE_MODE:-${SNAG_MODE:-report}}"
SOURCE=$(/usr/bin/jq -r '.source // "live"' "$DIR/meta.json" 2>/dev/null)
SOURCE="${SOURCE:-live}"

exec >> "$DIR/pipeline.log" 2>&1
echo "=== snag pipeline $(date '+%F %T') dir=$DIR mode=$MODE source=$SOURCE dry_run=$DRY_RUN ==="

# Notifications come from the pipeline itself — no long-lived app has to
# survive for the user to hear about the outcome. $3 (optional) is opened
# on click: a file path or URL.
notify() {
  local tn=/opt/homebrew/bin/terminal-notifier
  if [ -x "$tn" ]; then
    if [ -n "${3:-}" ]; then
      "$tn" -group snag -title "$1" -message "$2" -execute "open '$3'"
    else
      "$tn" -group snag -title "$1" -message "$2"
    fi
  else
    /usr/bin/osascript -e "display notification \"${2//\"/}\" with title \"${1//\"/}\"" 2>/dev/null
  fi
}

fail() {
  echo "FATAL: $1"
  printf '{"status":"error","error":%s}\n' "$(printf '%s' "$1" | /usr/bin/jq -Rs .)" > "$DIR/result.json"
  notify "Snag: pipeline failed" "$1" "$DIR"
  exit 0
}

[ -f "$DIR/recording.mov" ] || fail "no recording.mov in $DIR"
[ -x "$FFMPEG" ] || fail "ffmpeg not found at $FFMPEG"

# --- 1. audio + keyframes ----------------------------------------------------
echo "--- extracting audio"
"$FFMPEG" -y -loglevel error -i "$DIR/recording.mov" -vn -ac 1 -ar 16000 "$DIR/audio.wav" \
  || echo "WARN: audio extraction failed (silent recording?)"

echo "--- extracting keyframes"
DURATION=$("$FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 \
  "$DIR/recording.mov" 2>/dev/null)
DURATION="${DURATION%.*}"
case "$DURATION" in ''|*[!0-9]*) DURATION=0 ;; esac
[ "$MAX_FRAMES" -gt 99 ] && MAX_FRAMES=99            # frame_%02d namespace
if [ "$DURATION" -gt $((FRAME_EVERY * MAX_FRAMES)) ]; then
  FRAME_EVERY=$(( (DURATION + MAX_FRAMES - 1) / MAX_FRAMES ))  # spread over the full length
fi
echo "duration=${DURATION}s frame_every=${FRAME_EVERY}s max_frames=$MAX_FRAMES"
mkdir -p "$DIR/frames"
"$FFMPEG" -y -loglevel error -i "$DIR/recording.mov" \
  -vf "fps=1/$FRAME_EVERY,scale=1280:-2" -frames:v "$MAX_FRAMES" \
  "$DIR/frames/frame_%02d.jpg" \
  || echo "WARN: keyframe extraction failed"

# --- 2. transcription via Murmur's Parakeet daemon ---------------------------
echo "--- transcribing"
if [ -f "$DIR/audio.wav" ]; then
  WAVS=("$DIR/audio.wav")
  if [ "$DURATION" -gt "$CHUNK_SECONDS" ]; then
    mkdir -p "$DIR/audio-chunks"
    if "$FFMPEG" -y -loglevel error -i "$DIR/audio.wav" \
        -f segment -segment_time "$CHUNK_SECONDS" -c copy \
        "$DIR/audio-chunks/chunk_%03d.wav"; then
      WAVS=("$DIR"/audio-chunks/chunk_*.wav)
    else
      echo "WARN: audio segmenting failed — transcribing single-shot"
    fi
  fi
  echo "transcribing ${#WAVS[@]} chunk(s)"
  /usr/bin/python3 "$SNAG_DIR/transcribe.py" "${WAVS[@]}" > "$DIR/transcript.txt" \
    || { echo "WARN: transcription failed"; echo "(transcription unavailable)" > "$DIR/transcript.txt"; }
else
  echo "(no audio captured)" > "$DIR/transcript.txt"
fi
echo "transcript: $(head -c 200 "$DIR/transcript.txt")"

# --- 3. dev-server log slice -------------------------------------------------
# make dev-snag prefixes every line with [epoch]; keep the recording window.
echo "--- slicing dev log"
START=$(/usr/bin/jq -r '.startedAt // 0' "$DIR/meta.json" 2>/dev/null || echo 0)
END=$(/usr/bin/jq -r '.endedAt // 0' "$DIR/meta.json" 2>/dev/null || echo 0)
if [ "$SOURCE" = "ingest" ]; then
  echo "(skipped — ingested file; timestamps derive from file mtime, no dev-server correlation)" > "$DIR/devlog.txt"
elif [ -f "$DEV_LOG" ] && [ "$START" -gt 0 ]; then
  awk -v lo=$((START - LOG_PAD_BEFORE)) -v hi=$((END + LOG_PAD_AFTER)) '
    /^\[[0-9]+\]/ {
      ts = substr($0, 2, index($0, "]") - 2) + 0
      if (ts >= lo && ts <= hi) print
    }' "$DEV_LOG" > "$DIR/devlog.txt"
  echo "devlog: $(wc -l < "$DIR/devlog.txt") lines in window"
else
  echo "(no dev-server log found — run 'make dev-snag' in the repo to capture one)" > "$DIR/devlog.txt"
fi

if [ "$DRY_RUN" = "1" ]; then
  printf '{"status":"dry-run"}\n' > "$DIR/result.json"
  notify "Snag: dry run complete" "Context assembled, claude step skipped" "$DIR"
  echo "=== dry run complete ==="
  exit 0
fi

# --- 4. headless Claude in the repo ------------------------------------------
if [ "$MODE" = "verify" ]; then
  PROMPT_FILE="$SNAG_DIR/verify-prompt.md"
  TOOLS="Read,Grep,Glob,Bash(gh issue:*),Bash(git log:*),Bash(git diff:*),Bash(ls:*)"
elif [ "$MODE" = "meet" ]; then
  PROMPT_FILE="$SNAG_DIR/meet-prompt.md"
  TOOLS="Read,Grep,Glob,Write"
else
  PROMPT_FILE="$SNAG_DIR/report-prompt.md"
  TOOLS="Read,Grep,Glob,Write"
fi
echo "--- running claude ($MODE)"
{
  cat "$PROMPT_FILE"
  echo
  echo "## Capture inputs for this run"
  echo
  echo "- Capture dir: $DIR"
  echo "- Transcript: $DIR/transcript.txt"
  echo "- Keyframes: $DIR/frames/ ($(ls "$DIR/frames" 2>/dev/null | wc -l | tr -d ' ') images, chronological)"
  echo "- Dev-server log slice: $DIR/devlog.txt"
  echo "- Metadata: $DIR/meta.json"
  [ "$SOURCE" = "ingest" ] && echo "- Source: ingested file $(/usr/bin/jq -r '.originalFile // "?"' "$DIR/meta.json" 2>/dev/null), ${DURATION}s"
} > "$DIR/prompt.txt"

[ -n "$REPO" ] || fail "SNAG_REPO not set — add SNAG_REPO=/path/to/repo to snag.local.conf"
cd "$REPO" || fail "repo not found at $REPO"
"$CLAUDE_BIN" -p --output-format text --max-turns 60 \
  --allowedTools "$TOOLS" \
  < "$DIR/prompt.txt" > "$DIR/verifier-output.txt" 2>&1
VERIFIER_EXIT=$?
echo "claude exit: $VERIFIER_EXIT"

# --- 5. result ---------------------------------------------------------------
VERDICT_LINE=$(grep -E '^\{.*\}\s*$' "$DIR/verifier-output.txt" | tail -1)
if [ -n "$VERDICT_LINE" ] && echo "$VERDICT_LINE" | /usr/bin/jq -e . > /dev/null 2>&1; then
  echo "$VERDICT_LINE" | /usr/bin/jq '. + {status: "done"}' > "$DIR/result.json"
else
  fail "claude produced no JSON result (exit $VERIFIER_EXIT) — see verifier-output.txt"
fi
if [ "$MODE" != "verify" ]; then
  REPORT=$(/usr/bin/jq -r '.report // empty' "$DIR/result.json")
  [ -n "$REPORT" ] && [ -f "$REPORT" ] || fail "$MODE mode finished without writing a report — see verifier-output.txt"
  printf '%s' "$REPORT" | /usr/bin/pbcopy
  TITLE="Snag: report ready"
  [ "$MODE" = "meet" ] && TITLE="Snag: meeting notes ready"
  notify "$TITLE" "$(/usr/bin/jq -r '.summary // "report written"' "$DIR/result.json")" "$REPORT"
else
  ISSUE=$(/usr/bin/jq -r '.issue_url // empty' "$DIR/result.json")
  if [ -n "$ISSUE" ]; then
    notify "Snag: issue filed" "$(/usr/bin/jq -r '.title // .verdict' "$DIR/result.json")" "$ISSUE"
  else
    notify "Snag: no issue filed" "$(/usr/bin/jq -r '.reasoning // .verdict // "see capture dir"' "$DIR/result.json")" "$DIR"
  fi
fi
echo "=== pipeline complete: $(cat "$DIR/result.json") ==="
