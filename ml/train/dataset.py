"""Bouncer dataset: load + validate the DESIGN.md JSONL contract and align
word-level labels to WordPiece subtokens.

Contract (one JSON object per line):
    {"id": str, "source": "rule|llm|real",
     "words":  ["Send", "the", ...],
     "labels": ["KEEP", "DEL_FILLER", ...]}

Invariants enforced on read:
  * len(words) == len(labels)
  * every label is a known label
  * words / labels are non-empty lists of strings

Alignment rule (standard HF token classification):
  * label goes on the FIRST subtoken of each word
  * -100 on every continuation subtoken (ignored by the loss)
  * -100 on special tokens ([CLS], [SEP], [PAD])
"""

from __future__ import annotations

import json
import warnings
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import torch
from torch.utils.data import Dataset

# ---------------------------------------------------------------------------
# Label scheme (KEEP must be id 0 so an all-zero prediction == abstain/no-op).
# ---------------------------------------------------------------------------
KEEP = "KEEP"
DEL_LABELS = ["DEL_FILLER", "DEL_REPEAT", "DEL_REPARANDUM", "DEL_INTERREGNUM"]
LABELS = [KEEP] + DEL_LABELS
LABEL2ID = {lab: i for i, lab in enumerate(LABELS)}
ID2LABEL = {i: lab for lab, i in LABEL2ID.items()}
KEEP_ID = LABEL2ID[KEEP]
DEL_IDS = [LABEL2ID[d] for d in DEL_LABELS]
NUM_LABELS = len(LABELS)

IGNORE_INDEX = -100
MAX_SUBTOKENS = 512


@dataclass
class Record:
    id: str
    source: str
    words: list[str]
    labels: list[str]


def _validate_obj(obj: dict, line_no: int, path: str) -> Record:
    for key in ("words", "labels"):
        if key not in obj:
            raise ValueError(f"{path}:{line_no}: missing required key '{key}'")
    words, labels = obj["words"], obj["labels"]
    if not isinstance(words, list) or not isinstance(labels, list):
        raise ValueError(f"{path}:{line_no}: 'words'/'labels' must be lists")
    if len(words) != len(labels):
        raise ValueError(
            f"{path}:{line_no}: len(words)={len(words)} != len(labels)={len(labels)}"
        )
    if len(words) == 0:
        raise ValueError(f"{path}:{line_no}: empty 'words'")
    for w in words:
        if not isinstance(w, str):
            raise ValueError(f"{path}:{line_no}: non-string word {w!r}")
    for lab in labels:
        if lab not in LABEL2ID:
            raise ValueError(
                f"{path}:{line_no}: unknown label {lab!r} (known: {LABELS})"
            )
    return Record(
        id=str(obj.get("id", f"line-{line_no}")),
        source=str(obj.get("source", "unknown")),
        words=words,
        labels=labels,
    )


def load_records(path: str | Path) -> list[Record]:
    """Read and validate a contract-JSONL file. Raises on the first bad line."""
    path = str(path)
    records: list[Record] = []
    with open(path, "r", encoding="utf-8") as fh:
        for line_no, raw in enumerate(fh, start=1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError as e:
                raise ValueError(f"{path}:{line_no}: invalid JSON: {e}") from e
            records.append(_validate_obj(obj, line_no, path))
    if not records:
        raise ValueError(f"{path}: no records found")
    return records


def align_labels(
    words: list[str],
    word_label_ids: list[int],
    tokenizer,
    max_length: int = MAX_SUBTOKENS,
    record_id: str = "?",
) -> dict:
    """Tokenize a pre-split word list and align labels to the first subtoken.

    Returns a dict with input_ids / attention_mask / labels (all python lists).
    Truncates to `max_length` subtokens, emitting a warning (dictations are
    short so this should be exceptionally rare).
    """
    enc = tokenizer(
        words,
        is_split_into_words=True,
        truncation=True,
        max_length=max_length,
        return_tensors=None,
    )
    word_ids = enc.word_ids()
    aligned: list[int] = []
    prev_word_idx = None
    for word_idx in word_ids:
        if word_idx is None:
            aligned.append(IGNORE_INDEX)          # special token
        elif word_idx != prev_word_idx:
            aligned.append(word_label_ids[word_idx])  # first subtoken
        else:
            aligned.append(IGNORE_INDEX)          # continuation subtoken
        prev_word_idx = word_idx

    n_words_covered = len({w for w in word_ids if w is not None})
    if n_words_covered < len(words):
        warnings.warn(
            f"record {record_id}: truncated to {max_length} subtokens; "
            f"{len(words) - n_words_covered} of {len(words)} words dropped",
            stacklevel=2,
        )

    enc["labels"] = aligned
    # word_ids lets inference gather the first-subtoken logit for each word.
    enc["word_ids"] = [(-1 if w is None else w) for w in word_ids]
    return enc


class DisfluencyDataset(Dataset):
    """Torch Dataset over the contract JSONL, tokenized + label-aligned."""

    def __init__(self, path: str | Path, tokenizer, max_length: int = MAX_SUBTOKENS):
        self.records = load_records(path)
        self.tokenizer = tokenizer
        self.max_length = max_length
        self.examples: list[dict] = []
        for rec in self.records:
            word_label_ids = [LABEL2ID[lab] for lab in rec.labels]
            enc = align_labels(
                rec.words, word_label_ids, tokenizer, max_length, rec.id
            )
            enc["_id"] = rec.id
            enc["_words"] = rec.words
            enc["_gold"] = word_label_ids
            self.examples.append(enc)

    def __len__(self) -> int:
        return len(self.examples)

    def __getitem__(self, idx: int) -> dict:
        return self.examples[idx]

    def label_counts(self) -> dict[str, int]:
        counts = {lab: 0 for lab in LABELS}
        for rec in self.records:
            for lab in rec.labels:
                counts[lab] += 1
        return counts


class Collator:
    """Dynamic-padding collator. Pads input_ids/attention_mask to the batch max
    and labels with IGNORE_INDEX. Keeps a parallel list of record ids."""

    def __init__(self, tokenizer):
        self.pad_id = tokenizer.pad_token_id

    def __call__(self, batch: Iterable[dict]) -> dict:
        batch = list(batch)
        maxlen = max(len(ex["input_ids"]) for ex in batch)
        input_ids, attn, labels, word_ids = [], [], [], []
        ids, words, gold = [], [], []
        for ex in batch:
            n = len(ex["input_ids"])
            pad = maxlen - n
            input_ids.append(ex["input_ids"] + [self.pad_id] * pad)
            attn.append(ex["attention_mask"] + [0] * pad)
            labels.append(ex["labels"] + [IGNORE_INDEX] * pad)
            word_ids.append(ex.get("word_ids", []) + [-1] * pad)
            ids.append(ex.get("_id", "?"))
            words.append(ex.get("_words", []))
            gold.append(ex.get("_gold", []))
        return {
            "input_ids": torch.tensor(input_ids, dtype=torch.long),
            "attention_mask": torch.tensor(attn, dtype=torch.long),
            "labels": torch.tensor(labels, dtype=torch.long),
            "word_ids": word_ids,
            "ids": ids,
            "words": words,
            "gold": gold,
        }


def compute_class_weights(counts: dict[str, int], cap: float = 20.0) -> torch.Tensor:
    """Inverse-frequency class weights (normalised so KEEP≈1), capped so a very
    rare DEL_* class can't blow up the loss. Order matches LABELS."""
    total = sum(counts.values())
    weights = []
    for lab in LABELS:
        c = counts.get(lab, 0)
        w = (total / (NUM_LABELS * c)) if c > 0 else cap
        weights.append(min(w, cap))
    # normalise so KEEP weight == 1.0 (stable loss scale)
    keep_w = weights[KEEP_ID] or 1.0
    weights = [w / keep_w for w in weights]
    return torch.tensor(weights, dtype=torch.float)
