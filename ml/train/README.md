# Bouncer training / eval / calibration harness

On-device disfluency tagger. Fine-tunes `distilbert-base-cased` for token
classification (labels per DESIGN.md), then calibrates a DELETE decision
threshold so **DELETE precision >= 0.98 on gold** (precision is sacred, recall
is negotiable). See `../DESIGN.md` for the label scheme and JSONL contract.

## Files
- `dataset.py`   — loads + validates the contract JSONL, WordPiece tokenizes,
  aligns word labels to the first subtoken (`-100` on continuations), 512-cap
  with truncation warning. Also class-weight helper.
- `infer.py`     — shared checkpoint loader + per-word probability extraction
  (softmax over first-subtoken logits) used by evaluate + calibrate.
- `train.py`     — custom MPS training loop: weighted-CE/focal, warmup+decay,
  early stop on val DELETE-F1, seed control. Saves checkpoint + tokenizer +
  `report.json` to `../models/<run-name>/`.
- `evaluate.py`  — per-class + binary-DELETE P/R/F1, transcript exact-match,
  and a false-DELETE failure dump. Markdown report.
- `calibrate.py` — sweeps the DELETE threshold `t` in [0.5, 0.99], picks the
  lowest `t` with precision >= target, writes `threshold.json` into model dir.
- `fixture/`     — 59-example hand-written smoke fixture + builder.
- `smoke_test.sh`— end-to-end pipeline check on the fixture (proves harness).

## Environment
```bash
cd ~/Projects/Llatser.Listen/ml
uv venv --python 3.12          # if .venv doesn't already exist
uv pip install torch transformers "numpy<2" scikit-learn
.venv/bin/python -c "import torch; print('mps', torch.backends.mps.is_available())"
```
All commands below assume `.venv/bin/python`. If you hit localhost-proxy or
tokenizer noise, prepend:
`no_proxy=127.0.0.1,localhost TOKENIZERS_PARALLELISM=false`.

## Smoke test (no real data needed)
```bash
bash train/smoke_test.sh
```
Trains 1 tiny epoch on the fixture, evaluates, calibrates, re-evaluates.
Verified: passes on MPS in ~55s.

---

## FULL RUN — once ml/data/{train,val,gold}.jsonl exist

Run from `ml/train/`. `PY=../.venv/bin/python`.

### 1. Train
```bash
../.venv/bin/python train.py \
  --train ../data/train.jsonl \
  --val   ../data/val.jsonl \
  --run-name bouncer-v1 \
  --model distilbert-base-cased \
  --epochs 4 --batch-size 16 --lr 5e-5 --warmup-ratio 0.1 \
  --loss weighted_ce --seed 42 --patience 2
```
Writes `../models/bouncer-v1/` (checkpoint, tokenizer, `report.json`).
If DEL_* classes are very rare, try `--loss focal --focal-gamma 2.0`.

### 2. Calibrate the DELETE threshold on val
```bash
../.venv/bin/python calibrate.py \
  --model-dir ../models/bouncer-v1 \
  --data ../data/val.jsonl \
  --target-precision 0.98
```
Writes `../models/bouncer-v1/threshold.json`. If `target_met` is `false`,
the model can't hit 0.98 precision at any threshold on val — do not ship;
retrain (more data / focal / more epochs).

### 3. Evaluate on gold (the only eval that counts)
```bash
../.venv/bin/python evaluate.py \
  --model-dir ../models/bouncer-v1 \
  --data ../data/gold.jsonl
```
Auto-loads the calibrated `threshold.json`. Report -> `eval-gold.md`.
**Ship gate:** binary DELETE precision >= 0.98 on gold AND the false-DELETE
section reads "None". Inspect every false-DELETE if any appear.

### Optional: verify calibration transfers val->gold
```bash
../.venv/bin/python calibrate.py --model-dir ../models/bouncer-v1 \
  --data ../data/gold.jsonl --no-write   # inspect gold curve without overwriting
```

## Notes / gotchas
- Device auto-selects MPS. Override with `--device cpu` if needed.
- Base model download is ~250 MB (first run only, cached in HF hub).
- Tokenizer must stay a fast WordPiece tokenizer (Core ML/Swift port later);
  train.py hard-fails on a slow tokenizer.
- A "newly initialized classifier weights" warning at model load is expected
  (the classification head is fresh) — not an error.
