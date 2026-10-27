#!/bin/sh
# Wrap the universal binary in a minimal macOS .app bundle.
# Usage: scripts/make-app.sh bin/numident-viewer 0.1.0
set -eu
BIN=${1:-bin/numident-viewer}
VERSION=${2:-0.1.0}
APP="bin/NUMIDENT Viewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/numident-viewer"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NUMIDENT Viewer</string>
  <key>CFBundleDisplayName</key><string>NUMIDENT Viewer</string>
  <key>CFBundleIdentifier</key><string>local.numident.viewer</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>numident-viewer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# Ad-hoc signature so Apple Silicon will run it; no Developer ID needed.
codesign --force --deep --sign - "$APP"
echo "Built $APP"
