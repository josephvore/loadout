# Murmur

On-device, push-to-talk voice-to-text for macOS, with an optional LLM cleanup
pass. A free, open-source replacement for Wispr Flow, Superwhisper, and
MacWhisper.

Hold a key, speak, release — the transcript lands in whatever app has focus.
Capture and transcription run entirely on your Mac. After the one-time package
and model downloads, only optional cleanup can send runtime data over the
network (see [On-device vs. cloud](#on-device-vs-cloud)).

## How it works

Speech-to-text runs locally through `~/bin/hs-dictate`, a small Swift daemon.
[FluidAudio](https://github.com/FluidInference/FluidAudio) Parakeet streaming
updates the on-screen pill while you speak; a Parakeet TDT batch pass produces
the final transcript, with Apple's SpeechAnalyzer text as the automatic
fallback. The first daemon launch downloads about 480 MB for batch recognition
and 120 MB for streaming to `~/Library/Application Support/FluidAudio/`.

The daemon stays warm between takes with the models loaded and the mic engine
hot, so takes start instantly and work offline.

### Live transcript panel

While you speak, a panel above the status pill shows the **whole take**, not a
truncated tail. It grows with the transcript up to a maximum height, then
scrolls pinned to the newest words; scrolling up releases the pin (a "↓ live"
button re-pins). Text renders in three tiers: **polished** sentences at full
opacity, **committed but still raw** words slightly dimmed, and the
still-revisable recognizer tail dimmest — so revision-in-place is legible
instead of alarming. Your glossary and learned corrections are applied
word-level to the live text as you speak.

### Live polish

With `livePolish = true` (the default), the transcript polishes itself
**while you speak**: committed text is divided into sentence-sized segments,
and each settled segment gets a small LLM call — fillers and false starts
vanish, self-corrections collapse, punctuation and capitalization land, and
obvious mis-transcriptions get fixed from context. You watch sentences
upgrade in place (a brief highlight marks each one).

Releasing the key races a **full polish of the accurate batch transcript**
against a hard cap (`livePolishFinalSeconds`, ~1.5 s): whole-take context
means cross-sentence rambling collapses and stream mishearings the batch
pass corrected never reach the paste, while the cap keeps the stop feeling
instant. If the full polish misses the cap, the paste is the screen text —
polished segments plus the remainder spliced from the batch transcription —
and the full polish, when it lands late, is kept for a Caps+R swap.

Free-tier rate limits are managed so the final polish — the one call whose
latency budget is tightest — doesn't pay for the take's own segment calls:
after any HTTP 429, Hone cools that provider for ~30 s and the fallback
chain starts at the next live provider instead of re-burning the doomed
attempt. The validator that guards every polish is ITN-aware: rendering
spoken numbers as digits ("the number four" → "4", "seven thirty" → "7:30",
"nineteen ninety five" → "1995") is accepted, while inventing, dropping, or
altering a number is still rejected.

Any live failure (rate limit, network, rejected output) just leaves those
segments raw — words are never lost or delayed. If *nothing* got polished
live (very short takes, total outage), the classic end-of-take polish runs
instead.

### Raw vs. polished

The raw batch transcript is the source of truth and is always retained; every
polish — live segments included — reads raw recognizer text, never earlier
LLM output. After a paste, **Caps+R** (or ⌃⌥⌘D without QuickShots) swaps the
pasted text between its polished and raw versions in place (in apps exposing
the accessibility text API; elsewhere the other version lands on the
clipboard). If an end-of-take polish finishes just after its timeout already
pasted raw, it is still kept — an alert offers Caps+R to swap.

## Hotkeys

| Key | Action |
| --- | --- |
| Hold **Caps**, press **M**, speak, release Caps | Push-to-talk: transcribe and paste |
| Tap **Caps+M** | Hands-free: keep listening until you press Caps+M again |
| **Esc** | Cancel the current take and discard it |
| **Caps+R** (or ⌃⌥⌘D) | Swap the last paste between polished and raw |

Caps+M binds into QuickShots' shared Caps (F18) tap: Caps+M starts the take and
letting go of Caps ends it. A short Caps+M tap counts as hands-free; holding
Caps is push-to-talk. Rebind it from Palette (Caps+K). Set `capsTrigger = false`
and `trigger = { {}, "rightcmd" }` in `murmur.lua` to use a bare modifier key
instead; Murmur falls back to Right ⌘ on its own if the Caps tap is unavailable.
With a modifier trigger, pressing any other key while it is down means you were
typing a normal shortcut, so dictation silently cancels and the shortcut goes
through untouched.

## On-device vs. cloud

Capture and transcription are fully on-device — no audio ever leaves your Mac.
The **optional cleanup pass is the exception**: it sends the transcript text,
the frontmost app name, and (when available) up to 240 characters immediately
before the cursor to a cloud LLM via
[Hone](https://github.com/josephvore/loadout/tree/main/apps/hone). Hone supports
OpenAI, Groq, and Cerebras; provider billing and data policies apply.

**Auto is the default profile.** When Hone is installed and any supported key
exists, eligible dictation takes automatically use that cloud cleanup path. Set
the profile to Literal before dictating if you want transcript data to remain
local while keeping Hone available for its manual hotkeys.

To keep transcript data local, use the **Literal** profile or disable AI
cleanup. No transcript, context, or audio is sent in that mode; the initial
Swift dependency and speech-model downloads still require the network.

### Cleanup profiles

- **Auto** — pick the treatment based on context.
- **Prompt** — tuned for prompts and instructions.
- **Message** — tuned for chat and email.
- **Literal** — no AI cleanup; local polish only, fully on-device.

## Requirements

- Complete Loadout's [fresh-Mac prerequisites](../../PREREQUISITES.md) first.
- macOS 26 or later; the shipped locale/model defaults are English (`en_US`).
- Apple Silicon is tested; Intel Macs are currently unverified.
- [Hammerspoon](https://www.hammerspoon.org) 1.1.1 or later.
- Xcode 26 Command Line Tools (Swift 6 + macOS 26 SDK).
- At least 2 GB free for SwiftPM build artifacts and about 600 MB of models.
- API key(s) for the cleanup pass — optional but recommended. Set them via
  Hone's `setup-keys.sh`.
- Lua 5.4+ and ShellCheck only if you want to run `./test.sh`.

## Install

```sh
git clone https://github.com/josephvore/loadout.git ~/loadout
cd ~/loadout
apps/murmur/install.sh
open -a Hammerspoon
```

The installer symlinks the module into `~/.hammerspoon`, copies the example data
files, links the daemon source, and builds the Swift executable into
`~/bin/hs-dictate`. Keep the clone at this path because it is the live symlink
target. If the build fails, the files remain installed but the command exits 1;
fix the toolchain and retry with:

```sh
~/.hammerspoon/murmur/hs-dictate/build.sh
```

### Permissions

macOS will prompt the first time things run. Grant Hammerspoon:

- **Accessibility** — to paste and to read the surrounding context.
- **Microphone** — to capture audio.

Reload Hammerspoon, hold Caps and press M, speak a short phrase, and release Caps. The
first take can wait while the local models download; the phrase should then paste
into the focused app.

## Data files

Your personal dictation data lives in `~/.hammerspoon/murmur/`:

- `dictation_glossary.txt` — canonical spellings of names and terms.
- `dictation_corrections.tsv` — learned "wrong → right" replacements.
- `dictation_snippets.tsv` — text expansions.
- `takes.jsonl` — the take archive (raw/cleaned/pasted/polished per paste).
- `dictation_edit_mined.tsv` — edit-mining counts (see below).
- `self_eval/` — nightly self-eval reports.

Murmur auto-learns frequently-seen proper nouns into the glossary so the
recognizer stops mishearing them. These files are copied on install and are
**never overwritten** on re-install, so your edits and learned terms stay put.

## Self-improvement loop

Murmur watches its own output and gets better with use — the same loop
Wispr Flow runs, built from three pieces:

1. **Take archive** — every paste appends the full raw, cleaned, pasted,
   and polished text plus timings to `takes.jsonl` (log samples truncate;
   the archive doesn't). Local only, like the logs.
2. **Edit mining** — ~45 s after a paste, Murmur re-reads the target text
   field via the accessibility API and diffs it against what it pasted.
   Word replacements you typed inside the pasted region are correction
   candidates; a pair seen twice is promoted into
   `dictation_corrections.tsv` (an alert announces it) so the whole
   pipeline stops making that mistake. Common words are filtered; edits
   outside the pasted region are ignored.
3. **Nightly self-eval** (`tools/self_eval.lua`, scheduled via
   `config.selfEval` at 03:30, or run on demand with
   `hs -c "require('murmur').selfEval()"`) — replays the day's archived
   takes past an LLM judge (unresolved self-corrections, uncollapsed
   repeats, missing question marks, number formatting), re-runs judged-bad
   takes through the *current* prompt + validator to see whether today's
   pipeline would have done better, aggregates cap-miss / rejection / 429
   rates from the logs, writes a report to `self_eval/YYYY-MM-DD.md`, and
   appends judged-bad takes to `tests/polish_cases_auto.lua` as regression
   inputs. The result arrives as a notification.

### Voice commands and spoken punctuation

Layout commands ("new paragraph", "new bullet", "open quote"…) are applied
locally, but skipped when preceded by a determiner — "we need a new
paragraph about pricing" keeps its words. Bare spoken-punctuation words
("question mark", "comma", "period") are **never** regex-substituted:
context-blind substitution once turned "a question mark wasn't even added"
into "a? wasn't even added". Rendering intended punctuation is the polish
LLM's job, which understands the difference between saying a comma and
talking about one.

For local troubleshooting, Murmur logs transcript samples of up to 320
characters by default in `~/.hammerspoon/logs/murmur.log`. The log rotates at
1 MB with four archives and never leaves the Mac. Set
`logTranscriptSamples = false` in `murmur.lua` and reload Hammerspoon to omit
transcript text from future logs.

## Tests

```sh
./test.sh                               # full Loadout checks
lua apps/murmur/tests/test_murmur.lua  # Murmur replay suite only
```

`tests/polish_cases.lua` holds the polish acceptance fixtures — raw dictation
plus the expected polished output for each targeted failure mode (rephrasing
collapse, self-corrections, questions left unanswered, hedges and emphasis
preserved, numbers byte-identical, spoken enumerations becoming lists). The
offline suite asserts the output validator accepts every fixture and rejects
each counterexample. To replay the fixtures through the live polish prompt and
provider (network, manual, paced for free-tier rate limits):

```sh
lua apps/murmur/tests/eval_polish.lua        # first provider with a key
lua apps/murmur/tests/eval_polish.lua groq   # force a provider
```

To eyeball the transcript panel without dictating (no mic, no network — the
live polish is stubbed, including one deliberately rejected segment):

```sh
hs -c "require('murmur').previewPanel()"
hs -c "require('murmur').previewPanel({ livePolish = false })"  # raw-only view
```

Suite-wide update and safe-uninstall guidance is in the
[Loadout README](../../README.md#update-and-uninstall).

## About

Murmur is part of the [Loadout](https://github.com/josephvore/loadout) suite.
See its [changelog](https://github.com/josephvore/loadout/blob/main/CHANGELOG.md).
Licensed under [MIT](./LICENSE).
