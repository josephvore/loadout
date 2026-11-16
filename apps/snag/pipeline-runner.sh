#!/bin/bash
# snag pipeline-runner — drains the capture queue. Triggered by launchd
# (WatchPaths on queue/) whenever a token appears; a mkdir lock keeps
# concurrent triggers from double-processing. Tokens are files named after
# the capture stamp whose content is the capture dir path.
set -u
SNAG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE="$SNAG_DIR/queue"
LOCK="$SNAG_DIR/state/runner.lock"
mkdir -p "$SNAG_DIR/state"
exec >> "$SNAG_DIR/state/runner.log" 2>&1

mkdir "$LOCK" 2>/dev/null || exit 0  # another runner is already draining
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

while :; do
  token=$(command ls "$QUEUE" 2>/dev/null | head -1)
  [ -n "$token" ] || break
  dir=$(cat "$QUEUE/$token" 2>/dev/null)
  rm -f "$QUEUE/$token"
  if [ -d "$dir" ] && [ -f "$dir/recording.mov" ]; then
    echo "=== $(date '+%F %T') processing $dir"
    bash "$SNAG_DIR/pipeline.sh" "$dir"
  else
    echo "=== $(date '+%F %T') skipping stale token $token ($dir)"
  fi
done
