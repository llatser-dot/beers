"""Shared inference helpers for evaluate.py and calibrate.py.

Runs a checkpoint over a contract-JSONL dataset and returns, per record, the
per-word class-probability matrix (softmax over the first-subtoken logits).
Everything downstream (metrics, thresholding, calibration) works from these
word-level probabilities so there is a single source of truth.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import torch
from torch.utils.data import DataLoader
from transformers import AutoModelForTokenClassification, AutoTokenizer

from dataset import (
    DEL_IDS,
    KEEP_ID,
    Collator,
    DisfluencyDataset,
)


def get_device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


@dataclass
class WordPrediction:
    id: str
    words: list[str]
    gold: list[int]                 # gold label id per word (or empty if unknown)
    probs: list[list[float]]        # per-word softmax over NUM_LABELS
    del_prob: list[float] = field(default_factory=list)  # P(any DEL_*) per word

    def __post_init__(self):
        if not self.del_prob:
            self.del_prob = [sum(p[i] for i in DEL_IDS) for p in self.probs]

    def argmax_labels(self) -> list[int]:
        return [int(max(range(len(p)), key=lambda i: p[i])) for p in self.probs]

    def threshold_labels(self, t: float) -> list[int]:
        """Predicted label id per word under DELETE threshold `t`:
        delete (using the argmax DEL_* subtype) only if P(any DEL_*) >= t,
        else KEEP. This is the app's deletion rule."""
        out = []
        for p, dp in zip(self.probs, self.del_prob):
            if dp >= t:
                best_del = max(DEL_IDS, key=lambda i: p[i])
                out.append(best_del)
            else:
                out.append(KEEP_ID)
        return out


def load_checkpoint(model_dir: str):
    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    model = AutoModelForTokenClassification.from_pretrained(model_dir)
    return model, tokenizer


@torch.no_grad()
def predict(
    model,
    tokenizer,
    jsonl_path: str,
    device: torch.device | None = None,
    batch_size: int = 16,
    max_length: int = 512,
) -> list[WordPrediction]:
    device = device or get_device()
    model.to(device)
    model.eval()

    ds = DisfluencyDataset(jsonl_path, tokenizer, max_length=max_length)
    collate = Collator(tokenizer)
    loader = DataLoader(ds, batch_size=batch_size, shuffle=False, collate_fn=collate)

    results: list[WordPrediction] = []
    for batch in loader:
        input_ids = batch["input_ids"].to(device)
        attn = batch["attention_mask"].to(device)
        logits = model(input_ids=input_ids, attention_mask=attn).logits
        probs = torch.softmax(logits.float(), dim=-1).cpu()  # (B, T, C)

        for b in range(probs.shape[0]):
            word_ids = batch["word_ids"][b]
            words = batch["words"][b]
            gold = batch["gold"][b]
            # first subtoken position for each word index
            first_pos: dict[int, int] = {}
            for tok_pos, w in enumerate(word_ids):
                if w is not None and w >= 0 and w not in first_pos:
                    first_pos[w] = tok_pos
            word_probs = []
            for w in range(len(words)):
                if w in first_pos:
                    word_probs.append(probs[b, first_pos[w]].tolist())
                else:  # word truncated away -> treat as confident KEEP (no-op)
                    keep_vec = [0.0] * probs.shape[-1]
                    keep_vec[KEEP_ID] = 1.0
                    word_probs.append(keep_vec)
            results.append(
                WordPrediction(
                    id=batch["ids"][b],
                    words=words,
                    gold=gold,
                    probs=word_probs,
                )
            )
    return results
