#!/bin/bash
# Builds Afterglow.app with just the Command Line Tools (no Xcode needed).
#   ./build.sh           -> build/Afterglow.app
#   ./build.sh install   -> also copies it to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Afterglow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
    -target arm64-apple-macos14.2 \
    -framework AppKit -framework MetalKit -framework CoreAudio -framework Accelerate -framework ServiceManagement \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/Afterglow"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Shaders.metal "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Afterglow 2>/dev/null || true
    rm -rf /Applications/Afterglow.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Afterglow.app"
fi
