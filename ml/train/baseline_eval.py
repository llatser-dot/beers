"""Evaluate an off-the-shelf HF disfluency token-classification model against
our gold.jsonl, on the SAME binary-DELETE metrics as evaluate.py.

Their label schemes differ from ours (BIO edit tags, binary fluent/disfluent,
etc). We inspect config.id2label, map ANY label that indicates
disfluent / edited / to-be-removed -> our binary DELETE, align their subword
predictions back to words (first-subtoken rule), and compute:
  * binary DELETE precision / recall / F1 (vs our gold DEL_* collapsed)
  * transcript-level exact-match on the KEEP/DELETE sequence
  * a false-DELETE dump: every wrongly-deleted real word, verbatim.

Judged at raw argmax (no threshold calibration) -- that's how they ship.

Usage:
  baseline_eval.py --model DD0101/disfluency-base --data ../data/gold.jsonl
  baseline_eval.py --model X --data D --delete-ids 1,2   # override auto-map
  baseline_eval.py --model X --data D --probe            # just dump id2label
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import torch
from transformers import AutoModelForTokenClassification, AutoTokenizer

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dataset import DEL_IDS, LABEL2ID, load_records  # noqa: E402

OUR_DEL_IDS = set(DEL_IDS)

# Label strings (lowercased) that unambiguously mean KEEP / fluent / outside.
KEEP_EXACT = {"o", "0", "keep", "fluent", "fluency", "regular", "f", "clean",
              "non-disfluent", "nondisfluent", "not_disfluent", "normal"}
# Substrings that indicate a disfluent / editable / removable token -> DELETE.
DELETE_SUBSTR = ["disf", "edit", "repar", "filler", "interreg", "repeat",
                 "reset", "restart", "remove", "delete", "correct",
                 "false_start", "falsestart"]
# Standard disfluency-annotation abbreviations (core token, BIO prefix stripped)
# that all denote a token to be removed:
#   rm=reparandum removed, im=interregnum, e=edit, d=disfluent
#   fp=filled pause, rp=repetition, rv=revision, pw=partial word,
#   fs=false start, uh/um=fillers
DELETE_ABBR = {"rm", "im", "e", "d", "fp", "rp", "rv", "pw", "fs",
               "uh", "um", "disfluent", "edit"}


def is_delete_label(label: str) -> bool:
    """Heuristic: does this foreign label mean 'remove this token'?"""
    s = str(label).strip().lower()
    if s in KEEP_EXACT:
        return False
    if any(k in s for k in DELETE_SUBSTR):
        return True
    # strip a BIO prefix (b-, i-, b_, i_, or bare leading b/i) then match the core
    core = s
    for pre in ("b-", "i-", "b_", "i_"):
        if core.startswith(pre):
            core = core[len(pre):]
            break
    else:
        if len(s) > 1 and s[0] in "bi" and s[1:] in DELETE_ABBR:
            core = s[1:]
    if core in DELETE_ABBR:
        return True
    return False


def get_device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def _prf(tp, fp, fn):
    p = tp / (tp + fp) if (tp + fp) else 0.0
    r = tp / (tp + fn) if (tp + fn) else 0.0
    f = 2 * p * r / (p + r) if (p + r) else 0.0
    return p, r, f


def load_tokenizer_robust(model_id: str):
    """Load a tokenizer, working around the transformers>=5 PhoBERT
    'add_special_tokens conflicts with the method' crash by stripping that
    stray key from a local copy of tokenizer_config.json."""
    try:
        return AutoTokenizer.from_pretrained(model_id)
    except AttributeError as e:
        if "add_special_tokens conflicts" not in str(e):
            raise
        import json as _json
        import shutil
        import tempfile

        from huggingface_hub import snapshot_download
        snap = snapshot_download(model_id)
        tmp = tempfile.mkdtemp(prefix="tokfix-")
        for f in os.listdir(snap):
            src = os.path.join(snap, f)
            if os.path.isfile(src):
                shutil.copy(src, os.path.join(tmp, f))
        tc = os.path.join(tmp, "tokenizer_config.json")
        cfg = _json.load(open(tc))
        cfg.pop("add_special_tokens", None)
        _json.dump(cfg, open(tc, "w"))
        print(f"[base] patched tokenizer_config (dropped add_special_tokens) -> {tmp}")
        return AutoTokenizer.from_pretrained(tmp)


def _slow_align_pred(tok, model, words, del_ids, device, max_length=512):
    """First-subtoken prediction per word for a SLOW tokenizer (no word_ids):
    tokenize each word alone, concatenate with the model's special tokens,
    track each word's first-subtoken index manually."""
    import os as _os  # noqa
    bos = tok.bos_token_id if tok.bos_token_id is not None else tok.cls_token_id
    eos = tok.eos_token_id if tok.eos_token_id is not None else tok.sep_token_id
    unk = tok.unk_token_id if tok.unk_token_id is not None else 0
    ids = [] if bos is None else [bos]
    first_pos = {}
    for wi, w in enumerate(words):
        wp = tok.encode(w, add_special_tokens=False)
        if not wp:
            wp = [unk]
        if len(ids) + len(wp) >= max_length - 1:
            break  # rest truncated
        first_pos[wi] = len(ids)
        ids.extend(wp)
    if eos is not None:
        ids.append(eos)
    input_ids = torch.tensor([ids], device=device)
    attn = torch.ones_like(input_ids)
    logits = model(input_ids=input_ids, attention_mask=attn).logits
    pred = logits.argmax(-1)[0].cpu().tolist()
    pred_del = []
    for wi in range(len(words)):
        if wi in first_pos:
            pred_del.append(pred[first_pos[wi]] in del_ids)
        else:
            pred_del.append(False)  # truncated -> no-op KEEP
    truncated = len(first_pos) < len(words)
    return pred_del, truncated


@torch.no_grad()
def run(model_id: str, data_path: str, delete_ids_override, out_path, batch_size=16):
    print(f"[base] loading {model_id}")
    tok = load_tokenizer_robust(model_id)
    model = AutoModelForTokenClassification.from_pretrained(model_id)
    id2label = model.config.id2label
    print(f"[base] id2label = {id2label}")
    n_params = sum(p.numel() for p in model.parameters())

    if delete_ids_override is not None:
        del_ids = set(delete_ids_override)
    else:
        del_ids = {i for i, lab in id2label.items() if is_delete_label(lab)}
    keep_map = {i: ("DELETE" if i in del_ids else "KEEP") for i in id2label}
    print(f"[base] auto-map -> DELETE ids {sorted(del_ids)} : "
          f"{ {id2label[i]: keep_map[i] for i in id2label} }")
    if not del_ids:
        print("[base] WARNING: no DELETE label detected -- model will KEEP everything.")

    align_mode = "fast/word_ids" if tok.is_fast else "slow/per-word"
    print(f"[base] tokenizer={type(tok).__name__} is_fast={tok.is_fast} "
          f"align={align_mode}")

    device = get_device()
    model.to(device).eval()

    records = load_records(data_path)

    d_tp = d_fp = d_fn = 0
    exact = 0
    failures = []
    truncated = 0

    for rec in records:
        if tok.is_fast:
            enc = tok(rec.words, is_split_into_words=True, truncation=True,
                      max_length=512, return_tensors="pt")
            word_ids = enc.word_ids()
            logits = model(input_ids=enc["input_ids"].to(device),
                           attention_mask=enc["attention_mask"].to(device)).logits
            pred = logits.argmax(-1)[0].cpu().tolist()
            first_pos = {}
            for pos, w in enumerate(word_ids):
                if w is not None and w not in first_pos:
                    first_pos[w] = pos
            pred_del = []
            for wi in range(len(rec.words)):
                if wi in first_pos:
                    pred_del.append(pred[first_pos[wi]] in del_ids)
                else:
                    pred_del.append(False)
            if len(first_pos) < len(rec.words):
                truncated += 1
        else:
            pred_del, was_trunc = _slow_align_pred(
                tok, model, rec.words, del_ids, device)
            if was_trunc:
                truncated += 1

        gold_del = [LABEL2ID[l] in OUR_DEL_IDS for l in rec.labels]

        if pred_del == gold_del:
            exact += 1
        false_idx = [i for i in range(len(gold_del)) if pred_del[i] and not gold_del[i]]
        for i in range(len(gold_del)):
            if pred_del[i] and gold_del[i]:
                d_tp += 1
            elif pred_del[i] and not gold_del[i]:
                d_fp += 1
            elif not pred_del[i] and gold_del[i]:
                d_fn += 1
        if false_idx:
            failures.append({"id": rec.id, "words": rec.words, "false_del_idx": false_idx})

    p, r, f = _prf(d_tp, d_fp, d_fn)
    n = len(records)
    res = {
        "model": model_id,
        "params": n_params,
        "id2label": {str(k): v for k, v in id2label.items()},
        "delete_ids": sorted(del_ids),
        "delete_binary": {"precision": p, "recall": r, "f1": f,
                          "tp": d_tp, "fp": d_fp, "fn": d_fn},
        "exact_match": exact / n if n else 0.0,
        "exact_match_count": exact,
        "n_transcripts": n,
        "truncated_transcripts": truncated,
        "failures": failures,
    }

    print(f"[base] {model_id}: params={n_params/1e6:.1f}M "
          f"DELETE P={p:.4f} R={r:.4f} F1={f:.4f} "
          f"exact={res['exact_match']:.3f} ({exact}/{n}) "
          f"false-del transcripts={len(failures)} (tp={d_tp} fp={d_fp} fn={d_fn})")

    # false-delete dump
    if failures:
        print(f"[base] FALSE-DELETE dump ({len(failures)} transcripts):")
        for fl in failures:
            bad = set(fl["false_del_idx"])
            rendered = " ".join((f">>{w}<<" if i in bad else w)
                                for i, w in enumerate(fl["words"]))
            words_del = [fl["words"][i] for i in fl["false_del_idx"]]
            print(f"  - {fl['id']}: {rendered}")
            print(f"      wrongly deleted: {words_del}")
    else:
        print("[base] FALSE-DELETE dump: None")

    if out_path:
        Path(out_path).write_text(json.dumps(res, indent=2))
        print(f"[base] wrote {out_path}")
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--delete-ids", default=None,
                    help="comma-sep label ids to treat as DELETE (override auto-map)")
    ap.add_argument("--out", default=None)
    ap.add_argument("--probe", action="store_true", help="just print id2label and exit")
    args = ap.parse_args()

    if args.probe:
        model = AutoModelForTokenClassification.from_pretrained(args.model)
        print(json.dumps({str(k): v for k, v in model.config.id2label.items()}, indent=2))
        return

    override = None
    if args.delete_ids:
        override = [int(x) for x in args.delete_ids.split(",") if x.strip() != ""]
    run(args.model, args.data, override, args.out)


if __name__ == "__main__":
    main()
