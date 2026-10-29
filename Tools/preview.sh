#!/bin/bash
# Renders each style to PNG without touching the desktop: ./Tools/preview.sh [output-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/preview}"
mkdir -p "$OUT" build
swiftc -O -swift-version 5 -target arm64-apple-macos14.2 \
    Tools/Preview/main.swift Sources/Engine.swift Sources/Settings.swift Sources/AudioAnalyzer.swift Sources/AudioCapture.swift \
    -o build/preview-tool
./build/preview-tool "$OUT"
