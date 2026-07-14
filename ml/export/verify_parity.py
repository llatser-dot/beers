"""Verify the Core ML export makes the same KEEP/DELETE decisions as the
PyTorch checkpoint it was exported from.

For every example in fixture.jsonl + gold.jsonl we tokenize once (fixed 256,
pad/truncate — exactly what the app does), feed the identical token layout to
BOTH the eager PyTorch model and the exported Core ML model, extract the
first-subtoken logit of each word, softmax, and take the DELETE decision at the
bundled threshold (P(any DEL_*) >= t). Decisions must match on >= 99.5% of
words; a tiny per-logit epsilon (fp16 vs fp32) is expected and reported.

Run:
    python verify_parity.py --bundle ../models/bouncer-v1/export \
                            --model-dir ../models/bouncer-v1
Exit code 0 on pass, 1 on parity failure.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "train"))
from dataset import align_labels, load_records  # noqa: E402

REPO_ML = Path(__file__).resolve().parent.parent


def softmax(x: np.ndarray) -> np.ndarray:
    x = x - x.max(axis=-1, keepdims=True)
    e = np.exp(x)
    return e / e.sum(axis=-1, keepdims=True)


def first_subtoken_positions(word_ids: list[int], n_words: int) -> dict[int, int]:
    first: dict[int, int] = {}
    for pos, w in enumerate(word_ids):
        if w is not None and w >= 0 and w not in first:
            first[w] = pos
    return first


def word_del_probs(logits_row: np.ndarray, word_ids: list[int], n_words: int,
                   keep_id: int, del_ids: list[int]) -> list[float]:
    """P(any DEL_*) for each word using its first subtoken (KEEP if truncated)."""
    probs = softmax(logits_row.astype(np.float64))  # (T, C)
    first = first_subtoken_positions(word_ids, n_words)
    out = []
    for w in range(n_words):
        if w in first:
            out.append(float(sum(probs[first[w], i] for i in del_ids)))
        else:
            out.append(0.0)  # truncated -> confident KEEP
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bundle", default=str(REPO_ML / "models/bouncer-v1/export"))
    ap.add_argument("--model-dir", default=str(REPO_ML / "models/bouncer-v1"))
    ap.add_argument("--data", nargs="*", default=[
        str(REPO_ML / "train/fixture/fixture.jsonl"),
        str(REPO_ML / "data/gold.jsonl"),
    ])
    ap.add_argument("--seq-len", type=int, default=256)
    ap.add_argument("--min-agreement", type=float, default=0.995)
    args = ap.parse_args()

    import coremltools as ct
    from transformers import AutoModelForTokenClassification, AutoTokenizer

    bundle = Path(args.bundle)
    threshold = json.loads((bundle / "threshold.json").read_text())["threshold"]
    labels = json.loads((bundle / "labels.json").read_text())
    keep_id = labels["keep_id"]
    del_ids = labels["del_ids"]
    seq_len = args.seq_len
    print(f"[parity] threshold={threshold} keep_id={keep_id} del_ids={del_ids} seq_len={seq_len}")

    tokenizer = AutoTokenizer.from_pretrained(args.model_dir)
    pad_id = tokenizer.pad_token_id
    torch_model = AutoModelForTokenClassification.from_pretrained(
        args.model_dir, attn_implementation="eager").eval()
    mlmodel = ct.models.MLModel(str(bundle / "Bouncer.mlpackage"))

    records = []
    for path in args.data:
        recs = load_records(path)
        records.extend(recs)
        print(f"[parity] loaded {len(recs)} records from {path}")

    total_words = 0
    disagreements = 0
    max_del_prob_eps = 0.0
    diverge_examples = []

    for rec in records:
        dummy = [0] * len(rec.words)
        enc = align_labels(rec.words, dummy, tokenizer, max_length=seq_len, record_id=rec.id)
        ids = enc["input_ids"]
        word_ids = [None if w == -1 else w for w in enc["word_ids"]]
        n = len(ids)
        if n > seq_len:
            ids = ids[:seq_len]
            word_ids = word_ids[:seq_len]
            n = seq_len
        pad = seq_len - n
        input_ids = np.array([ids + [pad_id] * pad], dtype=np.int32)
        attn = np.array([[1] * n + [0] * pad], dtype=np.int32)

        with torch.no_grad():
            t_logits = torch_model(
                input_ids=torch.tensor(input_ids, dtype=torch.long),
                attention_mask=torch.tensor(attn, dtype=torch.long),
            ).logits[0].numpy()

        cm = mlmodel.predict({"input_ids": input_ids, "attention_mask": attn})
        c_logits = np.array(cm["logits"])[0]

        t_del = word_del_probs(t_logits, word_ids, len(rec.words), keep_id, del_ids)
        c_del = word_del_probs(c_logits, word_ids, len(rec.words), keep_id, del_ids)

        for w in range(len(rec.words)):
            total_words += 1
            eps = abs(t_del[w] - c_del[w])
            max_del_prob_eps = max(max_del_prob_eps, eps)
            t_dec = t_del[w] >= threshold
            c_dec = c_del[w] >= threshold
            if t_dec != c_dec:
                disagreements += 1
                diverge_examples.append(
                    f"  {rec.id} word[{w}]='{rec.words[w]}' torch_p={t_del[w]:.4f} "
                    f"coreml_p={c_del[w]:.4f} torch={'DEL' if t_dec else 'KEEP'} "
                    f"coreml={'DEL' if c_dec else 'KEEP'}")

    agree = (total_words - disagreements) / total_words if total_words else 1.0
    print(f"\n[parity] records={len(records)} words={total_words}")
    print(f"[parity] decision agreement = {agree*100:.3f}% "
          f"({total_words - disagreements}/{total_words})")
    print(f"[parity] max |P(DEL) torch - coreml| = {max_del_prob_eps:.6f}")
    if diverge_examples:
        print(f"[parity] {len(diverge_examples)} word-level decision divergence(s):")
        for line in diverge_examples[:50]:
            print(line)

    if agree >= args.min_agreement:
        print(f"[parity] PASS (>= {args.min_agreement*100:.1f}%)")
        sys.exit(0)
    else:
        print(f"[parity] FAIL (< {args.min_agreement*100:.1f}%)")
        sys.exit(1)


if __name__ == "__main__":
    main()
