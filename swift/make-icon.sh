#!/bin/bash
# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg.
# Needs rsvg-convert (MacPorts: librsvg, Homebrew: librsvg). The generated
# .icns is kept in the repo, so build-app.sh does not need this tool.
set -euo pipefail
cd "$(dirname "$0")/Resources"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" AppIcon.svg -o "$SET/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" -h "$((size * 2))" AppIcon.svg -o "$SET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$SET" -o AppIcon.icns
echo "Wrote $PWD/AppIcon.icns"
