#!/bin/bash
# Debug build helper: clean build + open ClashHalo.app.
# Note: intentionally does NOT bump CURRENT_PROJECT_VERSION. Build-number
# drift is reserved for release packaging (make.sh); ordinary verification
# must not dirty project.pbxproj (see AGENTS.md 构建与验证).
#
# Also builds & embeds the privileged Helper so Debug runs can exercise the
# same install/upgrade path as Release (without it, the installed LaunchDaemon
# stays on an old binary and fixes in Sources/XPC/ProxyManager.swift never land).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
BUILD="$ROOT/.build"
APP="$BUILD/Build/Products/Debug/ClashHalo.app"

osascript -e 'tell application "ClashHalo" to quit' >/dev/null 2>&1 || true

echo "[debug] Building Helper…"
mkdir -p "$BUILD"
# -target pins the Helper's minimum OS to the product deployment target
# (macOS 14.0); without it swiftc defaults to the build machine's OS and the
# Helper won't load on macOS 14–26. -O matches make.sh's Release Helper.
# -DDEBUG（2026-11-17 审查 P1-1 配套）：Helper 允许根里「Xcode 产物目录」分支
# 由 #if DEBUG 门控。GUI 走 Debug 配置时 Xcode 自动定义 DEBUG，而这里的手工
# swiftc 不会——缺了它，Debug 构建的 Helper 装机后会把 .build 产物路径的
# 真客户端拒之门外（实机事故：build-debug.sh 自动打开的 App 被已装 Helper
# REJECTED「路径未锚定」，特权功能全灭）。make.sh 的 Release Helper 不传此
# 旗标，收紧后的 Release 允许根不受影响。
swiftc \
    "$ROOT/Sources/Helper/main.swift" \
    "$ROOT/Sources/XPC/ProxyManager.swift" \
    "$ROOT/Sources/XPC/HelperProtocol.swift" \
    -target arm64-apple-macosx14.0 -O -DDEBUG \
    -o "$BUILD/com.clashhalo.helper" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/Helper-Info.plist"
codesign --force --sign - "$BUILD/com.clashhalo.helper" >/dev/null
echo "      Helper ready: $BUILD/com.clashhalo.helper"

echo "[debug] Building GUI (Debug)…"
xcodebuild \
    -project "$ROOT/ClashHalo.xcodeproj" \
    -scheme ClashHalo \
    -configuration Debug \
    -derivedDataPath "$BUILD" \
    clean build

[ -d "$APP" ] || { echo "Debug app not found: $APP" >&2; exit 1; }

echo "[debug] Embedding Helper into app…"
cp "$BUILD/com.clashhalo.helper" "$APP/Contents/MacOS/com.clashhalo.helper"
chmod 755 "$APP/Contents/MacOS/com.clashhalo.helper"
codesign --force --sign - "$APP/Contents/MacOS/com.clashhalo.helper" >/dev/null
codesign --force --sign - --entitlements "$ROOT/ClashHalo.entitlements" "$APP" >/dev/null 2>&1 || \
    codesign --force --sign - "$APP" >/dev/null

plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist"
echo -n "bundled helper: "
# Prefer embedded version string if present
strings "$APP/Contents/MacOS/com.clashhalo.helper" | rg -m1 '^[0-9]+\.[0-9]+\.[0-9]+$' || true
open "$APP"
