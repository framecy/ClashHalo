#!/bin/bash
# install.sh
# Installs or updates the ClashPow engine launchd daemon.
# Must be run with sudo for production install.
#
# Usage:
#   sudo ./install.sh          # Install for production (launchd)
#   ./install.sh --dev          # Install for development (user launchd)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
ENGINE_BIN="$BUILD_DIR/engine/clashpow-engine"
PLIST_SRC="$PROJECT_DIR/Config/com.clashpow.engine.plist"
PLIST_NAME="com.clashpow.engine.plist"

MODE="${1:-}"

# ── Determine install paths based on mode ────────────────────────

if [ "$MODE" = "--dev" ]; then
    # User-level launchd (no sudo needed)
    LAUNCHD_DIR="$HOME/Library/LaunchAgents"
    ENGINE_INSTALL="$HOME/Library/Application Support/ClashPow/clashpow-engine"
    LOG_DIR="$HOME/Library/Logs/ClashPow"
    KEEP_ALIVE="false"
else
    # System-level launchd (requires sudo)
    LAUNCHD_DIR="/Library/LaunchDaemons"
    ENGINE_INSTALL="/usr/local/bin/clashpow-engine"
    LOG_DIR="/usr/local/var/log"
    KEEP_ALIVE="true"
fi

echo "=== ClashPow Engine Installer ==="
echo "Mode: ${MODE#--} "
echo "Launchd dir: $LAUNCHD_DIR"
echo "Engine path: $ENGINE_INSTALL"
echo ""

# ── Build engine if not already built ────────────────────────────

if [ ! -f "$ENGINE_BIN" ]; then
    echo "[1/4] Building engine..."
    cd "$PROJECT_DIR/Engine"
    CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build \
        -ldflags="-s -w" \
        -o "$ENGINE_BIN" \
        ./cmd/clashpow
else
    echo "[1/4] Using existing engine binary: $ENGINE_BIN"
fi

# ── Install engine binary ────────────────────────────────────────

echo "[2/4] Installing engine binary..."
mkdir -p "$(dirname "$ENGINE_INSTALL")"
cp "$ENGINE_BIN" "$ENGINE_INSTALL"
chmod 755 "$ENGINE_INSTALL"
echo "  → $ENGINE_INSTALL"

# ── Create log directory ─────────────────────────────────────────

echo "[3/4] Creating log directory..."
mkdir -p "$LOG_DIR"
# Set permissions so engine can write logs
if [ "$MODE" = "--dev" ]; then
    chmod 755 "$LOG_DIR"
else
    chown root:wheel "$LOG_DIR" 2>/dev/null || true
    chmod 755 "$LOG_DIR"
fi
echo "  → $LOG_DIR"

# ── Install and load launchd plist ────────────────────────────────

echo "[4/4] Installing launchd plist..."
mkdir -p "$LAUNCHD_DIR"

# Generate plist with correct paths
PLIST_TARGET="$LAUNCHD_DIR/$PLIST_NAME"

# Write a fresh plist with the correct paths instead of mutating the template
cat > "$PLIST_TARGET" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clashpow.engine</string>

    <key>ProgramArguments</key>
    <array>
        <string>$ENGINE_INSTALL</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <$KEEP_ALIVE/>

    <key>ProcessType</key>
    <string>Background</string>

    <key>LowPriorityIO</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>3</integer>

    <key>EnvironmentVariables</key>
    <dict>
        <key>GOMAXPROCS</key>
        <string>4</string>
        <key>GOGC</key>
        <string>50</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$LOG_DIR/clashpow-engine.log</string>

    <key>StandardErrorPath</key>
    <string>$LOG_DIR/clashpow-engine.log</string>
</dict>
</plist>
PLISTEOF

echo "  → $PLIST_TARGET"

# ── Load the service ─────────────────────────────────────────────

if [ "$MODE" = "--dev" ]; then
    # Unload existing instance
    launchctl unload "$PLIST_TARGET" 2>/dev/null || true
    # Load new instance
    launchctl load "$PLIST_TARGET"
    echo ""
    echo "=== Installed (dev mode) ==="
    echo "Engine running as user LaunchAgent"
    echo ""
    echo "Useful commands:"
    echo "  launchctl list | grep clashpow"
    echo "  tail -f \"$LOG_DIR/clashpow-engine.log\""
    echo "  launchctl unload \"$PLIST_TARGET\"  # stop"
    echo "  launchctl load \"$PLIST_TARGET\"    # start"
else
    # Unload existing instance
    sudo launchctl unload "$PLIST_TARGET" 2>/dev/null || true
    # Load new instance
    sudo launchctl load "$PLIST_TARGET"
    echo ""
    echo "=== Installed (production) ==="
    echo "Engine running as system LaunchDaemon"
    echo ""
    echo "Useful commands:"
    echo "  sudo launchctl list | grep clashpow"
    echo "  tail -f \"$LOG_DIR/clashpow-engine.log\""
    echo "  sudo launchctl unload \"$PLIST_TARGET\"  # stop"
    echo "  sudo launchctl load \"$PLIST_TARGET\"    # start"
fi
