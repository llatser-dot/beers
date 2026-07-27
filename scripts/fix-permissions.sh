#!/bin/bash
# One-shot repair for the "macOS keeps asking for permissions again" loop.
#
# Two independent faults produce that loop, and this script fixes both.
#
# 1. Duplicate "Beers" rows in System Settings > Privacy & Security.
#    Throwaway builds (release checks, smoke tests, /tmp experiments) all ship
#    the com.llatser.listen bundle identifier. LaunchServices registers each one
#    and never garbage-collects the record. System Settings draws a row per
#    registration it can resolve, so you get several identical Beers icons and
#    no way to tell which is the app you actually run.
#
# 2. A permission that reads as granted but does not work.
#    TCC stores the code-signing requirement captured at the moment you granted
#    it. Beers has been signed four different ways over its life: ad-hoc, a
#    local self-signed identity, Apple Development, and Developer ID. A row
#    granted under one identity still shows its toggle ON, but fails validation
#    against a build signed with another — so the app prompts again. Removing
#    and re-adding the app rewrites the requirement, which is why that "works".
#
# After this script, grant the permissions ONCE. Because /Applications/Beers.app
# is Developer ID signed and notarized, its designated requirement is stable
# across every future release, and Sparkle updates will keep the grants.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/lsregister.sh
source "$PROJECT_DIR/scripts/lib/lsregister.sh"

BUNDLE_ID="com.llatser.listen"
APP_NAME="Beers"
APP_DEST="/Applications/$APP_NAME.app"

echo "=== Beers permission repair ==="

if [ ! -d "$APP_DEST" ]; then
    echo "ERROR: $APP_DEST is not installed. Install the release build first."
    exit 1
fi

# --- The installed app must be the notarized Developer ID build -------------
# If it is not, cleaning up around it is pointless: the next release will drift
# its code identity again and every grant will break a second time.
echo ""
echo "Checking the installed app's code identity..."
if ! codesign --verify --deep --strict "$APP_DEST" 2>/dev/null; then
    echo "ERROR: $APP_DEST fails signature verification. Reinstall a release build."
    exit 1
fi

TEAM="$(codesign -dvv "$APP_DEST" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [ -z "$TEAM" ] || [ "$TEAM" = "not set" ]; then
    echo "ERROR: $APP_DEST is ad-hoc signed (no Team ID)."
    echo "TCC cannot key a durable grant to it. Install the Developer ID build."
    exit 1
fi
echo "  Team ID:  $TEAM"
echo "  Notarized: $(spctl -a -t exec "$APP_DEST" >/dev/null 2>&1 && echo yes || echo 'NO — grants will still work, but users will see Gatekeeper warnings')"

# --- Purge every registration that is not the installed app -----------------
# Orphans (deleted paths) are invisible clutter. Live ghosts (/tmp and
# DerivedData builds that still exist) are the duplicate icons you can see.
echo ""
echo "Purging stale LaunchServices registrations for $BUNDLE_ID..."

# Collect the ghost paths BEFORE unregistering anything. Unregistering removes
# them from the LaunchServices dump, so re-querying afterwards returns nothing
# and the on-disk cleanup below would silently do no work.
GHOST_PATHS=()
ORPHANS=0
while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ "$path" = "$APP_DEST" ] && continue

    if [ -e "$path" ]; then
        GHOST_PATHS+=("$path")
        echo "  ghost:  $path"
    else
        ORPHANS=$((ORPHANS + 1))
    fi
    "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
done < <(registered_bundle_paths)

echo "  Removed ${#GHOST_PATHS[@]} live ghost bundle(s) and $ORPHANS orphaned record(s) from LaunchServices."

# Unregistering alone is not durable: these bundles still exist, and any
# Spotlight reindex or `lsregister -R` sweep will happily register them again,
# putting the duplicate icons straight back. Delete the ones we own.
if [ "${#GHOST_PATHS[@]}" -gt 0 ] && [ "${BEERS_DELETE_GHOSTS:-0}" = "1" ]; then
    echo ""
    echo "Deleting ghost bundles from disk (BEERS_DELETE_GHOSTS=1)..."
    for path in "${GHOST_PATHS[@]}"; do
        [ -e "$path" ] || continue
        case "$path" in
            /private/tmp/*|/tmp/*|"$PROJECT_DIR"/*|"$HOME"/Library/Developer/Xcode/DerivedData/*)
                rm -rf "$path" && echo "  deleted: $path"
                ;;
            *)
                echo "  kept (outside build dirs, delete by hand): $path"
                ;;
        esac
    done
elif [ "${#GHOST_PATHS[@]}" -gt 0 ]; then
    echo ""
    echo "  These bundles still exist on disk and can re-register themselves."
    echo "  Re-run with BEERS_DELETE_GHOSTS=1 to delete the ones under build dirs."
fi

# Re-register the one true app so it is the only row System Settings can draw.
"$LSREGISTER" -f -R -trusted "$APP_DEST" >/dev/null 2>&1 || true

# --- Reset the stale TCC rows ------------------------------------------------
# These rows carry code requirements from older, differently-signed builds.
# Resetting is what stops the "already granted but still prompting" state.
echo ""
echo "Resetting TCC rows carrying stale code requirements..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
for service in Microphone ListenEvent Accessibility SystemPolicyAllFiles; do
    if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "  reset $service"
    fi
done

echo ""
echo "=== Done ==="
echo ""
echo "Now, ONCE:"
echo "  1. Open System Settings > Privacy & Security."
echo "  2. Under Microphone (and Input Monitoring / Accessibility if Beers uses"
echo "     them), there should now be exactly ONE Beers entry, or none."
echo "  3. Launch Beers and grant each prompt as it appears."
echo ""
echo "These grants will now survive Sparkle updates: the notarized Developer ID"
echo "signature gives every future release the same designated requirement."
echo ""
echo "Re-run this script only if a duplicate icon ever reappears — and if one"
echo "does, a build script leaked a registration. Fix that script instead."
