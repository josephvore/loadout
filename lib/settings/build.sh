#!/bin/bash
# Build loadout-settings. Requires the Swift toolchain (present for murmur).
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -o loadout-settings loadout-settings.swift
echo "built -> $(pwd)/loadout-settings"
