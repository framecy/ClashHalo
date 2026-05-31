#!/bin/bash
# make.sh — build a self-contained, distributable ClashPow.app (+ DMG).
#
#   1. builds the Go engine (embeds mihomo) for arm64
#   2. builds the SwiftUI GUI via xcodebuild
#   3. bundles the engine + geodata into ClashPow.app/Contents/Resources
#      (the app installs them on first run via EngineControl.ensureInstalled)
#   4. ad-hoc signs and (optionally) builds a DMG
#
# Real distribution additionally needs a Developer ID + notarization + Sparkle
# appcast — those require the user's signing identity and are noted below.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
mkdir -p "$BUILD"

echo "[1/4] Building engine (Go + mihomo, arm64)…"
( cd "$ROOT/Engine" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
    go build -ldflags="-s -w" -o "$BUILD/clashpow-engine" ./cmd/clashpow )
echo "      $(du -h "$BUILD/clashpow-engine" | cut -f1) engine"

echo "[2/4] Building GUI (xcodebuild Release, sign later)…"
xcodebuild -project "$ROOT/ClashPow.xcodeproj" -scheme ClashPow \
    -configuration Release -derivedDataPath "$BUILD/dd" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO build >/dev/null
APP="$BUILD/dd/Build/Products/Release/ClashPow.app"
[ -d "$APP" ] || { echo "GUI build not found"; exit 1; }

echo "[3/4] Bundling engine + geodata into .app…"
RES="$APP/Contents/Resources"
cp "$BUILD/clashpow-engine" "$RES/clashpow-engine"
chmod 755 "$RES/clashpow-engine"
# bundle geodata if available locally (first-run install copies them out)
for f in GeoSite.dat geoip.metadb ASN.mmdb; do
    for src in "$HOME/.config/mihomo/$f" "$HOME/Library/Application Support/ClashPow/$f"; do
        [ -f "$src" ] && cp "$src" "$RES/$f" && break
    done
done

echo "[4/4] Ad-hoc signing + DMG…"
xattr -cr "$APP"                       # strip resource-fork/Finder detritus
codesign --force --deep --options runtime --sign - "$APP"
DMG="$BUILD/ClashPow.dmg"
rm -f "$DMG"
hdiutil create -volname ClashPow -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
echo ""
echo "=== Done ==="
echo "App: $APP"
echo "DMG: $DMG  ($(du -h "$DMG" | cut -f1))"
echo ""
echo "NOTE: For public distribution you still need:"
echo "  • Developer ID signing:  codesign --sign \"Developer ID Application: …\" --options runtime"
echo "  • Notarization:          xcrun notarytool submit \"$DMG\" --apple-id … --team-id … --wait"
echo "  • Sparkle auto-update:   add Sparkle SPM + appcast URL + EdDSA signing"
