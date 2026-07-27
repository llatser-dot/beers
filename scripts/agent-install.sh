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
# shellcheck source=lib/lsregister.sh
source "$PROJECT_DIR/scripts/lib/lsregister.sh"

APP_NAME="Beers"
APP_DEST="/Applications/$APP_NAME.app"
# One-time migration: removes the app bundle left behind by installs that
# predate the Beers rename. The literal old path is required here — this is the
# only remaining reference to that name, and it exists solely to delete it.
# Safe to drop once no machine still has a pre-1.1 install.
LEGACY_APP_DEST="/Applications/Llatser Listen.app"
LOG_FILE="/tmp/beers.log"
CONFIGURATION="${BEERS_CONFIGURATION:-Debug}"
DERIVED_DATA="$PROJECT_DIR/build/agent-derived"

# Developer ID only.
#
# This used to fall back through a local self-signed identity and then Apple
# Development. That ladder was the bug it was trying to prevent: each rung
# produces a DIFFERENT designated requirement for the same com.llatser.listen
# bundle, so an install that quietly stepped down a rung invalidated every TCC
# grant — and macOS reports the old row as still granted while the app keeps
# prompting. A hard failure is better than a silent identity change.
#
# Set BEERS_ALLOW_UNSTABLE_IDENTITY=1 to opt into the old behaviour when you
# have no Developer ID certificate and accept re-granting permissions.
pick_identity() {
    if [ -n "${BEERS_SIGN_IDENTITY:-}" ]; then
        echo "$BEERS_SIGN_IDENTITY"
        return
    fi
    local id
    id="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application:/ { print $2; exit }')"
    if [ -n "$id" ]; then echo "$id"; return; fi

    if [ "${BEERS_ALLOW_UNSTABLE_IDENTITY:-0}" = "1" ]; then
        id="$(security find-identity -v -p codesigning | awk -F '"' '/Beers Local Code Signing/ { print $2; exit }')"
        if [ -n "$id" ]; then echo "$id"; return; fi
        id="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ { print $2; exit }')"
        if [ -n "$id" ]; then echo "$id"; return; fi
    fi
    echo ""
}

echo "=== Beers Agent Install ==="

IDENTITY="$(pick_identity)"
if [ -z "$IDENTITY" ] && [ "${BEERS_ALLOW_UNSTABLE_IDENTITY:-0}" = "1" ]; then
    echo "No Developer ID certificate. Creating a local identity (unstable mode)..."
    bash "$PROJECT_DIR/scripts/create-local-signing-identity.sh"
    IDENTITY="$(pick_identity)"
fi
if [ -z "$IDENTITY" ]; then
    echo "No 'Developer ID Application' certificate found."
    echo ""
    echo "Beers must be signed with Developer ID so its designated requirement"
    echo "stays constant across releases. Any other identity makes macOS discard"
    echo "Microphone / Input Monitoring / Accessibility grants on every update."
    echo ""
    echo "Fix: Xcode > Settings > Accounts > Manage Certificates > + Developer ID"
    echo "Application. Or set BEERS_SIGN_IDENTITY to an explicit identity."
    echo "To build anyway and accept re-granting: BEERS_ALLOW_UNSTABLE_IDENTITY=1"
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

# Kill ghost copies. System Settings draws one Privacy row per registered
# com.llatser.listen bundle, so every stray build becomes another identical
# "Beers" icon with no way to tell which one is live.
#
# Drive this off the LaunchServices database rather than a find() over known
# directories: the old version only swept the project dir and DerivedData, and
# missed the throwaway /tmp builds that produce most of the ghosts.
"$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
while IFS= read -r GHOST; do
    [ -n "$GHOST" ] || continue
    [ "$GHOST" = "$APP_DEST" ] && continue
    "$LSREGISTER" -u "$GHOST" >/dev/null 2>&1 || true
    # Only delete bundles under build directories we own.
    case "$GHOST" in
        /private/tmp/*|/tmp/*|"$PROJECT_DIR"/*|"$HOME"/Library/Developer/Xcode/DerivedData/*)
            rm -rf "$GHOST"
            ;;
    esac
done < <(registered_bundle_paths)
"$LSREGISTER" -f -R -trusted "$APP_DEST" >/dev/null 2>&1 || true

> "$LOG_FILE"

TCC_NOTE="Privacy permissions preserved (stable signing identity)."
if [ "${BEERS_RESET_TCC:-0}" = "1" ] || [ -z "$OLD_REQ" ] || [ "$OLD_REQ" != "$NEW_REQ" ]; then
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
