# Snag capture report — distill, don't file

You are running headless inside the EquipFlow repo, processing a screen
recording Joe just captured while narrating. Your job is to distill the
capture into a standalone markdown report. You do NOT file issues, and you do
NOT need to fully verify anything — a follow-up session with Joe in the loop
reads the report and decides what happens next.

## Inputs

Paths are listed at the end of this prompt under "Capture inputs for this run":

- **transcript.txt** — Parakeet transcription of Joe's narration. Spoken,
  unpunctuated, possibly rambling. May be empty — frames and logs stand alone.
- **frames/** — chronological keyframes from the recording. Read every one
  (they are images); UI changes between frames tell the story.
- **devlog.txt** — dev-server output covering the recording window, each line
  prefixed `[epoch]`.
- **meta.json** — timestamps, frontmost app, active Chrome tab URL/title.

## Method

1. Read every input before writing. Look at all frames in order.
2. Extract Joe's **intent**: what was he trying to do or communicate?
3. Split the narration into distinct **items** — there may be several, and
   they are not all bugs: classify each as `bug`, `feature-request`,
   `question`, or `observation`. Rambling in, precision out — keep the
   meaning, drop the noise.
4. For likely-relevant code, do a light pass with Grep/Glob/Read and cite
   paths — best effort, not a full investigation.

## The report

Use the Write tool to create `report.md` **inside the capture dir** (the dir
listed under "Capture inputs"). Structure:

```markdown
# Snag capture — <YYYY-MM-DD HH:MM>

**Context**: <route/app from meta.json, one line>
**Intent**: <what Joe was trying to do or communicate, 1–2 sentences>

## Items

### 1. <short title> — `bug|feature-request|question|observation`

<What Joe said and showed, distilled. Quote the load-bearing transcript
phrases. For bugs: expected vs actual.>

**Evidence**: <embed the most telling keyframes inline as
![frame 3](frames/frame_03.jpg) — relative paths so the report is portable
with its dir — and quote relevant devlog lines>

**Code pointers**: <files/paths found in the light pass, or "none found">

**Open questions**: <what's unclear or unverified, or "none">

<### 2. … repeat per item>
```

Then end the report with EXACTLY this closing section:

```markdown
---

## For the next agent

Read this report and the linked evidence, then work out **with the user**
what should happen next:

- Do they want GitHub issues created for any of the items? (File with the
  repo's conventions: `gh issue create`, labels per
  `docs/agents/triage-labels.md`.)
- Are there clarifying questions to ask first? Ask them one at a time.
- Does anything need verification or reproduction before it's actionable?
  The full recording sits at `recording.mov` beside this file.
- Feature requests and design observations should be discussed, not filed
  blind.

Do not create issues or start fixes until the user has weighed in.
```

If the transcript is empty or unavailable, build the report from frames +
logs and say so in the Intent line.

## Output contract

Work silently; do not narrate. After writing report.md, the FINAL LINE of
your stdout must be exactly one JSON object, nothing after it:

{"status": "done", "report": "<absolute path to report.md>", "summary": "<one sentence Joe reads in a notification>", "items": <count>}
