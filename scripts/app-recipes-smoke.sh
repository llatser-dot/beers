#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/beers-app-recipes-smoke.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun swiftc \
    "$PROJECT_DIR/Beers/WritingMode.swift" \
    "$PROJECT_DIR/Beers/ActiveAppContext.swift" \
    "$PROJECT_DIR/Beers/AppRecipe.swift" \
    "$PROJECT_DIR/Beers/AppRecipeSettings.swift" \
    "$PROJECT_DIR/Beers/AppRecipeStore.swift" \
    "$PROJECT_DIR/scripts/app-recipes-smoke.swift" \
    -o "$BUILD_DIR/app-recipes-smoke"

"$BUILD_DIR/app-recipes-smoke"
