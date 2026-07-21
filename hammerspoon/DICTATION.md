# Hammerspoon Dictation

This is a local push-to-talk dictation app loaded by `~/.hammerspoon/init.lua`.
Lua owns the hotkey, paste behavior, cleanup, and logging. The Swift daemon in
`hs-dictate/` owns microphone capture and speech-to-text (Apple SpeechAnalyzer
partials + Parakeet finals).

## Runtime Logs

Start debugging here:

```sh
tail -n 120 ~/dotfiles/hammerspoon/logs/dictation.log
tail -n 120 ~/dotfiles/hammerspoon/logs/refine.log
tail -n 120 ~/dotfiles/hammerspoon/logs/init.log
```

The log files are local and gitignored. `dictation.log` includes short transcript
samples so agents can compare raw capture, local cleanup, LLM formatting, and
final paste output.

## Pipeline

1. Right Command starts a take through `dictation.lua`.
2. `~/bin/hs-dictate` streams live partials from Apple's `SpeechTranscriber`
   for the pill overlay while buffering the take's raw audio. On stop,
   Parakeet TDT 0.6b (FluidAudio CoreML, Apple Neural Engine, ~0.2s/take,
   roughly half Apple's word error rate) re-transcribes the buffered audio
   and owns the final transcript; Apple's finalized text is the automatic
   fallback if Parakeet is still loading, fails, or exceeds its 1.2s budget.
   The `final` event carries `engine: parakeet|speech|dictation` so logs show
   which engine produced each take.
3. Lua keeps the raw transcript on the clipboard as a backup (marked
   `org.nspasteboard.ConcealedType` so clipboard managers skip it).
4. Local cleanup normalizes glossary/correction entries and spoken edit
   commands like "scratch that" or "new paragraph".
5. Every ordinary take (4+ words) goes through the Wispr-style LLM cleanup
   pass: fillers, false starts, stutters, backtracking ("actually no", "no
   wait"), and pause-punctuation fragments are removed; nothing is
   paraphrased. The prompt also receives the frontmost app name and up to
   240 chars of AX text before the cursor, so mid-sentence insertions get
   the right capitalization and in-document terminology. The fastest
   provider with a Keychain key wins — Cerebras > Groq > OpenAI (see
   `providers` in `refine.lua`). The Literal profile and tiny takes skip
   the pass. The HTTPS connection is pre-warmed when the take STARTS, so
   the polish request never pays TLS handshake latency.
6. The result is validated in `dictation_core.validateAIOutput` (LCS word
   coverage: deletions allowed, invented words rejected; numerals, URLs, and
   prompt-leak guards). If cleanup fails validation, errors, or exceeds
   `autoRefineTimeout`, the locally cleaned transcript is pasted instead.
7. After each paste, unknown proper nouns ("EquipFlow", "Daniel") are
   counted; the second sighting auto-appends the word to the glossary and
   reloads the recognizer context, so the ASR stops mishearing it
   (`glossaryAutoLearn` in dictation.lua; counts live in
   `logs/dictation_proper_nouns.tsv`).

## Performance Notes

- The daemon stays warm and keeps the mic hot by default (`--idle -1`).
- Hammerspoon resets the daemon if mic start gets stuck instead of leaving the
  trigger in a dead `starting` state.
- Stop grace is 150ms (`stopGraceMs`); finalize/Parakeet run concurrently and
  are bounded in Swift, so stop→final is typically ~0.3-0.5s. If Apple's
  finalizer hangs, the streamed transcript is returned and pasted.
- Ordinary takes wait on the LLM pass, bounded by `autoRefineTimeout`. Raw
  text is copied to the clipboard before cleanup starts, so a network/API
  failure still leaves the words recoverable. With a Groq/Cerebras key the
  pass adds ~0.3-0.7s; on OpenAI (gpt-5.4-nano) ~1.2-2s.
- Parakeet models (~480MB) download once to
  `~/Library/Application Support/FluidAudio/`; until they land, takes use
  Apple finals. `dictation.log` records which engine served each take.
- `dictation.log` records start latency, finalize latency, take duration, and
  paste queue time for tuning.

## Build

```sh
~/dotfiles/hammerspoon/hs-dictate/build.sh   # SwiftPM release → ~/bin/hs-dictate
```

The daemon is a SwiftPM package (FluidAudio dependency); a bare `swiftc`
build no longer works. Debug hook: send `parakeet-file /path/to.wav` on the
daemon's stdin to transcribe a file through Parakeet without using the mic.

## Improvement Backlog

- Add a correction review command that appends bad -> good pairs to
  `dictation_corrections.tsv` from the last pasted transcript.
- Add a visible status command in the shortcuts menu that opens the latest log.
- Optional: Parakeet custom-vocabulary boosting (CTC keyword spotter, ~130MB
  extra model) if LLM-side glossary correction ever proves insufficient.
- Optional: speculative LLM polish on the live partial during finalize
  (Wispr-style) if the paste path ever needs another ~200ms.
