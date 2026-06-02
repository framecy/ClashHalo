#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
mkdir -p "$BUILD"

echo "[1/4] Building engine (CGO) & Helper Tool…"
( cd "$ROOT/Engine" && CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
    go build -buildmode=c-shared -o "$BUILD/libmihomo.dylib" ./cgo/main.go )
echo "      $(du -h "$BUILD/libmihomo.dylib" | cut -f1) libmihomo"

swiftc -import-objc-header "$ROOT/Engine/libmihomo.h" \
    -I "$ROOT/Engine" -L "$BUILD" -lmihomo \
    "$ROOT/Sources/Helper/main.swift" "$ROOT/Sources/XPC/ProxyManager.swift" "$ROOT/Sources/XPC/HelperProtocol.swift" \
    -o "$BUILD/dev.clashpow.helper"
echo "      Helper compiled natively."

echo "[2/4] Building GUI (xcodebuild Release, sign later)…"
xcodebuild -project "$ROOT/ClashPow.xcodeproj" -scheme ClashPow \
    -configuration Release -derivedDataPath "$BUILD/dd" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO build >/dev/null
APP="$BUILD/dd/Build/Products/Release/ClashPow.app"
[ -d "$APP" ] || { echo "GUI build not found"; exit 1; }

echo "[3/4] Bundling engine + geodata into .app…"
RES="$APP/Contents/Resources"
# Bundle CGO Engine into MacOS and Helper Tool
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp "$BUILD/libmihomo.dylib" "$APP/Contents/MacOS/libmihomo.dylib"
cp "$BUILD/dev.clashpow.helper" "$APP/Contents/MacOS/dev.clashpow.helper"
cp "$ROOT/dev.clashpow.helper.plist" "$APP/Contents/Library/LaunchDaemons/"

chmod 755 "$APP/Contents/MacOS/libmihomo.dylib"
chmod 755 "$APP/Contents/MacOS/dev.clashpow.helper"

# Use install_name_tool so Helper finds the dylib in the same directory
install_name_tool -change libmihomo.dylib @executable_path/libmihomo.dylib "$APP/Contents/MacOS/dev.clashpow.helper"

# bundle geodata if available locally
for f in GeoSite.dat geoip.metadb ASN.mmdb; do
    for src in "$HOME/.config/mihomo/$f" "$HOME/Library/Application Support/ClashPow/$f"; do
        [ -f "$src" ] && cp "$src" "$RES/$f" && break
    done
done

echo "[4/4] Ad-hoc signing + DMG…"
xattr -cr "$APP"                       # strip resource-fork/Finder detritus
codesign --force --sign - "$APP/Contents/MacOS/libmihomo.dylib"
codesign --force --sign - "$APP/Contents/MacOS/dev.clashpow.helper"
codesign --force --deep --options runtime --sign - "$APP"
DMG="$BUILD/ClashPow.dmg"
rm -f "$DMG"
hdiutil create -volname ClashPow -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
echo ""
echo "=== Done ==="
echo "App: $APP"
echo "DMG: $DMG  ($(du -h "$DMG" | cut -f1))"
