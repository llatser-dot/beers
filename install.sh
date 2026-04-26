#!/bin/bash
set -euo pipefail

PROJECT_DIR="$HOME/Projects/llatser-listen"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Llatser Listen"
APP_DEST="/Applications/$APP_NAME.app"
LOG_FILE="/tmp/llatser-listen.log"
SIGN_IDENTITY="${LLATSER_LISTEN_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="Llatser Listen Local Code Signing"
fi
ALLOW_ADHOC="${LLATSER_ALLOW_ADHOC:-0}"
SIGNING_MODE="stable identity"

echo "=== Llatser Listen Build & Install ==="

echo "[1/6] Generating project..."
cd "$PROJECT_DIR"
xcodegen generate

echo "[2/6] Stopping running app..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

echo "[3/6] Building Release..."
xcodebuild \
    -project "$PROJECT_DIR/LlatserListen.xcodeproj" \
    -scheme "LlatserListen" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    clean build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

echo "[4/6] Installing to /Applications..."
rm -rf "$APP_DEST"
ditto "$BUILD_DIR/Build/Products/Release/$APP_NAME.app" "$APP_DEST"

echo "[5/6] Signing app..."
if security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
    codesign --force --deep --timestamp=none --sign "$SIGN_IDENTITY" "$APP_DEST"
elif [ "$ALLOW_ADHOC" = "1" ]; then
    echo "No matching signing identity found; using ad-hoc signature."
    SIGNING_MODE="ad-hoc fallback"
    codesign --force --deep --sign - "$APP_DEST"
else
    echo "Missing signing identity: $SIGN_IDENTITY"
    echo "Run: $PROJECT_DIR/scripts/create-local-signing-identity.sh"
    echo "Or set LLATSER_ALLOW_ADHOC=1 for a temporary build that may break macOS permissions."
    exit 1
fi

codesign --verify --deep --strict "$APP_DEST"

echo "[6/6] Resetting app log..."
> "$LOG_FILE"

if [ "${LLATSER_RESET_TCC:-0}" = "1" ]; then
    echo "Resetting stale macOS privacy rows..."
    tccutil reset ListenEvent com.llatser.listen >/dev/null 2>&1 || true
    tccutil reset Accessibility com.llatser.listen >/dev/null 2>&1 || true
    tccutil reset Microphone com.llatser.listen >/dev/null 2>&1 || true
fi

# Xcode registers the built product with Launch Services during local builds.
# Remove that copy so Finder/Launchpad only show the installed application.
if [ -d "$BUILD_DIR/Build/Products/Release/$APP_NAME.app" ]; then
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
        -u "$BUILD_DIR/Build/Products/Release/$APP_NAME.app" 2>/dev/null || true
    rm -rf "$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
fi
rm -rf "$BUILD_DIR/Build/Products/Release/$APP_NAME.app.dSYM"

if [ -d "$BUILD_DIR/Build/Products/Debug/$APP_NAME.app" ]; then
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
        -u "$BUILD_DIR/Build/Products/Debug/$APP_NAME.app" 2>/dev/null || true
    rm -rf "$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"
fi
rm -rf "$BUILD_DIR/Build/Products/Debug/$APP_NAME.app.dSYM"

/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
    -f -R -trusted "$APP_DEST" 2>/dev/null || true

echo ""
echo "=== Done ==="
echo "Installed: $APP_DEST"
echo "Log: $LOG_FILE"
echo "Hotkey: Right Option"
echo "Engine default: Parakeet v3"
if [ "$SIGNING_MODE" != "stable identity" ]; then
    echo "Signing: ad-hoc, so macOS may ask for permissions after reinstall."
else
    echo "Signing: $SIGN_IDENTITY"
fi
