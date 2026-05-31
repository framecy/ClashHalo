#!/bin/bash
# notarize.sh
# Submits a DMG or .app for notarization and staples the ticket.
set -euo pipefail

TARGET="${1:?Usage: notarize.sh <path-to-dmg-or-app>}"
TEAM_ID="${TEAM_ID:?TEAM_ID must be set}"
APPLE_ID="${APPLE_ID:?APPLE_ID must be set}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD must be set}"

echo "=== ClashPow Notarize ==="

echo "Submitting $TARGET for notarization..."
xcrun notarytool submit "$TARGET" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait

echo ""
echo "Stapling notarization ticket..."
xcrun stapler staple "$TARGET"

echo "=== Notarization complete ==="
xcrun stapler validate "$TARGET"
