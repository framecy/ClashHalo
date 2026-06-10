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

# Bundle a default mihomo kernel so the app works out of the box. Reuse a local
# kernel if present, otherwise download the official darwin-arm64 release.
MIHOMO_DST="$APP/Contents/MacOS/mihomo"
if [ ! -s "$MIHOMO_DST" ]; then
    for src in "$HOME/Library/Application Support/ClashPow/bin/mihomo" \
               "$HOME/Library/Application Support/ClashPow/kernels"/*/mihomo \
               "$HOME/.config/mihomo/mihomo"; do
        [ -s "$src" ] && cp "$src" "$MIHOMO_DST" && echo "      Reused local mihomo: $src" && break
    done
fi
if [ ! -s "$MIHOMO_DST" ]; then
    echo "      Downloading official mihomo (darwin-arm64)…"
    URL=$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
        | grep -oE '"browser_download_url"[^,]*darwin-arm64[^"]*\.gz"' \
        | grep -vE 'compatible|go1' | head -1 | sed -E 's/.*"(https[^"]+)".*/\1/' || true)
    if [ -n "${URL:-}" ]; then
        curl -fsSL "$URL" | gunzip > "$MIHOMO_DST" 2>/dev/null || true
    fi
fi
if [ -s "$MIHOMO_DST" ]; then chmod 755 "$MIHOMO_DST"; echo "      mihomo kernel bundled ✓"
else echo "      WARN: no mihomo bundled; app will download on first run."; fi

echo "[4/4] Ad-hoc signing + DMG…"
xattr -cr "$APP"
# Sign helper tool
codesign --force --sign - "$APP/Contents/MacOS/com.clashpow.helper"
# Sign mihomo WITHOUT --options runtime: hardened runtime blocks AF_SYSTEM sockets
# (utun device creation) that mihomo needs for TUN mode even when running as root.
# Pre-signing before the bundle step prevents --deep from overriding this.
if [ -f "$APP/Contents/MacOS/mihomo" ]; then
    codesign --force --sign - "$APP/Contents/MacOS/mihomo"
fi
# Sign the app bundle WITHOUT --deep (--deep would re-sign mihomo with runtime,
# breaking TUN). Pre-signed nested binaries are preserved in the bundle seal.
codesign --force --options runtime --sign - "$APP"
# Assemble DMG staging: the app + an /Applications shortcut + a usage guide,
# so users can drag-install and read how to bypass Gatekeeper (ad-hoc signed).
STAGE="$BUILD/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/ClashPow.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/使用说明.txt" <<'GUIDE'
ClashPow 使用说明
====================================

【关于签名（重要）】
本应用为本地构建版本，使用 ad-hoc 临时签名（无 Apple 开发者证书）。
首次打开时 macOS Gatekeeper 会提示“无法打开，因为无法验证开发者”——这是
未经签名的预期行为，按下方步骤即可正常使用。

【安装】
将左侧 ClashPow 拖入右侧「应用程序」(Applications) 文件夹。

【首次打开（绕过 Gatekeeper，任选其一）】
方法一（推荐）：在「应用程序」中右键点击 ClashPow → 选择「打开」→
            在弹窗中再次点击「打开」。仅首次需要。
方法二：若提示被拦截，打开「系统设置 → 隐私与安全性」，在底部找到
       被拦截提示，点击「仍要打开」。
方法三（终端，彻底清除隔离属性）：
       xattr -dr com.apple.quarantine /Applications/ClashPow.app

【内核】
本应用已内置官方 mihomo (Clash.Meta) 内核，开箱即用，无需额外配置。
如需更新或切换版本，在「网络 → 内核」下载并启用，
亦可随时切回内置内核。

【基本使用】
1. 打开应用后会自动启动内核并连接（控制端口绑定回环 127.0.0.1）。
2. 在「配置编辑 / 订阅」导入你的 YAML 配置或订阅链接。
3. 「系统代理」开关：一键设置 / 清除 macOS 系统代理。
4. 「TUN 模式」开关：首次开启会弹出管理员授权以安装特权服务(Helper)，
   随后内核以 root 重启并接管全局流量（创建 utun 虚拟网卡）。
5. 「实时日志」默认仅显示 WARN/ERROR；调试时可在页面切到 INFO/DEBUG。

【系统要求】
macOS 14.0+ ，Apple Silicon (arm64)。

【卸载】
 · 删除 /Applications/ClashPow.app
 · 删除数据目录 ~/Library/Application Support/ClashPow
 · 若安装过 TUN 特权服务，在终端执行：
   sudo launchctl bootout system /Library/LaunchDaemons/com.clashpow.helper.plist
   sudo rm -f /Library/LaunchDaemons/com.clashpow.helper.plist \
              /Library/PrivilegedHelperTools/com.clashpow.helper
GUIDE

VERSION=$(grep -oE 'MARKETING_VERSION = [0-9.]+' "$ROOT/ClashPow.xcodeproj/project.pbxproj" | head -1 | awk '{print $3}')
DMG_NAME="ClashPow_v${VERSION}_mac_arm"
DMG="$BUILD/${DMG_NAME}.dmg"
rm -f "$DMG"
hdiutil create -volname "ClashPow v${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
# Deliver a copy to the Desktop for convenience.
cp -f "$DMG" "$HOME/Desktop/${DMG_NAME}.dmg"
echo ""
echo "=== Done ==="
echo "App: $APP"
echo "DMG: $DMG  ($(du -h "$DMG" | cut -f1))"
if [ -s "$APP/Contents/MacOS/mihomo" ]; then
    echo "Kernel: bundled mihomo ✓ ($(du -h "$APP/Contents/MacOS/mihomo" | cut -f1))"
else
    echo "Kernel: NONE bundled — app will download on first run"
fi
