#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Chunky"
BUILD_DIR="$SCRIPT_DIR/Chunky"
OUTPUT_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

cd "$BUILD_DIR"
swift build -c release

echo "Creating app bundle..."

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp .build/release/Chunky "$APP_BUNDLE/Contents/MacOS/"
cp Resources/Info.plist "$APP_BUNDLE/Contents/"
cp Resources/chunker.py "$APP_BUNDLE/Contents/Resources/"
cp Resources/Credits.html "$APP_BUNDLE/Contents/Resources/"

cat > "$APP_BUNDLE/Contents/PkgInfo" << EOF
APPL????
EOF

echo "App bundle created at: $APP_BUNDLE"
echo ""
echo "To run the app:"
echo "  open $APP_BUNDLE"
echo ""
echo "To install to Applications:"
echo "  cp -r $APP_BUNDLE /Applications/"
