#!/bin/bash
# setup.sh — Initialize ClashPow development environment
#
# This script:
#   1. Resolves all Go dependencies (downloads mihomo + 100+ transitive deps)
#   2. Builds the engine binary
#   3. Installs the launchd daemon (dev mode)
#   4. Verifies the engine RPC endpoint is responsive
#
# Usage: bash setup.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

echo "=== ClashPow Setup ==="
echo "Project dir: $PROJECT_DIR"
echo ""

# ── Step 1: Resolve Go dependencies ──────────────────────────────
echo "[1/4] Resolving Go dependencies (this downloads mihomo + all transitive deps)..."
cd "$PROJECT_DIR/Engine"
go mod tidy 2>&1 | tail -5
echo "  Done. Module ready."

# ── Step 2: Build engine ─────────────────────────────────────────
echo "[2/4] Building engine..."
cd "$PROJECT_DIR/Engine"
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build \
    -ldflags="-s -w" \
    -o /tmp/clashpow-engine \
    ./cmd/clashpow
echo "  Engine built: $(ls -lh /tmp/clashpow-engine | awk '{print $5}')"

# ── Step 3: Install launchd service ───────────────────────────────
echo "[3/4] Installing launchd daemon (dev mode)..."
bash "$PROJECT_DIR/Scripts/install.sh" --dev 2>&1 | tail -10

# ── Step 4: Verify engine is running ──────────────────────────────
echo "[4/4] Verifying engine RPC..."
sleep 0.5
if echo '{"jsonrpc":"2.0","method":"get_status","params":{},"id":1}' | nc -w 2 -U /tmp/clashpow-engine.sock 2>/dev/null | grep -q '"result"'; then
    echo "  ✓ Engine RPC responding"
else
    echo "  ✗ Engine RPC not responding — check logs:"
    echo "    tail -f ~/Library/Logs/ClashPow/clashpow-engine.log"
    exit 1
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Engine socket: /tmp/clashpow-engine.sock"
echo "Log socket:    /tmp/clashpow-log.sock"
echo "Engine logs:   ~/Library/Logs/ClashPow/clashpow-engine.log"
echo ""
echo "Open the Xcode project to build and run the GUI:"
echo "  open $PROJECT_DIR/ClashPow.xcodeproj"
