#!/bin/bash
# One-line installer for Afterglow:
#   curl -fsSL https://raw.githubusercontent.com/h4rdmanmapcreator-beep/AfterGlowWallpaper/main/install.sh | bash
# Downloads the source, builds it on this Mac (so it is never quarantined) and installs it to /Applications.
set -euo pipefail

REPO="h4rdmanmapcreator-beep/AfterGlowWallpaper"
BRANCH="main"

say() { printf '\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31mError: %s\033[0m\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Afterglow only runs on macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "Afterglow needs an Apple silicon Mac (M1 or newer)."

version="$(sw_vers -productVersion)"
major="${version%%.*}"; rest="${version#*.}"; minor="${rest%%.*}"
if (( major < 14 || (major == 14 && minor < 2) )); then
    fail "Afterglow needs macOS 14.2 or later (this Mac has $version)."
fi

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
    say "Installing the Xcode Command Line Tools (a dialog will open)"
    xcode-select --install >/dev/null 2>&1 || true
    fail "Finish the Command Line Tools install, then run this command again."
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

say "Downloading Afterglow"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$work"

say "Building (about a minute)"
cd "$work"/*/
./build.sh install

xattr -dr com.apple.quarantine /Applications/Afterglow.app 2>/dev/null || true

say "Starting Afterglow"
open /Applications/Afterglow.app
echo
echo "Done. Afterglow is in your menu bar (waveform icon)."
echo "On first launch, allow System Audio Recording when macOS asks."
