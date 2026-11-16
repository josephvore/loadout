#!/bin/bash
# ✦ Loadout hub — SwiftBar plugin (refreshes every 3s, per the filename).
# Reads snag's state files directly; no Hammerspoon required for snag
# actions. NOTE: SwiftBar strips DOUBLE quotes from bash=/param values —
# single quotes are passed through literally and break the action.
SNAG="$HOME/loadout/apps/snag"
CLI="$SNAG/snag"
HS=/opt/homebrew/bin/hs
JQ=/usr/bin/jq
REC="$SNAG/state/recording.json"

CAPTURES="$SNAG/captures"
conf_root=$(sed -n 's/^SNAG_CAPTURE_ROOT=//p' "$SNAG/snag.conf" 2>/dev/null)
[ -n "$conf_root" ] && CAPTURES="$conf_root"

recording=no
if [ -f "$REC" ] && kill -0 "$($JQ -r '.pid' "$REC" 2>/dev/null)" 2>/dev/null; then
  recording=yes
fi
busy=no
[ -d "$SNAG/state/runner.lock" ] && busy=yes
[ -n "$(command ls "$SNAG/queue" 2>/dev/null)" ] && busy=yes

if [ "$recording" = yes ]; then echo "✦ ●"
elif [ "$busy" = yes ]; then echo "✦ ⋯"
else echo "✦"
fi

echo "---"
echo "Snag | disabled=true"
if [ "$recording" = yes ]; then
  elapsed=$(( $(date +%s) - $($JQ -r '.startedAt' "$REC") ))
  echo "●  Recording ${elapsed}s — stop and process | bash=\"$CLI\" param1=stop terminal=false refresh=true"
  echo "Discard recording | bash=\"$CLI\" param1=cancel terminal=false refresh=true"
else
  echo "Record region (Caps+P) | bash=\"$HS\" param1=-c param2=\"require('snag').record()\" terminal=false"
  echo "Record full screen | bash=\"$CLI\" param1=record terminal=false refresh=true"
fi
echo "Analyze video file… | bash=\"$CLI\" param1=ingest param2=--pick terminal=false refresh=true"
[ "$busy" = yes ] && echo "⋯  Pipeline running | disabled=true"

echo "Recent captures"
found=no
for d in $(command ls -t "$CAPTURES" 2>/dev/null | head -5); do
  dir="$CAPTURES/$d"
  [ -d "$dir" ] || continue
  found=yes
  if [ -f "$dir/report.md" ]; then
    echo "-- $d — report | bash=/usr/bin/open param1=\"$dir/report.md\" terminal=false"
  elif [ -f "$dir/result.json" ]; then
    echo "-- $d — done | bash=/usr/bin/open param1=\"$dir\" terminal=false"
  else
    echo "-- $d — processing… | bash=/usr/bin/open param1=\"$dir\" terminal=false"
  fi
done
[ "$found" = no ] && echo "-- none yet | disabled=true"
echo "Open captures folder | bash=/usr/bin/open param1=\"$CAPTURES\" terminal=false"

mode=$(sed -n 's/^SNAG_MODE=//p' "$SNAG/snag.conf" 2>/dev/null)
case "$mode" in
  report) other=verify ;;
  verify) other=meet ;;
  *)      other=report ;;
esac
echo "Mode: ${mode:-report} — switch to $other | bash=\"$CLI\" param1=mode param2=$other terminal=false refresh=true"

echo "---"
LS="$HOME/loadout/lib/settings/loadout-settings"
echo "Settings"
echo "-- Snag | bash=\"$LS\" param1=snag terminal=false"
echo "-- Murmur | bash=\"$LS\" param1=murmur terminal=false"
echo "-- Refine (Hone) | bash=\"$LS\" param1=hone terminal=false"
echo "-- QuickShots | bash=\"$LS\" param1=quickshots terminal=false"
echo "Apps | disabled=true"
echo "Dictate (Murmur) | bash=\"$HS\" param1=-c param2=\"require('murmur').toggle()\" terminal=false"
echo "Refine clipboard (Hone) | bash=\"$HS\" param1=-c param2=\"require('hone').refineClipboard()\" terminal=false"
echo "QuickShots folder | bash=/usr/bin/open param1=\"$HOME/Pictures/QuickShots\" terminal=false"
echo "All shortcuts (Palette) | bash=\"$HS\" param1=-c param2=\"require('palette').show()\" terminal=false"
echo "---"
echo "Reload Hammerspoon | bash=\"$HS\" param1=-c param2=\"hs.reload()\" terminal=false"
