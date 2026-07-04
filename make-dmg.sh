#!/bin/bash
# ClashHalo DMG 打包脚本

set -e

VERSION="1.1.1"
APP_NAME="ClashHalo"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
TEMP_DMG="${DMG_NAME}.temp.dmg"
SOURCE_DIR=".dmg-temp"
VOLUME_NAME="ClashHalo ${VERSION}"

echo "🚀 开始打包 ${APP_NAME} v${VERSION}..."

# 检查源目录
if [ ! -d "$SOURCE_DIR" ]; then
    echo "❌ 错误: 找不到源目录 $SOURCE_DIR"
    exit 1
fi

# 删除旧的 DMG
if [ -f "/Users/chace/Desktop/$DMG_NAME" ]; then
    echo "🗑️  删除旧的 DMG..."
    rm "/Users/chace/Desktop/$DMG_NAME"
fi

# 创建临时 DMG
echo "📦 创建 DMG..."
hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$SOURCE_DIR" \
    -ov -format UDRW \
    "$TEMP_DMG"

# 挂载临时 DMG
echo "📂 挂载 DMG..."
MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | grep Volumes | sed 's/.*\/Volumes\//\/Volumes\//')

# 等待挂载完成
sleep 2

# 设置窗口属性
echo "🎨 设置 Finder 窗口属性..."
osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 200, 1000, 550}

        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 12

        -- 设置图标位置
        set position of item "ClashHalo.app" of container window to {150, 180}
        set position of item "Applications" of container window to {450, 180}
        set position of item "使用说明.txt" of container window to {300, 320}

        update without registering applications
        delay 2
    end tell
end tell
EOF

# 卸载临时 DMG
echo "💾 卸载临时 DMG..."
sync
hdiutil detach "$MOUNT_DIR" -force || true
sleep 2

# 转换为压缩的只读 DMG
echo "🗜️  压缩 DMG..."
hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -o "/Users/chace/Desktop/$DMG_NAME"

# 删除临时文件
rm "$TEMP_DMG"

# 显示结果
DMG_SIZE=$(du -h "/Users/chace/Desktop/$DMG_NAME" | cut -f1)
echo "✅ 完成！"
echo "📍 位置: /Users/chace/Desktop/$DMG_NAME"
echo "📊 大小: $DMG_SIZE"
