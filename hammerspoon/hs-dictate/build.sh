#!/bin/sh
# Build hs-dictate into ~/bin. Requires macOS 26 SDK (Command Line Tools).
set -e
cd "$(dirname "$0")"
swiftc -O -o "$HOME/bin/hs-dictate" main.swift
echo "built $HOME/bin/hs-dictate"
