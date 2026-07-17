#!/bin/bash
set -euo pipefail

APP_NAME="Beers"
BUNDLE_ID="com.llatser.listen"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build-airdrop"
SOURCE_APP="${LLATSER_LISTEN_APP_SOURCE:-}"
OUT_DIR="${LLATSER_AIRDROP_DIR:-$HOME/Desktop/$APP_NAME AirDrop}"
ZIP_PATH="${LLATSER_AIRDROP_ZIP:-$HOME/Desktop/$APP_NAME AirDrop.zip}"
SIGN_IDENTITY="${LLATSER_LISTEN_SIGN_IDENTITY:-}"
TEAM_ID="${LLATSER_LISTEN_TEAM_ID:-}"
SIGNING_NOTE="provided app"
ALLOW_LOCAL_SIGNING="${LLATSER_ALLOW_LOCAL_SIGNING:-0}"

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ { print $2; exit }')"
fi

echo "=== Beers AirDrop Package ==="

if [ -z "$SOURCE_APP" ]; then
    echo "[build] Creating release app..."
    cd "$PROJECT_DIR"
    if command -v xcodegen >/dev/null 2>&1 && [ -f project.yml ]; then
        xcodegen generate
    fi

    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    if [ -n "$TEAM_ID" ] && xcodebuild -quiet \
        -project "$PROJECT_DIR/LlatserListen.xcodeproj" \
        -scheme LlatserListen \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -archivePath "$BUILD_DIR/LlatserListen.xcarchive" \
        archive \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Automatic \
        ONLY_ACTIVE_ARCH=NO \
        ARCHS=arm64; then
        plutil -create xml1 "$BUILD_DIR/ExportOptions.plist"
        plutil -insert method -string developer-id "$BUILD_DIR/ExportOptions.plist"
        plutil -insert destination -string export "$BUILD_DIR/ExportOptions.plist"
        plutil -insert signingStyle -string automatic "$BUILD_DIR/ExportOptions.plist"
        plutil -insert teamID -string "$TEAM_ID" "$BUILD_DIR/ExportOptions.plist"
        plutil -insert stripSwiftSymbols -bool YES "$BUILD_DIR/ExportOptions.plist"

        if xcodebuild -exportArchive \
            -archivePath "$BUILD_DIR/LlatserListen.xcarchive" \
            -exportPath "$BUILD_DIR/export" \
            -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
            -allowProvisioningUpdates >/dev/null; then
            SOURCE_APP="$BUILD_DIR/export/$APP_NAME.app"
            SIGNING_NOTE="Developer ID signed"
        fi
    fi

    if [ -z "$SOURCE_APP" ]; then
        if [ "$ALLOW_LOCAL_SIGNING" != "1" ]; then
            echo "Developer ID export unavailable."
            echo "Refusing to package a locally signed build because it will break macOS privacy permissions again."
            echo "Set LLATSER_LISTEN_TEAM_ID for your Developer ID team, or use LLATSER_ALLOW_LOCAL_SIGNING=1 for a local-only development package."
            exit 1
        fi

        echo "[build] Developer ID export unavailable; creating development-signed Apple Silicon app..."
        xcodebuild -quiet \
            -project "$PROJECT_DIR/LlatserListen.xcodeproj" \
            -scheme LlatserListen \
            -configuration Release \
            -derivedDataPath "$BUILD_DIR" \
            -destination "generic/platform=macOS" \
            clean build \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            ONLY_ACTIVE_ARCH=NO \
            ARCHS=arm64

        SOURCE_APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

        # Hardened runtime without the audio-input entitlement silently kills
        # the microphone on the receiving Mac — always sign with entitlements.
        ENTITLEMENTS="$PROJECT_DIR/LlatserListen/LlatserListen.entitlements"
        if [ -n "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
            codesign --force --deep --timestamp=none --options runtime \
                --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$SOURCE_APP"
            SIGNING_NOTE="Apple Development signed"
        else
            echo "No Apple Development signing identity found; using ad-hoc signature."
            codesign --force --deep --options runtime \
                --entitlements "$ENTITLEMENTS" --sign - "$SOURCE_APP"
            SIGNING_NOTE="ad-hoc signed"
        fi
    fi
else
    SIGN_DETAILS="$(codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 || true)"
    if grep -Fq "Authority=Developer ID Application:" <<<"$SIGN_DETAILS"; then
        SIGNING_NOTE="Developer ID signed"
    else
        SIGNING_NOTE="custom source app"
    fi
fi

if [ ! -d "$SOURCE_APP" ]; then
    echo "Missing app: $SOURCE_APP"
    exit 1
fi

ARCHITECTURES="$(lipo -archs "$SOURCE_APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true)"
if [ "$ARCHITECTURES" != "arm64" ]; then
    echo "Refusing to package an app outside the supported Apple Silicon contract." >&2
    echo "Expected arm64, found: ${ARCHITECTURES:-no readable executable}" >&2
    exit 1
fi

echo "Source: $SOURCE_APP"
echo "Signing: $SIGNING_NOTE"
echo "Architecture: $ARCHITECTURES"

if [ -e "$OUT_DIR" ] || [ -e "$ZIP_PATH" ]; then
    echo "Refusing to overwrite an existing package path." >&2
    echo "Move or remove these exact outputs first: $OUT_DIR and $ZIP_PATH" >&2
    exit 1
fi
mkdir -p "$OUT_DIR/Payload"

echo "[1/4] Copying app into transfer payload..."
ditto "$SOURCE_APP" "$OUT_DIR/Payload/$APP_NAME.app"
xattr -cr "$OUT_DIR/Payload/$APP_NAME.app" 2>/dev/null || true

echo "[2/4] Verifying copied app signature..."
codesign --verify --deep --strict "$OUT_DIR/Payload/$APP_NAME.app"

echo "[3/4] Writing receiver-side installer..."
cat > "$OUT_DIR/Install $APP_NAME.command" <<'INSTALLER'
#!/bin/bash
set -euo pipefail

APP_NAME="Beers"
BUNDLE_ID="com.llatser.listen"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_APP="$SCRIPT_DIR/Payload/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"
LOG_FILE="/tmp/llatser-listen.log"

if [ ! -d "$SOURCE_APP" ]; then
    echo "Cannot find $APP_NAME.app next to this installer."
    echo "Keep the Payload folder and this installer together."
    exit 1
fi

echo "Installing $APP_NAME..."
pkill -x "$APP_NAME" 2>/dev/null || true

if [ -w /Applications ]; then
    rm -rf "$DEST_APP"
    ditto "$SOURCE_APP" "$DEST_APP"
else
    /usr/bin/osascript <<OSA
do shell script "/bin/rm -rf " & quoted form of "$DEST_APP" & " && /usr/bin/ditto " & quoted form of "$SOURCE_APP" & " " & quoted form of "$DEST_APP" with administrator privileges
OSA
fi

xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
xattr -d com.apple.macl "$DEST_APP" 2>/dev/null || true
codesign --verify --deep --strict "$DEST_APP"

touch "$LOG_FILE" 2>/dev/null || true

/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
    -f -R -trusted "$DEST_APP" 2>/dev/null || true

echo ""
echo "Installed: $DEST_APP"
echo "Opening $APP_NAME..."
open "$DEST_APP"
echo ""
echo "If macOS asks, allow Microphone, Accessibility, and Input Monitoring permissions for $APP_NAME."
echo "Log file: $LOG_FILE"
INSTALLER
chmod +x "$OUT_DIR/Install $APP_NAME.command"

cat > "$OUT_DIR/README-FIRST.txt" <<README
Beers AirDrop install

Use:
1. AirDrop "$APP_NAME AirDrop.zip" to the other Mac.
2. Open the ZIP.
3. Double-click "Install $APP_NAME.command".

This installer copies the app to /Applications, clears AirDrop quarantine from
the installed copy, registers it with macOS, and launches it.

Important:
- This package is $SIGNING_NOTE.
- A fully seamless no-warning double-click install requires Apple notarization.
- On first launch, macOS may still ask for Microphone, Accessibility, and Input Monitoring permissions.

Bundle ID: $BUNDLE_ID
README

echo "[4/4] Creating AirDrop ZIP..."
ditto -c -k --sequesterRsrc --keepParent "$OUT_DIR" "$ZIP_PATH"

echo ""
echo "=== Done ==="
echo "AirDrop this file:"
echo "$ZIP_PATH"
