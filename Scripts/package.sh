#!/bin/bash
# package.sh
# Creates a signed (and optionally notarized) DMG for distribution with a
# Developer ID certificate. Local ad-hoc packaging stays in make.sh.
# NOTE: does NOT bump CURRENT_PROJECT_VERSION (that is make.sh's job).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Your Name (TEAMID)}"

# DMG 名带版本号，与 make.sh 命名一致；版本唯一来源是 pbxproj。
VERSION=$(grep -oE 'MARKETING_VERSION = [0-9.]+' "$PROJECT_DIR/ClashHalo.xcodeproj/project.pbxproj" | head -1 | awk '{print $3}')
BUILD_NUM=$(grep -oE 'CURRENT_PROJECT_VERSION = [0-9]+' "$PROJECT_DIR/ClashHalo.xcodeproj/project.pbxproj" | head -1 | awk '{print $3}')
DMG_NAME="ClashHalo_v${VERSION}_build_${BUILD_NUM}_mac.dmg"
APP="$BUILD_DIR/dd/Build/Products/Release/ClashHalo.app"

echo "=== ClashHalo Package ==="

# Step 1: Release build. (The old "$SCRIPT_DIR/build.sh" call was a dead link —
# that script never existed. Build directly with xcodebuild, same layout as
# make.sh. Plain xcodebuild does NOT embed the Helper, so compile + embed it
# below; a distribution app without the Helper cannot install TUN.)
if [ ! -d "$APP" ]; then
    echo "[1/4] Building (xcodebuild Release)..."
    mkdir -p "$BUILD_DIR"
    if ! xcodebuild -project "$PROJECT_DIR/ClashHalo.xcodeproj" -scheme ClashHalo \
        -configuration Release -derivedDataPath "$BUILD_DIR/dd" \
        -destination 'platform=macOS,arch=arm64' \
        CODE_SIGNING_ALLOWED=NO build > "$BUILD_DIR/package-build.log" 2>&1; then
        echo "❌ xcodebuild failed — last 40 lines of $BUILD_DIR/package-build.log:"
        tail -40 "$BUILD_DIR/package-build.log"
        exit 1
    fi
else
    echo "[1/4] Using existing build..."
fi
[ -d "$APP" ] || { echo "❌ Release app not found: $APP"; exit 1; }

echo "      Building + embedding Helper (macOS 14.0 target)..."
swiftc \
    "$PROJECT_DIR/Sources/Helper/main.swift" "$PROJECT_DIR/Sources/XPC/ProxyManager.swift" "$PROJECT_DIR/Sources/XPC/HelperProtocol.swift" \
    -target arm64-apple-macosx14.0 -O \
    -o "$APP/Contents/MacOS/com.clashhalo.helper" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PROJECT_DIR/Helper-Info.plist"
chmod 755 "$APP/Contents/MacOS/com.clashhalo.helper"

# Step 2: Code sign.
# mihomo MUST NOT get hardened runtime (--options runtime): it blocks the
# AF_SYSTEM sockets (utun creation) mihomo needs for TUN even as root.
# Sign nested binaries first, then the bundle WITHOUT --deep — --deep would
# re-sign mihomo with runtime and break TUN (see make.sh signing comments).
echo "[2/4] Code signing..."
codesign --force --verify --verbose \
    --sign "$SIGNING_IDENTITY" \
    "$APP/Contents/MacOS/com.clashhalo.helper"
if [ -f "$APP/Contents/MacOS/mihomo" ]; then
    codesign --force --verify --verbose \
        --sign "$SIGNING_IDENTITY" \
        "$APP/Contents/MacOS/mihomo"
fi
codesign --force --verify --verbose \
    --options runtime \
    --entitlements "$PROJECT_DIR/ClashHalo.entitlements" \
    --sign "$SIGNING_IDENTITY" \
    "$APP"

# Verify signature
codesign --verify --deep --strict "$APP"
echo "  Signing complete"

# Step 3: Create DMG
echo "[3/4] Creating DMG..."
rm -f "$BUILD_DIR/$DMG_NAME"
hdiutil create \
    -volname "ClashHalo v${VERSION}" \
    -srcfolder "$APP" \
    -ov -format UDZO \
    "$BUILD_DIR/$DMG_NAME"
echo "  DMG created at $BUILD_DIR/$DMG_NAME"

# Step 4: Notarize (if NOTARIZE=true)
if [ "${NOTARIZE:-false}" = "true" ]; then
    echo "[4/4] Notarizing..."
    xcrun notarytool submit "$BUILD_DIR/$DMG_NAME" \
        --apple-id "$APPLE_ID" \
        --team-id "${TEAM_ID:-}" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
    # Staple the ticket so Gatekeeper validates offline (notarization alone
    # leaves the DMG dependent on an online check at first open).
    xcrun stapler staple "$BUILD_DIR/$DMG_NAME"
    echo "  Notarized and stapled"
else
    echo "[4/4] Skipping notarization (set NOTARIZE=true to notarize)"
fi

echo "=== Package complete ==="
