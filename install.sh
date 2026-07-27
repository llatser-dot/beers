#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Beers"
APP_DEST="/Applications/$APP_NAME.app"
# One-time migration: removes the app bundle left behind by installs that
# predate the Beers rename. The literal old path is required here — this is the
# only remaining reference to that name, and it exists solely to delete it.
# Safe to drop once no machine still has a pre-1.1 install.
LEGACY_APP_DEST="/Applications/Llatser Listen.app"
LOG_FILE="/tmp/beers.log"
SIGN_IDENTITY="${BEERS_SIGN_IDENTITY:-}"
TEAM_ID="${BEERS_TEAM_ID:-}"
ALLOW_LOCAL_SIGNING="${BEERS_ALLOW_LOCAL_SIGNING:-0}"
DEVELOPER_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application:/ { print $2; exit }')"
STABLE_LOCAL_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Beers Local Code Signing/ { print $2; exit }')"
APPLE_DEV_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ { print $2; exit }')"

if [ -z "$SIGN_IDENTITY" ]; then
    if [ -n "$DEVELOPER_IDENTITY" ]; then
        SIGN_IDENTITY="$DEVELOPER_IDENTITY"
    elif [ -n "$STABLE_LOCAL_IDENTITY" ]; then
        SIGN_IDENTITY="$STABLE_LOCAL_IDENTITY"
    else
        SIGN_IDENTITY="$APPLE_DEV_IDENTITY"
    fi
fi

if [ -n "$TEAM_ID" ] && [ -z "$DEVELOPER_IDENTITY" ]; then
    echo "Note: no local Developer ID certificate; relying on Xcode cloud-managed signing for the archive."
fi

SIGNING_MODE="Developer ID"

echo "=== Beers Build & Install ==="

echo "[1/6] Generating project..."
cd "$PROJECT_DIR"
xcodegen generate

echo "[2/6] Building release app..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

if [ -n "$TEAM_ID" ] && xcodebuild -quiet \
    -project "$PROJECT_DIR/Beers.xcodeproj" \
    -scheme "Beers" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$BUILD_DIR/Beers.xcarchive" \
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

    if ! xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/Beers.xcarchive" \
        -exportPath "$BUILD_DIR/export" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
        -allowProvisioningUpdates >/dev/null; then
        echo "Developer ID export failed (Xcode account or certificate unavailable)."
        if [ "$ALLOW_LOCAL_SIGNING" != "1" ]; then
            echo "Sign in to Xcode (Settings > Accounts, team $TEAM_ID), or rerun with BEERS_ALLOW_LOCAL_SIGNING=1 to install with a stable local identity."
            exit 1
        fi
    fi
else
    if [ -z "$TEAM_ID" ]; then
        echo "Skipping Developer ID archive (BEERS_TEAM_ID is not set)."
    else
        echo "Developer ID archive failed."
    fi
    if [ "$ALLOW_LOCAL_SIGNING" != "1" ]; then
        echo "Refusing local signing because it changes the macOS privacy identity and forces re-granting Microphone/Input Monitoring/Accessibility."
        echo "Set BEERS_TEAM_ID for your Developer ID team, or rerun with BEERS_ALLOW_LOCAL_SIGNING=1 for a local-only install."
        exit 1
    fi
fi

BUILT_APP="$BUILD_DIR/export/$APP_NAME.app"

if [ ! -d "$BUILT_APP" ] && [ "$ALLOW_LOCAL_SIGNING" != "1" ]; then
    echo "Developer ID export did not produce $BUILT_APP"
    exit 1
fi

SIGN_DETAILS=""
if [ -d "$BUILT_APP" ]; then
    SIGN_DETAILS="$(codesign -dv --verbose=4 "$BUILT_APP" 2>&1 || true)"
fi
if ! grep -Fq "Authority=Developer ID Application:" <<<"$SIGN_DETAILS"; then
    if [ "$ALLOW_LOCAL_SIGNING" != "1" ]; then
        echo "Refusing to install a non-Developer-ID build because it will break macOS privacy permissions again."
        echo "Set BEERS_ALLOW_LOCAL_SIGNING=1 for a stable local-only install."
        exit 1
    fi

    echo "Developer ID export unavailable; falling back to local signing because BEERS_ALLOW_LOCAL_SIGNING=1."
    SIGNING_MODE="local signing"
    xcodebuild -quiet \
        -project "$PROJECT_DIR/Beers.xcodeproj" \
        -scheme "Beers" \
        -configuration Release \
        -derivedDataPath "$BUILD_DIR" \
        -destination "generic/platform=macOS" \
        clean build \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        ONLY_ACTIVE_ARCH=NO \
        ARCHS=arm64
    BUILT_APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

    # Fresh clone with no Apple certificate at all: mint the stable local
    # identity (same one agent-install.sh uses) so local signing can proceed.
    if [ -z "$SIGN_IDENTITY" ]; then
        echo "No code-signing identity found; creating a stable local identity..."
        bash "$PROJECT_DIR/scripts/create-local-signing-identity.sh"
        SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Beers Local Code Signing/ { print $2; exit }')"
    fi

    if [ -n "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
        codesign --force --deep --timestamp=none --options runtime \
            --entitlements "$PROJECT_DIR/Beers/Beers.entitlements" \
            --sign "$SIGN_IDENTITY" "$BUILT_APP"
    else
        echo "Missing local signing identity."
        exit 1
    fi
fi

echo "[3/6] Checking privacy identity stability..."
# TCC (Microphone/Input Monitoring/Accessibility) keys grants on the app's
# designated code-signing requirement. If it is unchanged, existing grants
# survive the update untouched. If it changed, the old grants are dead ghost
# rows — reset them once so a single clean re-grant works, instead of the
# remove/reapply dance.
OLD_REQ=""
if [ -d "$APP_DEST" ]; then
    OLD_REQ="$(codesign -d -r- "$APP_DEST" 2>/dev/null | grep '^designated' || true)"
fi
NEW_REQ="$(codesign -d -r- "$BUILT_APP" 2>/dev/null | grep '^designated' || true)"

echo "[4/6] Installing to /Applications..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1
rm -rf "$APP_DEST"
rm -rf "$LEGACY_APP_DEST"
ditto "$BUILT_APP" "$APP_DEST"
xattr -cr "$APP_DEST"

echo "[5/6] Verifying app signature..."
codesign --verify --deep --strict "$APP_DEST"

echo "[6/6] Resetting app log..."
> "$LOG_FILE"

TCC_NOTE="Privacy permissions preserved (signing identity unchanged)."
if [ "${BEERS_RESET_TCC:-0}" = "1" ] || [ -z "$OLD_REQ" ] || [ "$OLD_REQ" != "$NEW_REQ" ]; then
    if [ -n "$OLD_REQ" ] && [ "$OLD_REQ" != "$NEW_REQ" ]; then
        echo "Signing identity changed since last install; resetting stale privacy grants..."
    else
        echo "Resetting privacy grants for a clean first grant..."
    fi
    tccutil reset ListenEvent com.llatser.listen >/dev/null 2>&1 || true
    tccutil reset Accessibility com.llatser.listen >/dev/null 2>&1 || true
    tccutil reset Microphone com.llatser.listen >/dev/null 2>&1 || true
    TCC_NOTE="Privacy grants were reset — grant Microphone, Input Monitoring and Accessibility once when the app asks."
fi

# Xcode registers built products with Launch Services during local builds.
# Remove that copy so Finder/Launchpad only show the installed application.
if [ -d "$BUILD_DIR/export/$APP_NAME.app" ]; then
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
        -u "$BUILD_DIR/export/$APP_NAME.app" 2>/dev/null || true
fi

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

# Xcode/DerivedData copies with the same bundle id confuse Launch Services and
# macOS Privacy panes, causing duplicate or stale "Beers" entries.
if [ -d "$HOME/Library/Developer/Xcode/DerivedData" ]; then
    while IFS= read -r -d '' DERIVED_APP; do
        /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
            -u "$DERIVED_APP" 2>/dev/null || true
        rm -rf "$DERIVED_APP"
    done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/*/$APP_NAME.app" -type d -print0 2>/dev/null)
fi

/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
    -f -R -trusted "$APP_DEST" 2>/dev/null || true

open "$APP_DEST"

echo ""
echo "=== Done ==="
echo "Installed: $APP_DEST (relaunched)"
echo "Log: $LOG_FILE"
echo "Hotkey: Left Command"
echo "Engine default: Parakeet v3"
echo "Signing: $SIGNING_MODE"
echo "$TCC_NOTE"
