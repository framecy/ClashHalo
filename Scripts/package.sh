#!/bin/bash
# package.sh
# Creates a signed and notarized DMG installer for distribution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
DMG_NAME="ClashHalo.dmg"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Your Name (TEAMID)}"

echo "=== ClashHalo Package ==="

# Step 1: Build everything (if not already built)
if [ ! -d "$BUILD_DIR/ClashHalo.app" ]; then
    echo "[1/4] Running build..."
    "$SCRIPT_DIR/build.sh"
else
    echo "[1/4] Using existing build..."
fi

# Step 2: Code sign
echo "[2/4] Code signing..."
codesign --deep --force --verify --verbose \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    "$BUILD_DIR/ClashHalo.app"

# Verify signature
codesign --verify --deep --strict "$BUILD_DIR/ClashHalo.app"
echo "  Signing complete"

# Step 3: Create DMG
echo "[3/4] Creating DMG..."
rm -f "$BUILD_DIR/$DMG_NAME"
hdiutil create \
    -volname "ClashHalo" \
    -srcfolder "$BUILD_DIR/ClashHalo.app" \
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
    echo "  Notarization submitted"
else
    echo "[4/4] Skipping notarization (set NOTARIZE=true to notarize)"
fi

echo "=== Package complete ==="
