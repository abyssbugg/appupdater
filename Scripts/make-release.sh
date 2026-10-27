#!/bin/bash
# make-release.sh — the full per-release pipeline from docs/RELEASE-PLUMBING.md
# (§1b signature chain + §2 checklist), with the honesty guards that keep the
# feed truthful.
#
# Usage:
#   Scripts/make-release.sh <version> <build> <notes-file> [--check]
#     --check : run ONLY the guards + gate, print the plan, touch nothing.
#
# Guards (refuse rather than release something dishonest):
#   - <build> must be STRICTLY greater than the feed's current sparkle:version
#     (Sparkle compares CFBundleVersion; short-version-only bumps offer nothing).
#   - tag v<version> must not already exist.
#   - working tree must have no uncommitted tracked changes.
#
# Pipeline: gate (build/test/lint) → make-app → codesign → zip → sign_update
# → verify → gh release create → asset verify → appcast splice → commit+push.
# APPUPDATER_SKIP_GATE=1 skips step 1 for re-runs (prints a loud warning).
set -euo pipefail

VERSION="${1:-}"
BUILD="${2:-}"
NOTES="${3:-}"
CHECK=0
[ "${4:-}" = "--check" ] && CHECK=1

die() { echo "REFUSED: $*" >&2; exit 2; }
[ -n "$VERSION" ] || die "usage: make-release.sh <version> <build> <notes-file> [--check]"
[ -n "$BUILD" ] || die "usage: make-release.sh <version> <build> <notes-file> [--check]"
case "$BUILD" in (*[!0-9]*|'') die "build must be a positive integer, got '$BUILD'";; esac
[ -n "$NOTES" ] || die "a release notes file is required (honest releases ship notes)"
[ -f "$NOTES" ] || die "notes file not found: $NOTES"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
[ -f appcast.xml ] || die "appcast.xml missing at repo root — the feed is the source of truth for the guard"

# --- Guards -----------------------------------------------------------------
LAST_BUILD="$(sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<\/sparkle:version>.*/\1/p' appcast.xml | head -1)"
[ -n "$LAST_BUILD" ] || die "could not read sparkle:version from appcast.xml"
[ "$BUILD" -gt "$LAST_BUILD" ] || die "build $BUILD must be > current feed sparkle:version $LAST_BUILD (Sparkle compares CFBundleVersion — short-version-only bumps offer no update)"
if git ls-remote --tags origin "refs/tags/v$VERSION" | grep -q "refs/tags/v$VERSION"; then
    die "tag v$VERSION already exists on origin (local clones may lag remote tags — checked remotely)"
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    die "uncommitted tracked changes present — commit or stash first (releases are cut from a clean tree)"
fi
PLAN="release v$VERSION (short $VERSION, build $BUILD) — feed advances sparkle:version $LAST_BUILD → $BUILD"

# --- Gate (§2 items 1–2) ------------------------------------------------------
if [ "${APPUPDATER_SKIP_GATE:-0}" = "1" ]; then
    echo "WARNING: APPUPDATER_SKIP_GATE=1 — the §2 gate is NOT re-proven by this run"
else
    echo "== gate: build =="
    swift build > /tmp/mkrel_build.log 2>&1 || { grep "error:" /tmp/mkrel_build.log | head -5; die "swift build failed"; }
    echo "== gate: test (nonzero count required) =="
    swift test > /tmp/mkrel_test.log 2>&1 || { grep -E "✘" /tmp/mkrel_test.log | head -5; die "swift test failed"; }
    grep -qE "Test run with [1-9][0-9]* tests" /tmp/mkrel_test.log || die "test count line missing or zero (XCTest discovery trap)"
    grep "Test run with" /tmp/mkrel_test.log
    echo "== gate: lint (error column must be empty) =="
    if swiftlint lint --quiet | grep -q ": error: "; then
        swiftlint lint --quiet | grep ": error: " | head -5
        die "swiftlint error-severity hits present"
    fi
    echo "lint: 0 errors"
fi

# --- Build + verify bundle (§2 item 4) ---------------------------------------
if [ "$CHECK" = "1" ]; then
    echo "CHECK-ONLY — would proceed with: $PLAN"
    exit 0
fi
echo "== build bundle ($VERSION / build $BUILD) =="
APPUPDATER_VERSION="$VERSION" APPUPDATER_BUILD="$BUILD" Scripts/make-app.sh release > /tmp/mkrel_make.log 2>&1 || { tail -3 /tmp/mkrel_make.log; die "make-app failed"; }
codesign -v --strict build/AppUpdater.app || die "bundle signature invalid"

# --- Zip + sign (§1b steps 2–4) -----------------------------------------------
ZIP="build/AppUpdater-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/AppUpdater.app "$ZIP"
ZIP_BYTES="$(stat -f %z "$ZIP")"
SIG="$(.build/artifacts/sparkle/Sparkle/bin/sign_update -p "$ZIP")"
.build/artifacts/sparkle/Sparkle/bin/sign_update --verify "$ZIP" "$SIG" || die "signature failed verification"

# --- Release (asset must exist before the appcast references it) ---------------
echo "== gh release create v$VERSION =="
gh release create "v$VERSION" "$ZIP" --title "AppUpdater $VERSION" --notes-file "$NOTES" > /dev/null
ASSET_URL="https://github.com/abyssbugg/appupdater/releases/download/v$VERSION/AppUpdater-$VERSION.zip"
gh release view "v$VERSION" --json assets --jq ".assets[] | select(.name == \"AppUpdater-$VERSION.zip\") | .size" | grep -qx "$ZIP_BYTES" \
    || die "uploaded asset size mismatch — refusing to publish a feed that points at wrong bytes"

# --- Appcast splice (newest item on top) + commit -------------------------------
PUBDATE="$(date -R)"
python3 - "$VERSION" "$BUILD" "$ZIP_BYTES" "$SIG" "$ASSET_URL" "$PUBDATE" <<'PYEOF'
import sys, re
version, build, size, sig, url, pubdate = sys.argv[1:7]
xml = open("appcast.xml").read()
item = f"""        <item>
            <title>Version {version}</title>
            <pubDate>{pubdate}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure url="{url}" length="{size}" type="application/octet-stream" sparkle:edSignature="{sig}"/>
        </item>
"""
new, n = re.subn(r"(    <channel>\n)", r"\1" + item, xml, count=1)
assert n == 1, "channel open tag not found"
open("appcast.xml", "w").write(new)
PYEOF
xmllint --noout appcast.xml || die "spliced appcast is not well-formed XML"
git add appcast.xml
git -c user.name="datamatics" -c user.email="datamatics@local" commit -q -m "release v$VERSION: appcast item (build $BUILD, EdDSA-verified)"
git push -q origin main
echo "RELEASED: v$VERSION — feed item committed and pushed (CircleCI gates the feed commit)"
echo "  asset: $ASSET_URL"
echo "  feed : https://raw.githubusercontent.com/abyssbugg/appupdater/main/appcast.xml"
