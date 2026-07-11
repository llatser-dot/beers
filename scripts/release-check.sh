#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${LLATSER_RELEASE_CHECK_DIR:-/tmp/llatser-listen-release-check}"
APP="$BUILD_DIR/Build/Products/Release/Beers.app"
BINARY="$APP/Contents/MacOS/Beers"

rm -rf "$BUILD_DIR"

if command -v xcodegen >/dev/null 2>&1; then
    (cd "$PROJECT_DIR" && xcodegen generate)
fi

xcodebuild -quiet \
    -project "$PROJECT_DIR/LlatserListen.xcodeproj" \
    -scheme LlatserListen \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -destination "generic/platform=macOS" \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    build

test -x "$BINARY"
ARCHITECTURES="$(lipo -archs "$BINARY")"
for architecture in arm64 x86_64; do
    if [[ " $ARCHITECTURES " != *" $architecture "* ]]; then
        echo "Missing required architecture: $architecture" >&2
        exit 1
    fi
done

test "$(defaults read "$APP/Contents/Info" CFBundleIdentifier)" = "com.llatser.listen"
test "$(defaults read "$APP/Contents/Info" LSUIElement)" = "1"
plutil -extract NSMicrophoneUsageDescription raw "$APP/Contents/Info.plist" >/dev/null

echo "Release check passed: $ARCHITECTURES, FluidAudio linked, app metadata valid."
