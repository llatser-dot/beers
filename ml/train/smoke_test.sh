#!/usr/bin/env bash
# Smoke test: prove the Bouncer harness runs end-to-end on MPS against the
# hand-written fixture BEFORE real data lands. Trains 1 tiny epoch, evaluates,
# calibrates. Asserts each stage produces its artifact. NOT a quality test.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ML="$(cd "$HERE/.." && pwd)"
PY="$ML/.venv/bin/python"
FIX="$HERE/fixture/fixture.jsonl"
RUN="smoke"
MODEL_DIR="$ML/models/$RUN"

echo "== Bouncer smoke test =="
echo "python: $PY"
"$PY" -c "import torch; print('mps_available', torch.backends.mps.is_available())"

[ -f "$FIX" ] || "$PY" "$HERE/fixture/build_fixture.py"

cd "$HERE"

echo; echo "== [1/3] train (1 epoch, tiny) =="
"$PY" train.py \
  --train "$FIX" --val "$FIX" \
  --run-name "$RUN" --epochs 1 --batch-size 4 \
  --model distilbert-base-cased --seed 42 --patience 5

test -f "$MODEL_DIR/model.safetensors" -o -f "$MODEL_DIR/pytorch_model.bin" \
  || { echo "FAIL: no checkpoint weights saved"; exit 1; }
test -f "$MODEL_DIR/report.json" || { echo "FAIL: no report.json"; exit 1; }
test -f "$MODEL_DIR/tokenizer.json" || { echo "FAIL: tokenizer not saved"; exit 1; }
echo "OK: checkpoint + tokenizer + report.json present"

echo; echo "== [2/3] evaluate =="
"$PY" evaluate.py --model-dir "$MODEL_DIR" --data "$FIX"
test -f "$MODEL_DIR/eval-fixture.md" || { echo "FAIL: no eval report"; exit 1; }
echo "OK: eval report written"

echo; echo "== [3/3] calibrate =="
"$PY" calibrate.py --model-dir "$MODEL_DIR" --data "$FIX"
test -f "$MODEL_DIR/threshold.json" || { echo "FAIL: no threshold.json"; exit 1; }
echo "OK: threshold.json written"

echo; echo "== re-evaluate with calibrated threshold =="
"$PY" evaluate.py --model-dir "$MODEL_DIR" --data "$FIX"

echo; echo "== SMOKE TEST PASSED =="
