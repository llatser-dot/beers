#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
BUILD_DIR="$(mktemp -d "${TMP_ROOT%/}/beers-release-check.XXXXXX")"
APP="$BUILD_DIR/Build/Products/Release/Beers.app"
BINARY="$APP/Contents/MacOS/Beers"
BOUNCER_DIR="$PROJECT_DIR/LlatserListen/Resources/Bouncer"

cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

fail() {
    echo "Release check failed: $*" >&2
    exit 1
}

if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=normal)" ]]; then
    fail "the Git worktree and index must be clean."
fi

for command in git grep lipo plutil python3 xcodegen xcodebuild xcrun; do
    if ! command -v "$command" >/dev/null 2>&1; then
        fail "missing required command: $command"
    fi
done

if ! git lfs version >/dev/null 2>&1; then
    fail "missing git-lfs (install with 'brew install git-lfs')."
fi

git -C "$PROJECT_DIR" lfs fsck

LFS_COUNT=0
while IFS= read -r lfs_path; do
    [[ -n "$lfs_path" ]] || continue
    LFS_COUNT=$((LFS_COUNT + 1))
    lfs_file="$PROJECT_DIR/$lfs_path"
    [[ -f "$lfs_file" ]] || fail "missing Git LFS file: $lfs_path (run 'git lfs pull')."
    if grep -aq '^version https://git-lfs.github.com/spec/v1' "$lfs_file"; then
        fail "Git LFS pointer was not materialised: $lfs_path (run 'git lfs pull')."
    fi
done < <(git -C "$PROJECT_DIR" lfs ls-files --name-only)
[[ "$LFS_COUNT" -gt 0 ]] || fail "no Git LFS files were found; check .gitattributes and the clone."

python3 - \
    "$BOUNCER_DIR/threshold.json" \
    "$BOUNCER_DIR/labels.json" \
    "$BOUNCER_DIR/Bouncer.mlpackage/Manifest.json" <<'PY'
import json
import sys

threshold_path, labels_path, manifest_path = sys.argv[1:]
with open(threshold_path, encoding="utf-8") as handle:
    threshold = json.load(handle)
with open(labels_path, encoding="utf-8") as handle:
    labels = json.load(handle)
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)

if not isinstance(threshold.get("threshold"), (int, float)):
    raise SystemExit("threshold.json is missing its numeric threshold")
if not isinstance(threshold.get("target_met"), bool):
    raise SystemExit("threshold.json is missing its boolean target_met gate")
if labels.get("id2label", {}).get("0") != "KEEP" or labels.get("keep_id") != 0:
    raise SystemExit("labels.json no longer preserves KEEP as label 0")
if not isinstance(manifest, dict) or not manifest:
    raise SystemExit("Bouncer.mlpackage/Manifest.json is empty or invalid")
PY

SMOKE_BINARY="$BUILD_DIR/endpoint-trust-smoke"
xcrun swiftc \
    "$PROJECT_DIR/LlatserListen/AIEndpointTrust.swift" \
    "$PROJECT_DIR/scripts/endpoint-trust-smoke.swift" \
    -o "$SMOKE_BINARY"
"$SMOKE_BINARY"

POLISH_SMOKE_BINARY="$BUILD_DIR/polish-smoke"
xcrun swiftc \
    "$PROJECT_DIR/LlatserListen/WritingMode.swift" \
    "$PROJECT_DIR/LlatserListen/ActiveAppContext.swift" \
    "$PROJECT_DIR/LlatserListen/TranscriptPolisher.swift" \
    "$PROJECT_DIR/scripts/polish-smoke.swift" \
    -o "$POLISH_SMOKE_BINARY"
POLISH_RESULT="$("$POLISH_SMOKE_BINARY" "visit example dot com.")"
[[ "$POLISH_RESULT" == "Visit example.com" ]] || \
    fail "polish smoke returned '$POLISH_RESULT' instead of 'Visit example.com'."
echo "Transcript polish smoke passed."

SANITIZER_SMOKE_BINARY="$BUILD_DIR/transcript-sanitizer-smoke"
xcrun swiftc \
    "$PROJECT_DIR/LlatserListen/TranscriptSanitizer.swift" \
    "$PROJECT_DIR/scripts/transcript-sanitizer-smoke.swift" \
    -o "$SANITIZER_SMOKE_BINARY"
"$SANITIZER_SMOKE_BINARY"

# Ordinary pours must remain structurally incapable of calling a generative
# rewrite. Command Mode still uses OrderKitchen.applyInstruction.
if grep -q 'OrderKitchen\.polish(' "$PROJECT_DIR/LlatserListen/AppState.swift"; then
    fail "ordinary AppState pours call OrderKitchen.polish; Parakeet-first boundary regressed."
fi
grep -q 'case parakeetFast = "parakeet-fast"' "$PROJECT_DIR/LlatserListen/OrderKitchen.swift" || \
    fail "Parakeet fast serving tier is missing."
grep -q 'return text' "$PROJECT_DIR/LlatserListen/TranscriptionEngine.swift" || \
    fail "TranscriptionEngine no longer exposes raw Parakeet output."
echo "Parakeet-first boundary smoke passed."
python3 "$PROJECT_DIR/scripts/score-asr-benchmark.py" --self-test

(cd "$PROJECT_DIR" && xcodegen generate)

xcodebuild -quiet \
    -project "$PROJECT_DIR/LlatserListen.xcodeproj" \
    -scheme LlatserListen \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -destination "generic/platform=macOS" \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS=arm64 \
    build

[[ -x "$BINARY" ]] || fail "the Release build did not produce an executable Beers binary."
ARCHITECTURES="$(lipo -archs "$BINARY")"
[[ "$ARCHITECTURES" == "arm64" ]] || \
    fail "the public build must contain arm64 only; found: $ARCHITECTURES"

INFO_PLIST="$APP/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")" == "com.llatser.listen" ]] || \
    fail "unexpected CFBundleIdentifier."
[[ "$(plutil -extract LSUIElement raw "$INFO_PLIST")" == "true" ]] || \
    fail "LSUIElement must remain true."
[[ "$(plutil -extract LSMinimumSystemVersion raw "$INFO_PLIST")" == "14.0" ]] || \
    fail "LSMinimumSystemVersion must remain 14.0."
[[ -n "$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")" ]] || \
    fail "CFBundleShortVersionString is empty."
[[ -n "$(plutil -extract CFBundleVersion raw "$INFO_PLIST")" ]] || \
    fail "CFBundleVersion is empty."
[[ -n "$(plutil -extract NSMicrophoneUsageDescription raw "$INFO_PLIST")" ]] || \
    fail "NSMicrophoneUsageDescription is empty."

[[ -d "$APP/Contents/Resources/Bouncer.mlmodelc" ]] || fail "compiled Bouncer model is missing."
for resource in threshold.json labels.json vocab.txt; do
    [[ -s "$APP/Contents/Resources/$resource" ]] || fail "bundled resource is missing or empty: $resource"
done

echo "Release readiness passed: clean Git, $LFS_COUNT LFS objects, endpoint and polish smokes, unsigned arm64 build, metadata and Bouncer resources."
