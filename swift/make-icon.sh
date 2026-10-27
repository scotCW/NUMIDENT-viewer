#!/bin/bash
# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg.
# Needs rsvg-convert (MacPorts: librsvg, Homebrew: librsvg). The generated
# .icns is kept in the repo, so build-app.sh does not need this tool.
set -euo pipefail
cd "$(dirname "$0")/Resources"

WORK="$(mktemp -d)"
# librsvg only loads images from the referencing file's own folder, so the
# wrapper sits next to AppIcon.svg while rendering.
WRAP="$PWD/.AppIcon-wrapper.svg"
trap 'rm -rf "$WORK" "$WRAP"' EXIT

# The seal on a white disc with a thin navy rim, inside the standard macOS
# icon grid (824 pt artwork on a 1024 pt canvas), so it reads in a dark Dock.
cat > "$WRAP" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1024" height="1024" viewBox="0 0 1024 1024">
  <circle cx="512" cy="512" r="412" fill="#ffffff" stroke="#2b2f6e" stroke-width="10"/>
  <image x="182" y="182" width="660" height="660" preserveAspectRatio="xMidYMid meet" xlink:href="AppIcon.svg"/>
</svg>
SVG

SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$WRAP" -o "$SET/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" -h "$((size * 2))" "$WRAP" -o "$SET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$SET" -o AppIcon.icns
echo "Wrote $PWD/AppIcon.icns"
