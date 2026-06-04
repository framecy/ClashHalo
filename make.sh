#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
mkdir -p "$BUILD"

echo "[1/4] Building Helper Tool…"
# Note: Embed Info.plist into the binary for proper identification
swiftc \
    "$ROOT/Sources/Helper/main.swift" "$ROOT/Sources/XPC/ProxyManager.swift" "$ROOT/Sources/XPC/HelperProtocol.swift" \
    -o "$BUILD/com.clashpow.helper" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/Helper-Info.plist"
echo "      Helper compiled and Info.plist embedded."

echo "[2/4] Building GUI (xcodebuild Release, sign later)…"
xcodebuild -project "$ROOT/ClashPow.xcodeproj" -scheme ClashPow \
    -configuration Release -derivedDataPath "$BUILD/dd" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO build >/dev/null
APP="$BUILD/dd/Build/Products/Release/ClashPow.app"
[ -d "$APP" ] || { echo "GUI build not found"; exit 1; }

echo "[3/4] Bundling Helper Tool + Geodata…"
RES="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS"

# Clean manually-bundled artifacts from any previous incremental build so stale
# files (a removed plist, a 0-byte geodata) never linger in the shipped bundle.
rm -rf "$APP/Contents/Library/LaunchDaemons"
rm -f "$RES/GeoSite.dat" "$RES/geoip.metadb" "$RES/ASN.mmdb"

cp "$BUILD/com.clashpow.helper" "$APP/Contents/MacOS/com.clashpow.helper"
# B7: the LaunchDaemon plist is generated at install time by XPCManager.installDaemon
# (single source of truth). Bundling a separate plist here was dead/misleading config.

chmod 755 "$APP/Contents/MacOS/com.clashpow.helper"

# bundle geodata if available locally (B8: -s skips 0-byte/corrupt files so the
# kernel falls back to its geox-url download instead of loading an empty .dat)
for f in GeoSite.dat geoip.metadb ASN.mmdb; do
    for src in "$HOME/.config/mihomo/$f" "$HOME/Library/Application Support/ClashPow/$f"; do
        [ -s "$src" ] && cp "$src" "$RES/$f" && break
    done
done

echo "[4/4] Ad-hoc signing + DMG…"
xattr -cr "$APP"
# Sign helper tool first
codesign --force --sign - "$APP/Contents/MacOS/com.clashpow.helper"
# Sign mihomo if present
if [ -f "$APP/Contents/MacOS/mihomo" ]; then
    codesign --force --sign - "$APP/Contents/MacOS/mihomo"
fi
# Sign the whole app deeply
codesign --force --deep --options runtime --sign - "$APP"
DMG="$BUILD/ClashPow.dmg"
rm -f "$DMG"
hdiutil create -volname ClashPow -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
echo ""
echo "=== Done ==="
echo "App: $APP"
echo "DMG: $DMG  ($(du -h "$DMG" | cut -f1))"
echo ""
echo "NOTE: Official 'mihomo' binary must be placed at $APP/Contents/MacOS/mihomo before final distribution."
