#!/bin/bash
# One-line installer for Afterglow (no developer tools needed):
#   curl -fsSL https://raw.githubusercontent.com/h4rdmanmapcreator-beep/AfterGlowWallpaper/main/install.sh | bash
# Downloads the latest prebuilt app, clears macOS's quarantine flag, installs it to /Applications and starts it.
set -euo pipefail

REPO="h4rdmanmapcreator-beep/AfterGlowWallpaper"
URL="${AFTERGLOW_URL:-https://github.com/$REPO/releases/latest/download/Afterglow.zip}"

say() { printf '\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31mError: %s\033[0m\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Afterglow only runs on macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "Afterglow needs an Apple silicon Mac (M1 or newer)."

version="$(sw_vers -productVersion)"
major="${version%%.*}"; rest="${version#*.}"; minor="${rest%%.*}"
if (( major < 14 || (major == 14 && minor < 2) )); then
    fail "Afterglow needs macOS 14.2 or later (this Mac has $version)."
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

say "Downloading Afterglow"
curl -fsSL "$URL" -o "$work/Afterglow.zip" || fail "Download failed ($URL)."
ditto -x -k "$work/Afterglow.zip" "$work"
[[ -d "$work/Afterglow.app" ]] || fail "The download did not contain Afterglow.app."

say "Installing to /Applications"
pkill -x Afterglow 2>/dev/null || true
sleep 0.5
rm -rf /Applications/Afterglow.app
ditto "$work/Afterglow.app" /Applications/Afterglow.app

# The app is signed ad hoc, not notarized, so clear the download flag, make sure the program is
# executable, and re-seal the signature in case the copy lost anything on the way.
xattr -cr /Applications/Afterglow.app
chmod +x /Applications/Afterglow.app/Contents/MacOS/Afterglow
codesign --force --sign - /Applications/Afterglow.app 2>/dev/null

say "Starting Afterglow"
open /Applications/Afterglow.app
echo
echo "Done. Afterglow is in your menu bar (waveform icon)."
echo "On first launch, allow System Audio Recording when macOS asks."
