# Snag

EquipFlow bug capture: record a region of your screen while talking through
what you're seeing, and a pipeline transcribes the narration, attaches the
dev-server log slice, and distills it with headless Claude into a **capture
report** — `report.md` in the capture dir, with the items you raised (bug /
feature-request / question / observation), embedded screenshots, code
pointers, and a closing prompt telling the next agent to work out next steps
*with you* before filing anything. A Jam/Loom alternative whose back half is
your own agent stack.

Nothing is auto-filed by default. The auto-file workflow (verify
triage-grade, then `gh issue create` with `ready-for-agent`/`needs-triage`
labels) is the opt-in `verify` mode: `snag mode verify` (back with
`snag mode report`), also switchable from the ✦ menu.

## Architecture — nothing long-lived is load-bearing

Hammerspoon is a *trigger*, not the owner. Every stage is independently
restartable and state lives in files:

```
trigger (any):                     owner:
  Caps+P region select (HS) ─┐
  ✦ menu (SwiftBar) ─────────┼──► snag CLI ──► ffmpeg (detached)
  terminal / Raycast ────────┘        │ stop
                                      ▼
                              queue/<stamp> token
                                      │ launchd WatchPaths
                                      ▼
                       pipeline-runner.sh ──► pipeline.sh
                                                  │
                          notification (terminal-notifier) + report.md
```

- **`snag` CLI** — `record [--screen N] [--crop W:H:X:Y] | stop | cancel |
  status | ingest <file> | mode [report|verify|meet]`. Owns the ffmpeg
  lifecycle via `state/recording.json`; anything can drive it.
- **launchd agent** (`com.loadout.snag-pipeline`, WatchPaths on `queue/`)
  runs `pipeline-runner.sh`, which drains queue tokens under a lock. Reload
  Hammerspoon, quit SwiftBar, whatever — a queued capture still processes,
  and a recording in flight keeps recording.
- **Notifications come from the pipeline itself** (terminal-notifier; click
  opens the report). The report path is also copied to the clipboard.
- **✦ menu bar** — SwiftBar plugin at `~/loadout/swiftbar/snag.3s.sh`:
  live record/stop, processing indicator, last 5 captures, mode switch, and
  shortcuts into the other Loadout apps.
- **Hammerspoon** (`snag.lua`) keeps only Caps+P / Caps+Shift+P and the
  drag-select overlay, then shells out to the CLI. If HS is down, record
  full-screen from ✦ or `snag record` in a terminal.

## Usage

| Action | Binding |
| --- | --- |
| Start / stop recording | Caps+P (or ✦ menu, or `snag record` / `snag stop`) |
| Cancel + discard | Caps+Shift+P (or ✦ menu / `snag cancel`) |
| Analyze a video file | ✦ menu "Analyze video file…" (or `snag ingest <file>`) |

Caps+P dims the screen: drag a region (a plain click records the whole
screen under the cursor; Esc cancels), narrate freely, Caps+P again to stop.
The pipeline runs in the background; a notification with the distilled
summary arrives a few minutes later — click it to open `report.md`.
Follow-up workflow: `claude` in the equipflow repo, paste the report path
(already on your clipboard) — the report's own closing prompt takes it from
there.

For server-side context, run the dev server with `make dev-snag` in the
EquipFlow repo — it tees timestamped output to `tmp/dev-server.log`, and
each capture attaches only the slice covering the recording window.

## Ingesting external video (Google Meet recordings)

`snag ingest <file>` (or ✦ → "Analyze video file…", which opens a file
picker) runs any video — typically a Meet recording downloaded from Google
Drive — through the same pipeline. The file is staged into a normal capture
dir (remuxed to `recording.mov` with `-c copy`, instant for Meet's H.264/AAC
mp4; VP9/webm falls back to a transcode, logged in `ingest.log`) and queued.
The original file is never modified.

Ingested captures default to a third analysis mode, **meet**
(`meet-prompt.md`): meeting notes — summary, decisions, action items, plus
any EquipFlow items that surfaced — written to `report.md` like report mode.
Force the bug-capture modes instead with `snag ingest <file> --mode
report|verify`. Details that differ from live captures:

- `meta.json` gets `source: "ingest"`, the original filename/path, and
  timestamps derived from the file's mtime (endedAt = mtime, startedAt =
  mtime − duration) — rough wall-clock only.
- The dev-log slice is skipped (mtime epochs would match coincidental noise).
- Keyframes spread across the whole video: when duration exceeds
  `FRAME_EVERY × MAX_FRAMES`, the interval grows so `SNAG_MAX_FRAMES` frames
  (default 12, settable) cover the full length.
- Audio longer than `SNAG_CHUNK_SECONDS` (default 120) is segmented into
  `audio-chunks/` and transcribed chunk-by-chunk in one daemon session, with
  `[MM:SS]` offset markers joining the transcript; the transcription
  deadline scales with audio length.

## Recorder notes

Recording is ffmpeg/avfoundation (cursor + system-default mic,
h264_videotoolbox). `screencapture` is unusable for this: it rejects `-v`
with `-i`, and no signal makes it finalize a video file — only `-V` expiry.
ffmpeg finalizes cleanly on SIGINT, which is what makes toggle-to-stop work.
Screens are addressed by avfoundation device *name* ("Capture screen N"),
never index — indexes shift as iPhone/Insta360 cameras come and go.

## Settings

`snag settings` (or ✦ → Settings → Snag) opens a native settings window:
output folder (Browse…; empty = `captures/` in the app dir), pipeline mode
(report/verify/meet), max recording length, max keyframes, dry-run toggle,
and clickable recent outputs. It's
rendered by the shared `loadout-settings` app (see
`~/loadout/settings/README.md`) from `snag.schema.json`, and writes
`snag.conf` — the single source of truth the CLI, pipeline, and ✦ plugin
all follow, so a changed output folder applies everywhere at once.

## Files

- `snag` — the CLI (lifecycle owner). `snag.conf` — all config
  (mode/dry-run/capture root/max seconds).
- `snag.local.conf` (untracked) — machine-specific values, sourced after
  `snag.conf`. Set `SNAG_REPO=/path/to/your/repo` here; the pipeline runs
  Claude in that repo.
- Settings window: shared `loadout-settings` +
  `~/loadout/settings/snag.schema.json`.
- `snag.lua` — thin Hammerspoon trigger (hotkeys + region overlay).
- `pipeline.sh` — extraction → transcription → log slice → claude →
  notification. `pipeline-runner.sh` — launchd queue drainer.
- `transcribe.py` — Parakeet transcription via Murmur's `~/bin/hs-dictate`
  daemon (fully local, ~4s including model load).
- `report-prompt.md` / `verify-prompt.md` / `meet-prompt.md` — the three
  claude modes.
- `~/Library/LaunchAgents/com.loadout.snag-pipeline.plist` — the watcher.
- `~/loadout/swiftbar/snag.3s.sh` — the ✦ menu bar plugin.
- `captures/<stamp>/` — recording, frames, transcript, devlog slice,
  report.md, result.json, pipeline.log. `queue/`, `state/` — plumbing.

## Debugging

- Per-capture: `pipeline.log` and `verifier-output.txt` in the capture dir.
- Runner: `state/runner.log`. Recorder: `recorder.log` in the capture dir.
- Dry-run (skip the claude step): set `SNAG_DRY_RUN=1` in `snag.conf`, or
  run `SNAG_CONF=off SNAG_DRY_RUN=1 ./pipeline.sh <capture-dir>` directly.
- Reprocess any capture: `echo <capture-dir> > queue/<stamp>` (launchd picks
  it up), or run `pipeline.sh <capture-dir>` by hand.
- Pipeline tunables (env or `snag.conf`): `SNAG_FRAME_EVERY` (keyframe
  interval, short clips), `SNAG_MAX_FRAMES` (also in settings),
  `SNAG_CHUNK_SECONDS` (transcription chunk length). Ingest leaves
  `ingest.log` in the capture dir; chunked audio lands in `audio-chunks/`.

## v2 ideas (deliberately out of v1)

- Chrome console/network attach (Claude-in-Chrome extension or CDP).
- Native Swift menu bar app with ScreenCaptureKit picker (replaces both the
  HS overlay and SwiftBar; the day-plus build).
- Auto-launch `/implement` on `ready-for-agent` issues; @claude GitHub Action.
- Reuse Murmur's already-warm daemon instead of spawning a fresh one.
