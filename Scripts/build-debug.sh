#!/bin/bash
# Debug build helper: clean build + open ClashHalo.app.
# Note: intentionally does NOT bump CURRENT_PROJECT_VERSION. Build-number
# drift is reserved for release packaging (make.sh); ordinary verification
# must not dirty project.pbxproj (see AGENTS.md 构建与验证).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

osascript -e 'tell application "ClashHalo" to quit' >/dev/null 2>&1 || true

xcodebuild \
    -project "$ROOT/ClashHalo.xcodeproj" \
    -scheme ClashHalo \
    -configuration Debug \
    -derivedDataPath "$ROOT/.build" \
    clean build

APP="$ROOT/.build/Build/Products/Debug/ClashHalo.app"
[ -d "$APP" ] || { echo "Debug app not found: $APP" >&2; exit 1; }

plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist"
open "$APP"
