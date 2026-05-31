// build.sh
// Build script: compiles Go engine and Xcode project into a .app bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

echo "=== ClashPow Build ==="

# Step 1: Build Go engine
echo "[1/3] Building engine..."
mkdir -p "$BUILD_DIR/engine"
cd "$PROJECT_DIR/Engine"
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build \
    -ldflags="-s -w" \
    -o "$BUILD_DIR/engine/clashpow-engine" \
    ./cmd/clashpow
echo "  Engine built at $BUILD_DIR/engine/clashpow-engine"

# Step 2: Build Swift GUI
echo "[2/3] Building GUI..."
cd "$PROJECT_DIR"
xcodebuild \
    -project ClashPow.xcodeproj \
    -scheme ClashPow \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/xcode" \
    build
echo "  GUI built"

# Step 3: Bundle into .app
echo "[3/3] Bundling .app..."
APP_DIR="$BUILD_DIR/ClashPow.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy engine binary into app bundle
cp "$BUILD_DIR/engine/clashpow-engine" "$APP_DIR/Contents/MacOS/"

# Copy launchd plist
cp "$PROJECT_DIR/Config/com.clashpow.engine.plist" "$APP_DIR/Contents/Resources/"

echo "  App bundled at $APP_DIR"
echo "=== Build complete ==="
