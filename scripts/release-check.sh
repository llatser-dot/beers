#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
BUILD_DIR="$(mktemp -d "${TMP_ROOT%/}/beers-release-check.XXXXXX")"
APP="$BUILD_DIR/Build/Products/Release/Beers.app"
BINARY="$APP/Contents/MacOS/Beers"

cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=normal)" ]]; then
    echo "Release check requires a clean Git worktree and index." >&2
    exit 1
fi

for command in xcodegen xcodebuild xcrun; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Missing required release-check command: $command" >&2
        exit 1
    fi
done

if ! git lfs version >/dev/null 2>&1; then
    echo "Missing required release-check command: git-lfs (install with 'brew install git-lfs')." >&2
    exit 1
fi

git -C "$PROJECT_DIR" lfs fsck

WEIGHT="$PROJECT_DIR/LlatserListen/Resources/Bouncer/Bouncer.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
if [[ ! -f "$WEIGHT" ]]; then
    echo "Missing Bouncer weights: $WEIGHT (run git lfs pull)." >&2
    exit 1
fi
if grep -aq '^version https://git-lfs.github.com/spec/v1' "$WEIGHT"; then
    echo "Bouncer weights are still a Git LFS pointer; run git lfs pull." >&2
    exit 1
fi

SMOKE_BINARY="$BUILD_DIR/endpoint-trust-smoke"
xcrun swiftc \
    "$PROJECT_DIR/LlatserListen/AIEndpointTrust.swift" \
    "$PROJECT_DIR/scripts/endpoint-trust-smoke.swift" \
    -o "$SMOKE_BINARY"
"$SMOKE_BINARY"

(cd "$PROJECT_DIR" && xcodegen generate)

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
test -d "$APP/Contents/Resources/Bouncer.mlmodelc"
test -s "$APP/Contents/Resources/threshold.json"
test -s "$APP/Contents/Resources/vocab.txt"

echo "Release check passed: clean Git, LFS complete, endpoint trust verified, $ARCHITECTURES, app metadata and Bouncer resources valid."
