#!/usr/bin/env bash
# Build hs-dictate into ~/bin. SwiftPM package (FluidAudio/Parakeet dependency);
# requires the macOS 26 SDK and Xcode/CLT Swift 6 toolchain.
set -euo pipefail

cd "$(dirname "$0")"
swift build -c release

dest_dir="${HOME}/bin"
dest="${dest_dir}/hs-dictate"
staged="${dest}.loadout-new-$$"
mkdir -p "$dest_dir"
trap 'rm -f "$staged"' EXIT
cp .build/release/hs-dictate "$staged"
# Re-sign the copy ad-hoc. `swift build` already ad-hoc signs, but AMFI has
# been seen to SIGKILL the freshly-copied binary (exit 137, no output, no
# crash report) until its cdhash is re-validated; forcing a fresh signature
# on the deployed file makes the first launch reliable instead of needing a
# retry/reload. Harmless if it was already valid.
codesign --force --sign - "$staged"

if [ -e "$dest" ] || [ -L "$dest" ]; then
  # A deployed command must be self-contained. Even when a symlink resolves to
  # identical bytes, back up the link itself and replace it with this build.
  if [ ! -L "$dest" ] && cmp -s "$staged" "$dest"; then
    rm -f "$staged"
    trap - EXIT
    echo "up to date: $dest"
    exit 0
  fi
  backup="${dest}.backup-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$dest" "$backup"
  echo "backed up existing: $dest -> $backup"
fi
mv -f "$staged" "$dest"
trap - EXIT
echo "built $dest"
