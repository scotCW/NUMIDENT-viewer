#!/bin/bash
# Builds a universal (arm64 + x86_64) NUMIDENT Viewer.app, ad-hoc signed, into ./dist.
# Also copies the universal numident-cli next to it.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NUMIDENT Viewer"
BUNDLE_ID="local.numident.viewer"
VERSION="1.0"
DIST="dist"
APP="$DIST/$APP_NAME.app"

swift build -c release --arch arm64 --arch x86_64 --product NumidentViewer
swift build -c release --arch arm64 --arch x86_64 --product numident-cli
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NumidentViewer" "$APP/Contents/MacOS/NumidentViewer"
cp "$BIN_DIR/numident-cli" "$DIST/numident-cli"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>NumidentViewer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>The NUMIDENT files are read from an external drive.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
codesign --force --sign - "$DIST/numident-cli"

echo
lipo -info "$APP/Contents/MacOS/NumidentViewer"
lipo -info "$DIST/numident-cli"
echo "Built: $APP"
