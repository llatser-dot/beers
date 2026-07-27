#!/bin/bash
set -euo pipefail

BENCHMARK_DIR="${1:-$HOME/Library/Application Support/Beers/ASR Benchmarks}"
APP="/Applications/Beers.app/Contents/MacOS/Beers"

if [[ ! -x "$APP" ]]; then
    echo "Beers is not installed at /Applications/Beers.app." >&2
    exit 1
fi
if [[ ! -f "$BENCHMARK_DIR/manifest.jsonl" ]]; then
    echo "No benchmark manifest at: $BENCHMARK_DIR/manifest.jsonl" >&2
    echo "Enable 'Capture ASR benchmark audio' in Brew Settings and collect some pours first." >&2
    exit 1
fi

"$APP" --beers-asr-benchmark "$BENCHMARK_DIR"
python3 "$(dirname "$0")/score-asr-benchmark.py" "$BENCHMARK_DIR/results.jsonl"
