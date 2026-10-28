#!/bin/bash
# Usage: scripts/make-app.sh [debug|release]
# Builds the Diskinventory product and wraps it in .build/Diskinventory.app.
set -euo pipefail

NAME="Diskinventory"
BUNDLE_ID="com.ooozzy.diskinventory"
CONFIG="${1:-debug}"
case "$CONFIG" in debug|release) ;; *) echo "usage: $0 [debug|release]" >&2; exit 2 ;; esac

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
swift build -c "$CONFIG" --product "$NAME"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$NAME"

APP=".build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
mkdir -p "$APP/Contents/Resources"
cp Sources/DiskApp/Resources/lenses.json "$APP/Contents/Resources/lenses.json"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 ooozzy</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

codesign --force --sign - --deep --options runtime --entitlements scripts/Diskinventory.entitlements "$APP"
echo "Built $APP"
