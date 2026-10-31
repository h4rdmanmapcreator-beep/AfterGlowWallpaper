#!/bin/bash
# Builds the app and zips it for a GitHub release: ./Tools/package.sh  ->  build/Afterglow.zip
# Publish it with:  gh release create v1.0 build/Afterglow.zip --title "Afterglow 1.0" --notes "..."
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
rm -f build/Afterglow.zip
ditto -c -k --keepParent build/Afterglow.app build/Afterglow.zip
echo "Packaged build/Afterglow.zip ($(du -h build/Afterglow.zip | cut -f1))"
