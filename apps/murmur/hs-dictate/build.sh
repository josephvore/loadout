#!/bin/sh
# Build hs-dictate into ~/bin. SwiftPM package (FluidAudio/Parakeet dependency);
# requires the macOS 26 SDK and Xcode/CLT Swift 6 toolchain.
set -e
cd "$(dirname "$0")"
swift build -c release
cp -f .build/release/hs-dictate "$HOME/bin/hs-dictate"
# Re-sign the copy ad-hoc. `swift build` already ad-hoc signs, but AMFI has
# been seen to SIGKILL the freshly-copied binary (exit 137, no output, no
# crash report) until its cdhash is re-validated; forcing a fresh signature
# on the deployed file makes the first launch reliable instead of needing a
# retry/reload. Harmless if it was already valid.
codesign --force --sign - "$HOME/bin/hs-dictate"
echo "built $HOME/bin/hs-dictate"
