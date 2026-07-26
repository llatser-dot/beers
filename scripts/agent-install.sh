#!/bin/bash
# Fast local install for agent/dev iteration.
#
# Always signs with a STABLE identity so Microphone / Input Monitoring /
# Accessibility TCC grants survive rebuilds.
#
# NEVER ad-hoc signs. Ad-hoc (`codesign -s -`) keys TCC on a per-build cdhash,
# which is why every agent edit forced a full permission re-grant.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Beers"
APP_DEST="/Applications/$APP_NAME.app"
LEGACY_APP_DEST="/Applications/Llatser Listen.app"
LOG_FILE="/tmp/llatser-listen.log"
CONFIGURATION="${LLATSER_CONFIGURATION:-Debug}"
DERIVED_DATA="$PROJECT_DIR/build/agent-derived"

pick_identity() {
    if [ -n "${LLATSER_LISTEN_SIGN_IDENTITY:-}" ]; then
        echo "$LLATSER_LISTEN_SIGN_IDENTITY"
        return
    fi
    local id
    id="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application:/ { print $2; exit }')"
    if [ -n "$id" ]; then echo "$id"; return; fi
    id="$(security find-identity -v -p codesigning | awk -F '"' '/Llatser Listen Local Code Signing/ { print $2; exit }')"
    if [ -n "$id" ]; then echo "$id"; return; fi
    id="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ { print $2; exit }')"
    if [ -n "$id" ]; then echo "$id"; return; fi
    echo ""
}

echo "=== Beers Agent Install ==="

IDENTITY="$(pick_identity)"
if [ -z "$IDENTITY" ]; then
    echo "No usable code-signing identity found."
    echo "Creating a stable local identity..."
    bash "$PROJECT_DIR/scripts/create-local-signing-identity.sh"
    IDENTITY="$(pick_identity)"
fi
if [ -z "$IDENTITY" ]; then
    echo "Still no identity. Open Xcode > Settings > Accounts and ensure a team is signed in."
    exit 1
fi
echo "Using identity: $IDENTITY"

cd "$PROJECT_DIR"
xcodegen generate

echo "Building $CONFIGURATION..."
xcodebuild -quiet \
    -project "$PROJECT_DIR/Beers.xcodeproj" \
    -scheme "Beers" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination "platform=macOS,arch=arm64" \
    build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "Build did not produce $BUILT_APP"
    exit 1
fi

echo "Signing with stable identity..."
codesign --force --deep --timestamp=none --options runtime \
    --entitlements "$PROJECT_DIR/Beers/Beers.entitlements" \
    --sign "$IDENTITY" \
    "$BUILT_APP"

NEW_REQ="$(codesign -d -r- "$BUILT_APP" 2>/dev/null | grep '^designated' || true)"
OLD_REQ=""
if [ -d "$APP_DEST" ]; then
    OLD_REQ="$(codesign -d -r- "$APP_DEST" 2>/dev/null | grep '^designated' || true)"
fi

echo "New designated requirement:"
echo "  $NEW_REQ"

pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$APP_DEST"
rm -rf "$LEGACY_APP_DEST"
ditto "$BUILT_APP" "$APP_DEST"
xattr -cr "$APP_DEST"
codesign --verify --deep --strict "$APP_DEST"

# Kill ghost copies. System Settings / TCC get confused when multiple
# com.llatser.listen bundles exist (especially ad-hoc DerivedData builds).
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
"$LSREG" -u "$BUILT_APP" 2>/dev/null || true
while IFS= read -r -d '' GHOST; do
    case "$GHOST" in
        "$APP_DEST") continue ;;
    esac
    "$LSREG" -u "$GHOST" 2>/dev/null || true
    rm -rf "$GHOST"
done < <(find "$PROJECT_DIR" "$HOME/Library/Developer/Xcode/DerivedData" -name "$APP_NAME.app" -type d -print0 2>/dev/null)
"$LSREG" -f -R -trusted "$APP_DEST" 2>/dev/null || true

> "$LOG_FILE"

TCC_NOTE="Privacy permissions preserved (stable signing identity)."
if [ "${LLATSER_RESET_TCC:-0}" = "1" ] || [ -z "$OLD_REQ" ] || [ "$OLD_REQ" != "$NEW_REQ" ]; then
    echo "Signing requirement changed (or first stable install) — clearing stale TCC rows once..."
    tccutil reset ListenEvent com.llatser.listen >/dev/null 2>&1 || true
    tccutil reset Accessibility com.llatser.listen >/dev/null 2>&1 || true
    tccutil reset Microphone com.llatser.listen >/dev/null 2>&1 || true
    TCC_NOTE="Grant Microphone, Input Monitoring, and Accessibility ONCE now. Future agent installs keep them."
fi

open "$APP_DEST"

# Drop local build products after install so Finder/Spotlight only show
# the project sources + /Applications app (no ghost .app trees).
rm -rf "$DERIVED_DATA"
rm -rf "$PROJECT_DIR/build"

echo ""
echo "=== Done ==="
echo "Project:   $PROJECT_DIR"
echo "Installed: $APP_DEST"
echo "Identity:  $IDENTITY"
echo "$TCC_NOTE"
echo "Log: $LOG_FILE"
