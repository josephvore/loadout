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
2. `~/bin/hs-dictate` streams partial text and returns a final transcript.
3. Lua keeps the raw transcript on the clipboard as a backup.
4. Conservative local cleanup normalizes exact glossary/correction entries.
5. The cleaned raw text is pasted immediately.
6. AI cleanup stays available through `refine.lua`, but it is off by default for
   the dictation path because it adds latency and can invent punctuation.

## Wispr-Style Improvement Backlog

- Add a small "polish profile" setting: raw, light formatting, or full cleanup.
- Add a correction review command that appends bad -> good pairs to
  `dictation_corrections.tsv` from the last pasted transcript.
- Track latency metrics in `dictation.log`: trigger down -> started, stop ->
  final, final -> pasted, formatter duration.
- Add per-app defaults. Example: raw in terminals, light polish in browsers,
  fuller cleanup in notes/email.
- Add a replay harness that feeds saved raw transcripts through cleanup prompts
  so prompt changes can be tested before reloading Hammerspoon.
- Add a visible status command in the shortcuts menu that opens the latest log.
