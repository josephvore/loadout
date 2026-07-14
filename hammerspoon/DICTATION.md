# Hammerspoon Dictation

This is a local push-to-talk dictation app loaded by `~/.hammerspoon/init.lua`.
Lua owns the hotkey, paste behavior, cleanup, and logging. The Swift daemon in
`hs-dictate/` owns microphone capture and Apple SpeechAnalyzer transcription.

## Runtime Logs

Start debugging here:

```sh
tail -n 120 ~/dotfiles/hammerspoon/logs/dictation.log
tail -n 120 ~/dotfiles/hammerspoon/logs/refine.log
tail -n 120 ~/dotfiles/hammerspoon/logs/init.log
```

The log files are local and gitignored. `dictation.log` includes short transcript
samples so agents can compare raw capture, local cleanup, OpenAI formatting, and
final paste output.

## Pipeline

1. Right Command starts a take through `dictation.lua`.
2. `~/bin/hs-dictate` prefers Apple's newer `SpeechTranscriber`, streams
   partial text, and returns a final transcript. `DictationTranscriber` remains
   an automatic compatibility fallback.
3. Lua keeps the raw transcript on the clipboard as a backup.
4. Local cleanup normalizes glossary/correction entries and spoken edit
   commands like "scratch that" or "new paragraph".
5. Only explicit backtracking such as “actually no” or “let me change that”
   is sent through the conservative OpenAI cleanup pass.
6. The validated result is pasted. If cleanup changes unrelated words, fails,
   or exceeds the timeout, the locally cleaned transcript is pasted instead.

## Performance Notes

- The daemon stays warm and keeps the mic hot by default (`--idle -1`).
- Hammerspoon resets the daemon if mic start gets stuck instead of leaving the
  trigger in a dead `starting` state.
- Stop/finalize is bounded in Swift; if Apple's finalizer hangs, the streamed
  transcript is returned and pasted.
- Ordinary takes never wait on OpenAI. Raw text is copied to the clipboard
  before any explicit-correction cleanup starts, so a network/API failure still
  leaves the words recoverable.
- `dictation.log` records start latency, finalize latency, take duration, and
  paste queue time for tuning.

## Wispr-Style Improvement Backlog

- Add a correction review command that appends bad -> good pairs to
  `dictation_corrections.tsv` from the last pasted transcript.
- Add per-app defaults. Example: raw in terminals, light polish in browsers,
  fuller cleanup in notes/email.
- Add an opt-in API replay harness for prompt changes; deterministic transcript
  and validator cases already run through `tests/test_dictation.lua`.
- Add a visible status command in the shortcuts menu that opens the latest log.
