#!/bin/bash
# Builds a universal (arm64 + x86_64) NUMIDENT Viewer.app into ./dist.
# Also copies the universal numident-cli next to it.
#   SIGN_IDENTITY   certificate to sign with; ad-hoc when unset
#   NOTARY_PROFILE  notarytool keychain profile; when set, notarizes and staples
#                   (needs a "Developer ID Application" SIGN_IDENTITY)
set -euo pipefail
cd "$(dirname "$0")"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

APP_NAME="NUMIDENT Viewer"
BUNDLE_ID="app.NUMIDENT-viewer"
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

if [ "$SIGN_IDENTITY" = "-" ]; then
    SIGN_FLAGS=(--force --sign -)
else
    # Hardened runtime and a secure timestamp are what notarization requires.
    SIGN_FLAGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign "${SIGN_FLAGS[@]}" "$DIST/numident-cli"
codesign --verify --strict "$APP"

if [ -n "$NOTARY_PROFILE" ]; then
    # The app's ticket is stapled so it opens offline; a bare tool can't hold a
    # ticket, so Gatekeeper looks numident-cli's up online.
    ZIP="$DIST/notarize.zip"
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE" "$ZIP"' EXIT
    ditto "$APP" "$STAGE/$APP_NAME.app"
    cp "$DIST/numident-cli" "$STAGE/numident-cli"
    ditto -c -k "$STAGE" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

echo
lipo -info "$APP/Contents/MacOS/NumidentViewer"
lipo -info "$DIST/numident-cli"
echo "Built: $APP (signed with: $SIGN_IDENTITY)"
