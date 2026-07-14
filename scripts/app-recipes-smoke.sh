#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/beers-app-recipes-smoke.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun swiftc \
    "$PROJECT_DIR/LlatserListen/WritingMode.swift" \
    "$PROJECT_DIR/LlatserListen/ActiveAppContext.swift" \
    "$PROJECT_DIR/LlatserListen/AppRecipe.swift" \
    "$PROJECT_DIR/LlatserListen/AppRecipeSettings.swift" \
    "$PROJECT_DIR/LlatserListen/AppRecipeStore.swift" \
    "$PROJECT_DIR/scripts/app-recipes-smoke.swift" \
    -o "$BUILD_DIR/app-recipes-smoke"

"$BUILD_DIR/app-recipes-smoke"
