#!/bin/bash
set -euo pipefail

NAME="Third Hand"
BUILD=".build/release"

echo "Building…"
swift build -c release 2>&1

echo "Bundling…"
APP="$BUILD/$NAME.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp "$BUILD/ThirdHand" "$APP/MacOS/ThirdHand"
cp Resources/Info.plist "$APP/Info.plist"

echo "Signing…"
codesign --force --deep --sign - "$BUILD/$NAME.app" 2>&1

echo ""
echo "✓  $BUILD/$NAME.app"
echo ""
echo "Run:  open \"$BUILD/$NAME.app\""
echo ""
echo "First launch:"
echo "  1. Grant Accessibility permission when prompted"
echo "  2. Enter your OpenRouter API key"
echo "  3. Press ⌥ Space in any app"
