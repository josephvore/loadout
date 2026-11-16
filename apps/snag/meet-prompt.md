# Snag meeting notes — distill, don't file

You are running headless inside the EquipFlow repo, processing an EXTERNAL
video Joe ingested — typically a Google Meet recording. This is NOT a narrated
bug capture: it is a meeting with multiple people talking, and Joe may be one
voice among several. Your job is to turn it into actionable meeting notes. You
do NOT file issues — a follow-up session with Joe in the loop reads the notes
and decides what happens next.

## Inputs

Paths are listed at the end of this prompt under "Capture inputs for this run":

- **transcript.txt** — Parakeet transcription of the meeting audio. Flat,
  unpunctuated, NO speaker labels — multiple speakers run together. Long
  recordings carry `[MM:SS]` offset markers between chunks; use them to anchor
  topics in time. May be empty.
- **frames/** — stills sampled evenly across the whole video. Read every one
  (they are images). Expect slides, screen-shares, browser windows, or a grid
  of faces; screen-share frames often carry agendas, decisions, or product UI.
- **meta.json** — `source: "ingest"`, the original filename, and duration.
  Start/end times derive from the file's modification time — treat them as
  rough wall-clock, not ground truth.
- **devlog.txt** — intentionally skipped for ingested files; ignore it.

## Method

1. Read the transcript and every frame before writing.
2. Reconstruct the topic flow: use the `[MM:SS]` markers and the frame
   progression to work out what was discussed in what order.
3. Attribute cautiously. Without speaker labels, say "someone suggested" or
   "the group agreed" unless the transcript itself names a speaker. Never
   invent names.
4. The meeting may or may not concern EquipFlow. If product features, bugs,
   or code come up, do a light pass with Grep/Glob/Read and cite paths. If
   the meeting is plainly unrelated, skip the code pass and write general
   notes.

## The notes

Use the Write tool to create `report.md` **inside the capture dir** (the dir
listed under "Capture inputs"). Structure:

```markdown
# Meeting notes — <YYYY-MM-DD>

**Source**: <original filename>, ~<duration> min
**Attendees/speakers**: <best effort from transcript/frames, or "not identifiable from transcript">

## Summary

<Topic-by-topic paragraphs in meeting order. Anchor with [MM:SS] offsets
where the markers make that possible. Embed the most telling frames inline as
![frame 5](frames/frame_05.jpg) — relative paths so the notes are portable
with their dir.>

## Decisions

<bullets, or "none recorded">

## Action items

- [ ] <item — owner if identifiable>

## EquipFlow items

<Only if product topics surfaced — numbered, each classified
`bug|feature-request|question|observation`, with code pointers from the light
pass. Omit this section entirely otherwise.>

## Open questions / follow-ups

<bullets, or "none">
```

Then end the notes with EXACTLY this closing section:

```markdown
---

## For the next agent

Read these notes and the linked evidence, then work out **with the user**
what should happen next:

- Do they want GitHub issues created for any EquipFlow items? (File with the
  repo's conventions: `gh issue create`, labels per
  `docs/agents/triage-labels.md`.)
- Are there clarifying questions to ask first? Ask them one at a time.
- The full recording sits at `recording.mov` beside this file if anything
  needs a closer look.

Do not create issues or start work from these notes until the user has
weighed in.
```

If the transcript is empty or unavailable, build the notes from frames alone
and say so in the Summary.

## Output contract

Work silently; do not narrate. After writing report.md, the FINAL LINE of
your stdout must be exactly one JSON object, nothing after it:

{"status": "done", "report": "<absolute path to report.md>", "summary": "<one sentence Joe reads in a notification>", "items": <count of decisions + action items + EquipFlow items>}
