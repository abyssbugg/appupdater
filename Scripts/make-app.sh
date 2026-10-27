#!/bin/sh
# Assembles build/AppUpdater.app from the swift build output (menu-bar + window app).
# Usage: Scripts/make-app.sh [release|debug]
#
# Phase 5 (self-update): embeds Sparkle.framework and configures the Sparkle
# Info.plist keys. Env knobs (all optional):
#   APPUPDATER_FEED_URL       — SUFeedURL for self-update checks.
#                               Default: https://raw.githubusercontent.com/abyssbugg/appupdater/main/appcast.xml
#                               (the live feed — set .invalid for honest-unreachable local tests)
#   APPUPDATER_PUBLIC_ED_KEY  — SUPublicEDKey (Sparkle EdDSA public key). Default: the
#                               committed release key (public half; private half is keychain-only).
#   APPUPDATER_VERSION        — CFBundleShortVersionString.  Default: 0.1.0
#   APPUPDATER_BUILD          — CFBundleVersion.             Default: 1
#                               ⚠ Sparkle compares CFBundleVersion against the appcast's
#                               sparkle:version — a release MUST advance BOTH (guarded in
#                               Scripts/make-release.sh).
# Automatic checks are hard-off (SUEnableAutomaticChecks=false): self-update runs only
# through the explicit "Check for Self-Update…" menu action.
set -euo pipefail

CONFIG=${1:-release}
VERSION="${APPUPDATER_VERSION:-0.1.0}"
BUILD="${APPUPDATER_BUILD:-1}"
swift build -c "$CONFIG"

APP=build/AppUpdater.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp ".build/$CONFIG/AppUpdaterApp" "$APP/Contents/MacOS/AppUpdater"

# Sparkle.framework embed (binary xcframework artifact from the SwiftPM checkout).
# The binary links @rpath/Sparkle.framework/Versions/B/Sparkle and carries no
# usable rpath for a bundle layout, so the rpath must be added BEFORE signing.
SPARKLE_FW_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_FW_SRC" ]; then
    echo "error: Sparkle framework artifact missing at $SPARKLE_FW_SRC (run: swift package resolve)" >&2
    exit 1
fi
cp -R "$SPARKLE_FW_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/AppUpdater"

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

PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
$PB -c "Add :SUEnableAutomaticChecks bool false" "$APP/Contents/Info.plist"
FEED_URL="${APPUPDATER_FEED_URL:-https://releases.appupdater.invalid/appupdater-appcast.xml}"
$PB -c "Add :SUFeedURL string $FEED_URL" "$APP/Contents/Info.plist"
# PUBLIC EdDSA key (safe to commit — the private half lives ONLY in the owner's
# login keychain, created by Sparkle's generate_keys; never in the repo).
PUBLIC_ED_KEY="${APPUPDATER_PUBLIC_ED_KEY:-MHC1fFI4O3w/kNBDff8VIxJaJ/vkpyUrKiNvr73n2nw=}"
$PB -c "Add :SUPublicEDKey string $PUBLIC_ED_KEY" "$APP/Contents/Info.plist"

# Sign nested code first, then the outer bundle (Sparkle validates its own
# helpers' signatures at runtime). Ad-hoc personal-use signing for now —
# Developer ID + notarization is the documented future slot (no distribution
# claims until the owner enrolls: AGENTS.md LOCKED decision 9).
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Assembled: $APP"
