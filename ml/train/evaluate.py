"""Evaluate a Bouncer checkpoint on any contract-JSONL.

Reports:
  * per-class precision / recall / F1 (KEEP + each DEL_* subtype)
  * binary DELETE precision / recall / F1 (all DEL_* collapsed) -- the number
    that gates shipping (DESIGN acceptance: DELETE precision >= 0.98 on gold)
  * transcript-level exact-match on the KEEP/DELETE decision sequence
  * a FALSE-DELETE failure dump: every transcript where the model deleted a
    word that gold says KEEP, with the wrongly-deleted words highlighted.
    These are precision violations -- the only errors that can hurt a pour.

Decision threshold: a word is DELETEd iff P(any DEL_*) >= t. If --threshold
is not given, uses threshold.json in the model dir, else falls back to argmax.

Writes a Markdown report (and prints a summary).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from dataset import DEL_IDS, ID2LABEL, KEEP_ID, LABELS, NUM_LABELS
from infer import get_device, load_checkpoint, predict

DEL_ID_SET = set(DEL_IDS)


def _prf(tp: int, fp: int, fn: int) -> tuple[float, float, float]:
    p = tp / (tp + fp) if (tp + fp) else 0.0
    r = tp / (tp + fn) if (tp + fn) else 0.0
    f = 2 * p * r / (p + r) if (p + r) else 0.0
    return p, r, f


def evaluate(preds, threshold: float) -> dict:
    argmax_mode = threshold is None
    # per-class confusion (against thresholded/argmax predictions)
    per_class = {i: {"tp": 0, "fp": 0, "fn": 0} for i in range(NUM_LABELS)}
    d_tp = d_fp = d_fn = 0
    exact = 0
    failures = []  # list of dicts for false-DELETE transcripts

    for wp in preds:
        pred_ids = wp.argmax_labels() if argmax_mode else wp.threshold_labels(threshold)
        gold = wp.gold
        has_gold = len(gold) == len(wp.words)

        # binary decision sequences
        pred_del = [pid in DEL_ID_SET for pid in pred_ids]
        if has_gold:
            gold_del = [gid in DEL_ID_SET for gid in gold]
            if pred_del == gold_del:
                exact += 1
            false_del_idx = [i for i in range(len(gold))
                             if pred_del[i] and not gold_del[i]]
            for i in range(len(gold)):
                # per-class multi-way confusion
                pi, gi = pred_ids[i], gold[i]
                if pi == gi:
                    per_class[gi]["tp"] += 1
                else:
                    per_class[pi]["fp"] += 1
                    per_class[gi]["fn"] += 1
                # binary DELETE confusion
                if pred_del[i] and gold_del[i]:
                    d_tp += 1
                elif pred_del[i] and not gold_del[i]:
                    d_fp += 1
                elif not pred_del[i] and gold_del[i]:
                    d_fn += 1
            if false_del_idx:
                failures.append({
                    "id": wp.id,
                    "words": wp.words,
                    "false_del_idx": false_del_idx,
                    "pred_ids": pred_ids,
                    "del_prob": wp.del_prob,
                })

    n = len(preds)
    d_p, d_r, d_f = _prf(d_tp, d_fp, d_fn)
    per_class_out = {}
    for i in range(NUM_LABELS):
        c = per_class[i]
        p, r, f = _prf(c["tp"], c["fp"], c["fn"])
        per_class_out[ID2LABEL[i]] = {
            "precision": p, "recall": r, "f1": f,
            "tp": c["tp"], "fp": c["fp"], "fn": c["fn"],
        }
    return {
        "n_transcripts": n,
        "threshold": "argmax" if argmax_mode else threshold,
        "delete_binary": {
            "precision": d_p, "recall": d_r, "f1": d_f,
            "tp": d_tp, "fp": d_fp, "fn": d_fn,
        },
        "per_class": per_class_out,
        "exact_match": exact / n if n else 0.0,
        "exact_match_count": exact,
        "failures": failures,
    }


def render_markdown(res: dict, model_dir: str, data_path: str) -> str:
    L = []
    L.append(f"# Bouncer evaluation report\n")
    L.append(f"- model: `{model_dir}`")
    L.append(f"- data: `{data_path}`")
    L.append(f"- transcripts: {res['n_transcripts']}")
    L.append(f"- DELETE threshold: `{res['threshold']}`\n")

    db = res["delete_binary"]
    gate = "PASS" if db["precision"] >= 0.98 else "FAIL"
    L.append("## Binary DELETE (all DEL_* collapsed) -- shipping gate\n")
    L.append(f"**Precision {db['precision']:.4f}** (acceptance >= 0.98 -> {gate}) | "
             f"Recall {db['recall']:.4f} | F1 {db['f1']:.4f}")
    L.append(f"\ntp={db['tp']} fp={db['fp']} fn={db['fn']}\n")

    L.append("## Per-class\n")
    L.append("| label | precision | recall | f1 | tp | fp | fn |")
    L.append("|---|---|---|---|---|---|---|")
    for lab in LABELS:
        c = res["per_class"][lab]
        L.append(f"| {lab} | {c['precision']:.3f} | {c['recall']:.3f} | "
                 f"{c['f1']:.3f} | {c['tp']} | {c['fp']} | {c['fn']} |")
    L.append("")

    L.append(f"## Transcript exact-match (KEEP/DELETE sequence)\n")
    L.append(f"{res['exact_match_count']}/{res['n_transcripts']} "
             f"= {res['exact_match']:.3f}\n")

    L.append("## FALSE-DELETE failures (precision violations)\n")
    if not res["failures"]:
        L.append("_None. No real content was deleted._\n")
    else:
        L.append(f"{len(res['failures'])} transcript(s) with >=1 false DELETE. "
                 f"Wrongly-deleted words are wrapped in >>...<<.\n")
        for f in res["failures"]:
            bad = set(f["false_del_idx"])
            rendered = " ".join(
                (f">>{w}<<" if i in bad else w) for i, w in enumerate(f["words"])
            )
            probs = ", ".join(f"'{f['words'][i]}'@{f['del_prob'][i]:.2f}"
                              for i in f["false_del_idx"])
            L.append(f"- **{f['id']}**: {rendered}")
            L.append(f"  - deleted: {probs}")
        L.append("")
    return "\n".join(L)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--data", required=True, help="contract JSONL to evaluate on")
    ap.add_argument("--threshold", type=float, default=None,
                    help="DELETE prob threshold; default reads threshold.json or argmax")
    ap.add_argument("--out", default=None, help="markdown report path (default: model-dir/eval-<stem>.md)")
    ap.add_argument("--batch-size", type=int, default=16)
    args = ap.parse_args()

    threshold = args.threshold
    if threshold is None:
        tj = Path(args.model_dir) / "threshold.json"
        if tj.exists():
            threshold = json.loads(tj.read_text())["threshold"]
            print(f"[eval] using calibrated threshold={threshold} from {tj}")
        else:
            print("[eval] no threshold given/found -> using argmax decision")

    device = get_device()
    print(f"[eval] device={device}")
    model, tokenizer = load_checkpoint(args.model_dir)
    preds = predict(model, tokenizer, args.data, device=device, batch_size=args.batch_size)
    res = evaluate(preds, threshold)

    md = render_markdown(res, args.model_dir, args.data)
    stem = Path(args.data).stem
    out = Path(args.out) if args.out else Path(args.model_dir) / f"eval-{stem}.md"
    out.write_text(md)

    db = res["delete_binary"]
    print(f"[eval] DELETE precision={db['precision']:.4f} recall={db['recall']:.4f} "
          f"f1={db['f1']:.4f} | exact={res['exact_match']:.3f} | "
          f"false-deletes in {len(res['failures'])} transcripts")
    print(f"[eval] report -> {out}")


if __name__ == "__main__":
    main()
