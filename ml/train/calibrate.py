"""Calibrate the Bouncer DELETE decision threshold.

A word is deleted iff P(any DEL_*) >= t. This sweeps t across [0.5, 0.99],
computes the binary DELETE precision/recall at each t on the given data
(normally val.jsonl), and picks the LOWEST t that reaches precision >= target
(default 0.98 per DESIGN acceptance). Lowest-such-t maximises recall while
keeping precision sacred.

Writes threshold.json into the model dir:
    {"threshold": 0.87, "target_precision": 0.98, "achieved": {...}, ...}

If NO threshold reaches the target (even t=0.99), it records the best-precision
threshold and marks target_met=false -- the caller must not ship until this
passes on gold. (The model may also abstain: t=0.99 with all-KEEP is a safe
no-op pour.)
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from dataset import DEL_IDS
from infer import get_device, load_checkpoint, predict

DEL_ID_SET = set(DEL_IDS)


def sweep(preds, thresholds) -> list[dict]:
    rows = []
    for t in thresholds:
        tp = fp = fn = 0
        for wp in preds:
            if len(wp.gold) != len(wp.words):
                continue
            gold_del = [g in DEL_ID_SET for g in wp.gold]
            for i, dp in enumerate(wp.del_prob):
                pred_del = dp >= t
                if pred_del and gold_del[i]:
                    tp += 1
                elif pred_del and not gold_del[i]:
                    fp += 1
                elif not pred_del and gold_del[i]:
                    fn += 1
        p = tp / (tp + fp) if (tp + fp) else 1.0  # no deletions -> vacuously precise
        r = tp / (tp + fn) if (tp + fn) else 0.0
        f = 2 * p * r / (p + r) if (p + r) else 0.0
        rows.append({"t": round(t, 3), "precision": p, "recall": r, "f1": f,
                     "tp": tp, "fp": fp, "fn": fn})
    return rows


def choose(rows, target: float) -> tuple[dict | None, bool]:
    """Lowest t with precision >= target (and at least one true positive so it
    isn't the vacuous all-KEEP point). Falls back to best precision."""
    qualifying = [r for r in rows if r["precision"] >= target and r["tp"] > 0]
    if qualifying:
        return min(qualifying, key=lambda r: r["t"]), True
    # allow the safe abstain point (no deletions at all) only if nothing else works
    abstain = [r for r in rows if r["tp"] + r["fp"] == 0]
    if not rows:
        return None, False
    best = max(rows, key=lambda r: (r["precision"], r["recall"]))
    if abstain and best["precision"] < target:
        return min(abstain, key=lambda r: r["t"]), False
    return best, False


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--data", required=True, help="JSONL to calibrate on (usually val.jsonl)")
    ap.add_argument("--target-precision", type=float, default=0.98)
    ap.add_argument("--lo", type=float, default=0.5)
    ap.add_argument("--hi", type=float, default=0.99)
    ap.add_argument("--step", type=float, default=0.01)
    ap.add_argument("--batch-size", type=int, default=16)
    ap.add_argument("--write", action="store_true", default=True,
                    help="write threshold.json into model dir (default on)")
    ap.add_argument("--no-write", dest="write", action="store_false")
    args = ap.parse_args()

    device = get_device()
    print(f"[calib] device={device}")
    model, tokenizer = load_checkpoint(args.model_dir)
    preds = predict(model, tokenizer, args.data, device=device, batch_size=args.batch_size)

    n = int(round((args.hi - args.lo) / args.step)) + 1
    thresholds = [round(args.lo + i * args.step, 4) for i in range(n)]
    rows = sweep(preds, thresholds)
    chosen, met = choose(rows, args.target_precision)

    print(f"[calib]   t    prec   recall   f1    (tp/fp/fn)")
    for r in rows:
        mark = " <-- chosen" if chosen and r["t"] == chosen["t"] else ""
        print(f"[calib] {r['t']:.2f}  {r['precision']:.3f}  {r['recall']:.3f}  "
              f"{r['f1']:.3f}   ({r['tp']}/{r['fp']}/{r['fn']}){mark}")

    result = {
        "threshold": chosen["t"] if chosen else args.hi,
        "target_precision": args.target_precision,
        "target_met": met,
        "achieved": chosen,
        "data": args.data,
        "curve": rows,
    }
    if not met:
        print(f"[calib] WARNING: precision target {args.target_precision} NOT met "
              f"on {args.data}; chose t={result['threshold']} "
              f"(precision={chosen['precision'] if chosen else 0:.3f}). Do not ship.")
    else:
        print(f"[calib] chosen threshold={result['threshold']} "
              f"(precision={chosen['precision']:.3f} recall={chosen['recall']:.3f})")

    if args.write:
        out = Path(args.model_dir) / "threshold.json"
        out.write_text(json.dumps(result, indent=2))
        print(f"[calib] wrote {out}")


if __name__ == "__main__":
    main()
