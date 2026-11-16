#!/usr/bin/env python3
"""Transcribe audio file(s) through Murmur's hs-dictate daemon (Parakeet).

Spawns a fresh daemon with the batch Parakeet pass enabled, waits for the
model to warm, sends `parakeet-file <path>` per file, and prints the combined
transcript to stdout. The daemon answers "(unavailable)" until the model
finishes loading, so retry on that until the deadline. Multiple files are
treated as sequential chunks of one recording: each chunk after the first is
prefixed with its [MM:SS] offset; a single file prints bare text.

The daemon awaits each transcription before reading the next stdin line, so
never re-send while a result is pending — only after an "(unavailable)"
answer. Blind periodic re-sends queue duplicate work.
"""
import contextlib
import json
import os
import signal
import subprocess
import sys
import time
import wave

DAEMON = os.path.expanduser("~/bin/hs-dictate")
PARAKEET_VERSION = "v2"  # matches murmur.lua config so the model is already downloaded
DEADLINE_BASE = 60        # daemon spawn + Parakeet warm-up
DEADLINE_PER_SECOND = 0.5  # per second of audio; Parakeet runs well above realtime
DEADLINE_MIN = 150        # never tighter than the old single-shot budget
RETRY_INTERVAL = 3


def die(msg):
    print(f"transcribe: {msg}", file=sys.stderr)
    sys.exit(1)


def wav_seconds(path):
    try:
        with contextlib.closing(wave.open(path)) as w:
            return w.getnframes() / float(w.getframerate() or 16000)
    except Exception:
        return 0.0


def transcribe_one(proc, send, wav, deadline):
    send(f"parakeet-file {wav}")
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            die("daemon exited mid-transcription")
        try:
            event = json.loads(line)
        except ValueError:
            continue
        msg = event.get("message", "")
        if not msg.startswith("parakeet-file: "):
            continue
        text = msg[len("parakeet-file: "):]
        if text == "(unavailable)":
            time.sleep(RETRY_INTERVAL)  # model still loading
            send(f"parakeet-file {wav}")
            continue
        return text
    die("timed out waiting for Parakeet")


def main():
    if len(sys.argv) < 2:
        die("usage: transcribe.py <audio.wav> [more.wav ...]")
    wavs = [os.path.abspath(p) for p in sys.argv[1:]]
    for wav in wavs:
        if not os.path.exists(wav):
            die(f"no such file: {wav}")
    if not os.path.exists(DAEMON):
        die(f"hs-dictate not found at {DAEMON} (build it via murmur's install.sh)")

    durations = [wav_seconds(w) for w in wavs]
    deadline_s = max(DEADLINE_MIN, int(DEADLINE_BASE + DEADLINE_PER_SECOND * sum(durations)))
    signal.alarm(deadline_s + 30)  # hard watchdog on the whole run
    proc = subprocess.Popen(
        [DAEMON, "--parakeet", PARAKEET_VERSION],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, bufsize=1,
    )

    def send(cmd):
        proc.stdin.write(cmd + "\n")
        proc.stdin.flush()

    deadline = time.time() + deadline_s
    try:
        while time.time() < deadline:
            line = proc.stdout.readline()
            if not line:
                die("daemon exited before ready (mic permission?)")
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("event") == "ready":
                break
            if event.get("event") == "error":
                die(f"daemon error: {event.get('message')}")
        else:
            die("timed out waiting for Parakeet")

        parts = []
        offset = 0.0
        for wav, dur in zip(wavs, durations):
            text = transcribe_one(proc, send, wav, deadline)
            if len(wavs) > 1:
                parts.append("[%02d:%02d] %s" % (*divmod(int(offset), 60), text))
            else:
                parts.append(text)
            offset += dur
        print(" ".join(parts))
    finally:
        try:
            send("quit")
            proc.wait(timeout=5)
        except Exception:
            proc.kill()


if __name__ == "__main__":
    main()
