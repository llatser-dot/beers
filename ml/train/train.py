"""Fine-tune distilbert-base-cased as a Bouncer disfluency token-tagger on MPS.

Custom training loop (readable, no Trainer sprawl) with:
  * weighted cross-entropy OR focal loss (for rare DEL_* classes)
  * linear warmup + decay schedule
  * early stopping on validation binary DELETE-F1
  * seed control, MPS/CPU auto-select
  * saves checkpoint + tokenizer + report.json to models/<run-name>/

Example (tiny, for smoke test):
  python train.py --train fixture/fixture.jsonl --val fixture/fixture.jsonl \
      --run-name smoke --epochs 1 --batch-size 4 --model distilbert-base-cased
"""

from __future__ import annotations

import argparse
import json
import random
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader
from transformers import (
    AutoModelForTokenClassification,
    AutoTokenizer,
    get_linear_schedule_with_warmup,
)

from dataset import (
    DEL_IDS,
    ID2LABEL,
    IGNORE_INDEX,
    LABEL2ID,
    NUM_LABELS,
    Collator,
    DisfluencyDataset,
    compute_class_weights,
)
from infer import get_device

DEL_ID_SET = set(DEL_IDS)


def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.backends.mps.is_available():
        torch.mps.manual_seed(seed)


def focal_loss(logits, targets, weight, gamma: float) -> torch.Tensor:
    """Multi-class focal loss with -100 ignore + optional class weights."""
    logits = logits.view(-1, logits.size(-1))
    targets = targets.view(-1)
    mask = targets != IGNORE_INDEX
    if mask.sum() == 0:
        return logits.sum() * 0.0
    logits, targets = logits[mask], targets[mask]
    logp = F.log_softmax(logits, dim=-1)
    logpt = logp.gather(1, targets.unsqueeze(1)).squeeze(1)
    pt = logpt.exp()
    loss = -((1 - pt) ** gamma) * logpt
    if weight is not None:
        loss = loss * weight[targets]
    return loss.mean()


@torch.no_grad()
def eval_delete_f1(model, loader, device) -> dict:
    """Binary DELETE precision/recall/F1 at argmax (all DEL_* collapsed),
    over first-subtoken positions (labels != -100)."""
    model.eval()
    tp = fp = fn = tn = 0
    for batch in loader:
        input_ids = batch["input_ids"].to(device)
        attn = batch["attention_mask"].to(device)
        labels = batch["labels"]
        logits = model(input_ids=input_ids, attention_mask=attn).logits.cpu()
        preds = logits.argmax(-1)
        for p_row, l_row in zip(preds, labels):
            for p, l in zip(p_row.tolist(), l_row.tolist()):
                if l == IGNORE_INDEX:
                    continue
                pred_del = p in DEL_ID_SET
                gold_del = l in DEL_ID_SET
                if pred_del and gold_del:
                    tp += 1
                elif pred_del and not gold_del:
                    fp += 1
                elif not pred_del and gold_del:
                    fn += 1
                else:
                    tn += 1
    prec = tp / (tp + fp) if (tp + fp) else 0.0
    rec = tp / (tp + fn) if (tp + fn) else 0.0
    f1 = 2 * prec * rec / (prec + rec) if (prec + rec) else 0.0
    return {"precision": prec, "recall": rec, "f1": f1,
            "tp": tp, "fp": fp, "fn": fn, "tn": tn}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--train", required=True, help="train JSONL (contract)")
    ap.add_argument("--val", required=True, help="validation JSONL (contract)")
    ap.add_argument("--model", default="distilbert-base-cased")
    ap.add_argument("--run-name", default="bouncer")
    ap.add_argument("--out-root", default=str(Path(__file__).resolve().parent.parent / "models"))
    ap.add_argument("--epochs", type=int, default=4)
    ap.add_argument("--batch-size", type=int, default=16)
    ap.add_argument("--lr", type=float, default=5e-5)
    ap.add_argument("--warmup-ratio", type=float, default=0.1)
    ap.add_argument("--weight-decay", type=float, default=0.01)
    ap.add_argument("--max-length", type=int, default=512)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--patience", type=int, default=2, help="early-stop patience (epochs)")
    ap.add_argument("--loss", choices=["weighted_ce", "focal", "ce"], default="weighted_ce")
    ap.add_argument("--focal-gamma", type=float, default=2.0)
    ap.add_argument("--grad-clip", type=float, default=1.0)
    ap.add_argument("--device", default=None, help="override device (cpu/mps/cuda)")
    args = ap.parse_args()

    set_seed(args.seed)
    device = torch.device(args.device) if args.device else get_device()
    out_dir = Path(args.out_root) / args.run_name
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"[train] device={device} out={out_dir}")

    tokenizer = AutoTokenizer.from_pretrained(args.model)
    if tokenizer.is_fast is False:
        raise RuntimeError("A fast (WordPiece) tokenizer is required for word alignment.")

    train_ds = DisfluencyDataset(args.train, tokenizer, args.max_length)
    val_ds = DisfluencyDataset(args.val, tokenizer, args.max_length)
    print(f"[train] train={len(train_ds)} val={len(val_ds)}")
    counts = train_ds.label_counts()
    print(f"[train] label counts: {counts}")

    collate = Collator(tokenizer)
    train_loader = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True, collate_fn=collate)
    val_loader = DataLoader(val_ds, batch_size=args.batch_size, shuffle=False, collate_fn=collate)

    model = AutoModelForTokenClassification.from_pretrained(
        args.model,
        num_labels=NUM_LABELS,
        id2label=ID2LABEL,
        label2id=LABEL2ID,
    ).to(device)

    class_weights = None
    if args.loss in ("weighted_ce", "focal"):
        class_weights = compute_class_weights(counts).to(device)
        print(f"[train] class weights: {class_weights.tolist()}")

    optim = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    total_steps = max(1, len(train_loader) * args.epochs)
    warmup_steps = int(total_steps * args.warmup_ratio)
    sched = get_linear_schedule_with_warmup(optim, warmup_steps, total_steps)

    history = []
    best_f1 = -1.0
    best_epoch = -1
    epochs_no_improve = 0
    t0 = time.time()

    for epoch in range(1, args.epochs + 1):
        model.train()
        running = 0.0
        for batch in train_loader:
            input_ids = batch["input_ids"].to(device)
            attn = batch["attention_mask"].to(device)
            labels = batch["labels"].to(device)
            logits = model(input_ids=input_ids, attention_mask=attn).logits
            if args.loss == "focal":
                loss = focal_loss(logits, labels, class_weights, args.focal_gamma)
            else:
                loss = F.cross_entropy(
                    logits.view(-1, NUM_LABELS), labels.view(-1),
                    weight=class_weights, ignore_index=IGNORE_INDEX,
                )
            optim.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), args.grad_clip)
            optim.step()
            sched.step()
            running += loss.item()

        train_loss = running / max(1, len(train_loader))
        metrics = eval_delete_f1(model, val_loader, device)
        history.append({"epoch": epoch, "train_loss": train_loss, "val": metrics})
        print(f"[train] epoch {epoch}: loss={train_loss:.4f} "
              f"val DELETE P={metrics['precision']:.3f} R={metrics['recall']:.3f} "
              f"F1={metrics['f1']:.3f}")

        if metrics["f1"] > best_f1:
            best_f1 = metrics["f1"]
            best_epoch = epoch
            epochs_no_improve = 0
            model.save_pretrained(out_dir)
            tokenizer.save_pretrained(out_dir)
        else:
            epochs_no_improve += 1
            if epochs_no_improve >= args.patience:
                print(f"[train] early stop at epoch {epoch} (no val F1 gain for {args.patience})")
                break

    # if nothing ever improved (e.g. all-zero F1), still persist a checkpoint
    if best_epoch == -1:
        model.save_pretrained(out_dir)
        tokenizer.save_pretrained(out_dir)
        best_epoch = args.epochs

    wall = time.time() - t0
    report = {
        "run_name": args.run_name,
        "base_model": args.model,
        "device": str(device),
        "wall_clock_sec": round(wall, 1),
        "args": vars(args),
        "label_counts": counts,
        "best_epoch": best_epoch,
        "best_val_delete_f1": best_f1,
        "history": history,
        "labels": list(LABEL2ID.keys()),
    }
    with open(out_dir / "report.json", "w") as fh:
        json.dump(report, fh, indent=2)
    print(f"[train] done in {wall:.1f}s. best epoch={best_epoch} "
          f"val DELETE-F1={best_f1:.3f}. saved -> {out_dir}")


if __name__ == "__main__":
    main()
