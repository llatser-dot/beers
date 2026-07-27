#!/bin/bash
# Shared LaunchServices helpers.
#
# Throwaway builds (release checks, smoke tests, airdrop packaging) produce a
# Beers.app that claims com.llatser.listen. LaunchServices registers it the
# moment it touches the disk and NEVER garbage-collects the record, even after
# the directory is deleted. Those orphan records are why System Settings grows
# duplicate "Beers" rows in Privacy & Security: one row per registration it can
# still resolve, and only one of them is the app you actually run.
#
# Every script that builds a Beers.app outside /Applications must unregister it
# before deleting the build directory.

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

# unregister_apps_under <dir> — drop LaunchServices records for every .app
# bundle inside <dir>. Safe to call on a directory that no longer exists.
unregister_apps_under() {
    local root="$1"
    [ -n "$root" ] || return 0
    [ -d "$root" ] || return 0
    [ -x "$LSREGISTER" ] || return 0

    while IFS= read -r -d '' bundle; do
        "$LSREGISTER" -u "$bundle" >/dev/null 2>&1 || true
    done < <(find "$root" -name '*.app' -type d -print0 2>/dev/null)
}

# purge_orphan_registrations — drop every com.llatser.listen record whose bundle
# path no longer exists on disk. Prints the count removed.
purge_orphan_registrations() {
    [ -x "$LSREGISTER" ] || return 0

    local removed=0 path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -e "$path" ] && continue
        "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
        removed=$((removed + 1))
    done < <(registered_bundle_paths)

    echo "$removed"
}

# registered_bundle_paths — every distinct path LaunchServices currently has
# registered under the com.llatser.listen bundle identifier.
registered_bundle_paths() {
    [ -x "$LSREGISTER" ] || return 0
    # lsregister -dump emits "path:" and "identifier:" lines per record. Capture
    # the whole remainder of the path line — bundle paths contain spaces
    # ("Llatser Listen.app") — and emit it when the record's identifier matches.
    # Trailing "(0x61a0)" node ids are stripped.
    "$LSREGISTER" -dump 2>/dev/null \
        | sed -n -E 's/^[[:space:]]*(path|identifier):[[:space:]]*/\1: /p' \
        | awk '
            /^path: /       { p = substr($0, 7); sub(/ \(0x[0-9a-f]+\)$/, "", p) }
            /^identifier: / { if (substr($0, 13) == "com.llatser.listen" && p != "") print p }
        ' \
        | sort -u
}
