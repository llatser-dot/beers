"""Export a HF token-classification checkpoint to a Core ML .mlpackage bundle.

Produces an ANE-eligible, fixed-length (256) token classifier that emits
per-token logits, plus everything the Swift tier-0 Bouncer needs to run it:

    <out>/
      Bouncer.mlpackage      fp16 weights, compute_units=ALL, seq len 256
      vocab.txt              WordPiece vocab (for the pure-Swift tokenizer)
      threshold.json         calibrated DELETE threshold + the GOLD ship gate
      labels.json            id2label (so Swift never hard-codes the scheme)
      export-manifest.json   provenance: base model, shapes, sizes, timings

The bundled threshold.json is NOT a verbatim copy. calibrate.py sets
`target_met` from the VALIDATION sweep; DESIGN.md's actual ship gate is DELETE
precision on gold.jsonl. So this script re-evaluates the checkpoint on gold and
overwrites `target_met` with the honest gold-gate result. That makes tier-0
activation ("target_met == true") a genuine file-swap: the current stand-in
fails gold -> target_met:false -> app stays in shadow; a v2 that passes gold
-> target_met:true -> app activates, no code change.

CLI:
    export_coreml.py --model-dir ../models/bouncer-v1 --out ../models/bouncer-v1/export/
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from pathlib import Path

import numpy as np
import torch

# Reuse the training harness' gold-gate logic so the number in the bundle is
# exactly the number evaluate.py reports.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "train"))
from dataset import DEL_IDS, ID2LABEL, KEEP_ID, NUM_LABELS  # noqa: E402
from infer import load_checkpoint, predict  # noqa: E402

SEQ_LEN = 256
DEL_ID_SET = set(DEL_IDS)


class TokenClassifierWrapper(torch.nn.Module):
    """Trace-friendly wrapper: fixed-shape int32 inputs -> float logits.

    Core ML prefers int32 tensors; DistilBert's embedding wants int64, so we
    cast inside. Output is the raw per-token logits (B, T, num_labels); softmax
    happens in Swift so the exported graph stays a pure encoder+head.
    """

    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        out = self.model(
            input_ids=input_ids.to(torch.long),
            attention_mask=attention_mask.to(torch.long),
        )
        return out.logits


def _dir_size_bytes(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def gold_gate(model, tokenizer, gold_path: Path, threshold: float, target_precision: float) -> dict:
    """Binary DELETE precision/recall on gold at `threshold` (the ship gate)."""
    preds = predict(model, tokenizer, str(gold_path), device=torch.device("cpu"))
    tp = fp = fn = 0
    for wp in preds:
        if len(wp.gold) != len(wp.words):
            continue
        gold_del = [g in DEL_ID_SET for g in wp.gold]
        for i, dp in enumerate(wp.del_prob):
            pred_del = dp >= threshold
            if pred_del and gold_del[i]:
                tp += 1
            elif pred_del and not gold_del[i]:
                fp += 1
            elif not pred_del and gold_del[i]:
                fn += 1
    precision = tp / (tp + fp) if (tp + fp) else 1.0
    recall = tp / (tp + fn) if (tp + fn) else 0.0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0
    return {
        "data": str(gold_path),
        "threshold": threshold,
        "target_precision": target_precision,
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "met": precision >= target_precision and tp > 0,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model-dir", required=True, help="HF token-classification checkpoint dir")
    ap.add_argument("--out", required=True, help="output bundle dir")
    ap.add_argument("--seq-len", type=int, default=SEQ_LEN)
    ap.add_argument("--gold", default=None,
                    help="gold JSONL for the ship gate (default: <model-dir>/../../data/gold.jsonl)")
    ap.add_argument("--skip-gold", action="store_true",
                    help="don't re-evaluate the gold gate; copy threshold.json verbatim")
    args = ap.parse_args()

    import coremltools as ct
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch.torch_op_registry import (
        register_torch_op,
        _TORCH_OPS_REGISTRY,
    )
    from coremltools.converters.mil.frontend.torch.ops import _get_inputs

    # transformers 5.x builds the attention base mask via `q_idx.new_ones(...)`
    # (masking_utils.py) — an all-True tensor later AND-ed with the padding mask.
    # coremltools has no lowering for `new_ones`, so provide one: a fill of the
    # requested shape. Padding is preserved because it flows through separate
    # ops built from attention_mask.
    # torch ScalarType code -> Core ML dtype string
    _TORCH_DTYPE = {2: "int16", 3: "int32", 4: "int32", 5: "fp16",
                    6: "fp32", 7: "fp32", 11: "bool"}

    if "new_ones" not in _TORCH_OPS_REGISTRY.name_to_func_mapping:
        @register_torch_op
        def new_ones(context, node):
            import numpy as _np
            inputs = _get_inputs(context, node)
            size = inputs[1]
            dtype_code = inputs[2].val if len(inputs) > 2 and inputs[2].val is not None else 6
            out_dtype = _TORCH_DTYPE.get(int(dtype_code), "fp32")
            if size.val is not None:
                shp = _np.array(size.val, dtype=_np.int32).reshape(-1)
                if shp.size == 0:  # new_ones(()) -> scalar 1
                    res = mb.const(val=1.0, name=node.name + "_one")
                else:
                    res = mb.fill(shape=shp, value=1.0, name=node.name + "_fill")
            else:  # dynamic shape
                res = mb.fill(shape=mb.cast(x=size, dtype="int32"), value=1.0,
                              name=node.name + "_fill")
            res = mb.cast(x=res, dtype=out_dtype, name=node.name)
            context.add(res)

    model_dir = Path(args.model_dir).resolve()
    out_dir = Path(args.out).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    seq_len = args.seq_len

    print(f"[export] loading checkpoint {model_dir}")
    model, tokenizer = load_checkpoint(str(model_dir))
    model.eval()

    # The default SDPA attention path emits `new_ones` (mask prep) which has no
    # Core ML lowering. Eager attention is numerically identical for inference
    # and traces cleanly. Load a separate eager copy purely for tracing; the
    # original `model` still drives the gold-gate eval below.
    from transformers import AutoModelForTokenClassification
    trace_model = AutoModelForTokenClassification.from_pretrained(
        str(model_dir), attn_implementation="eager"
    ).eval()

    num_labels = model.config.num_labels
    id2label = {int(i): model.config.id2label[i] for i in sorted(model.config.id2label, key=int)} \
        if isinstance(model.config.id2label, dict) else {i: l for i, l in enumerate(model.config.id2label)}

    # --- trace -------------------------------------------------------------
    wrapper = TokenClassifierWrapper(trace_model).eval()
    example_ids = torch.randint(0, model.config.vocab_size, (1, seq_len), dtype=torch.int32)
    example_mask = torch.ones((1, seq_len), dtype=torch.int32)
    print(f"[export] tracing at fixed seq_len={seq_len}")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (example_ids, example_mask), strict=False)

    # --- convert -----------------------------------------------------------
    print("[export] converting to Core ML (fp16, compute_units=ALL)")
    t0 = time.time()
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, seq_len), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, seq_len), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="logits")],
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    convert_sec = time.time() - t0

    mlmodel.short_description = (
        "Bouncer disfluency tagger — per-token KEEP/DEL_* logits. "
        f"Base: {model.config.model_type}. Seq len {seq_len}."
    )
    mlmodel.input_description["input_ids"] = "WordPiece token ids, [CLS]..[SEP] padded to seq len"
    mlmodel.input_description["attention_mask"] = "1 for real tokens, 0 for [PAD]"
    mlmodel.output_description["logits"] = f"Per-token logits, shape (1, {seq_len}, {num_labels})"
    mlmodel.user_defined_metadata["labels"] = json.dumps(id2label)
    mlmodel.user_defined_metadata["seq_len"] = str(seq_len)

    pkg_path = out_dir / "Bouncer.mlpackage"
    if pkg_path.exists():
        shutil.rmtree(pkg_path)
    mlmodel.save(str(pkg_path))
    pkg_bytes = _dir_size_bytes(pkg_path)
    print(f"[export] wrote {pkg_path} ({pkg_bytes/1e6:.1f} MB) in {convert_sec:.1f}s")

    # --- vocab.txt (WordPiece, index order) --------------------------------
    vocab = tokenizer.get_vocab()  # token -> id
    ordered = sorted(vocab.items(), key=lambda kv: kv[1])
    # sanity: ids must be contiguous 0..N-1
    assert [i for _, i in ordered] == list(range(len(ordered))), "vocab ids not contiguous"
    vocab_path = out_dir / "vocab.txt"
    vocab_path.write_text("\n".join(tok for tok, _ in ordered) + "\n", encoding="utf-8")
    print(f"[export] wrote {vocab_path} ({len(ordered)} tokens)")

    # --- labels.json -------------------------------------------------------
    labels_path = out_dir / "labels.json"
    labels_path.write_text(json.dumps({
        "id2label": {str(k): v for k, v in id2label.items()},
        "keep_id": KEEP_ID,
        "del_ids": DEL_IDS,
        "num_labels": num_labels,
    }, indent=2), encoding="utf-8")
    print(f"[export] wrote {labels_path}")

    # --- threshold.json (with the HONEST gold gate) ------------------------
    src_threshold = model_dir / "threshold.json"
    tj = json.loads(src_threshold.read_text()) if src_threshold.exists() else {
        "threshold": 0.98, "target_precision": 0.98,
    }
    threshold = float(tj.get("threshold", 0.98))
    target_precision = float(tj.get("target_precision", 0.98))

    if not args.skip_gold:
        gold_path = Path(args.gold) if args.gold else (model_dir.parent.parent / "data" / "gold.jsonl")
        if gold_path.exists():
            print(f"[export] evaluating GOLD ship gate on {gold_path}")
            g = gold_gate(model, tokenizer, gold_path, threshold, target_precision)
            print(f"[export] gold DELETE precision={g['precision']:.4f} "
                  f"recall={g['recall']:.4f} (tp={g['tp']} fp={g['fp']} fn={g['fn']}) "
                  f"-> gate {'PASS' if g['met'] else 'FAIL'}")
            tj["target_met_val"] = tj.get("target_met")  # preserve the val-based flag
            tj["target_met"] = bool(g["met"])            # authoritative = gold gate
            tj["gold_gate"] = g
        else:
            print(f"[export] WARNING: gold not found at {gold_path}; keeping val target_met, "
                  f"forcing target_met=false for safety")
            tj["target_met_val"] = tj.get("target_met")
            tj["target_met"] = False
            tj["gold_gate"] = {"evaluated": False, "reason": f"gold not found: {gold_path}"}

    out_threshold = out_dir / "threshold.json"
    out_threshold.write_text(json.dumps(tj, indent=2), encoding="utf-8")
    print(f"[export] wrote {out_threshold} (target_met={tj.get('target_met')})")

    # --- manifest ----------------------------------------------------------
    manifest = {
        "base_model": model.config._name_or_path if hasattr(model.config, "_name_or_path") else model.config.model_type,
        "model_type": model.config.model_type,
        "seq_len": seq_len,
        "num_labels": num_labels,
        "id2label": {str(k): v for k, v in id2label.items()},
        "vocab_size": len(ordered),
        "inputs": ["input_ids:int32(1,%d)" % seq_len, "attention_mask:int32(1,%d)" % seq_len],
        "output": "logits:float(1,%d,%d)" % (seq_len, num_labels),
        "compute_precision": "float16",
        "compute_units": "ALL",
        "minimum_deployment_target": "macOS14",
        "mlpackage_bytes": pkg_bytes,
        "convert_seconds": round(convert_sec, 2),
        "threshold": threshold,
        "target_met": tj.get("target_met"),
        "coremltools": ct.__version__,
        "exported_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    (out_dir / "export-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"[export] wrote {out_dir/'export-manifest.json'}")
    print(f"[export] DONE -> {out_dir}")


if __name__ == "__main__":
    main()
