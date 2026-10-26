#!/bin/sh
# Assembles build/AppUpdater.app from the swift build output (menu-bar + window app).
# Usage: Scripts/make-app.sh [release|debug]
set -euo pipefail

CONFIG=${1:-release}
swift build -c "$CONFIG"

APP=build/AppUpdater.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/AppUpdaterApp" "$APP/Contents/MacOS/AppUpdater"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AppUpdater</string>
    <key>CFBundleDisplayName</key><string>AppUpdater</string>
    <key>CFBundleIdentifier</key><string>io.appupdater.AppUpdater</string>
    <key>CFBundleExecutable</key><string>AppUpdater</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Assembled: $APP"
