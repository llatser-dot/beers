"""Assemble train.jsonl / val.jsonl from the corruption sources + emit stats.

Mix (by transcript):
  rule-corrupted   ~45%   (includes the ~25% all-KEEP clean baked into rules)
  traps            ~30%   (hard negatives from gen/corrupt_traps.py: KEEP-
                          labeled deletion lookalikes — added after v1's gold
                          DELETE precision collapsed on exactly these patterns)
  llm-corrupted    ~20%   (semantic self-corrections)
  raw real logs    ~5%    (verbatim real dictations, labelled all-KEEP as a
                          weak-but-real signal; the TRUE eval is data/gold.jsonl
                          built by another agent, which we do NOT touch)

Split: 95/5 train/val by CLEAN-SOURCE sentence (trap/llm records carry their
seed sentence), so no clean seed and none of its corrupted/decorated variants
appear in both splits. Traps land in VAL proportionally — this is what makes
val-threshold calibration predictive of gold.

Usage: python gen/build_dataset.py
"""
from __future__ import annotations
import sys, os, random, json, hashlib
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
import corrupt_rules as R

random.seed(2026)

TRAIN = os.path.join(C.DATA_DIR, "train.jsonl")
VAL = os.path.join(C.DATA_DIR, "val.jsonl")
STATS = os.path.join(C.DATA_DIR, "stats.md")

VAL_FRACTION = 0.05

# Target proportions among the FINAL dataset.
RULE_SHARE = 0.45
TRAP_SHARE = 0.30
LLM_SHARE = 0.20
REAL_SHARE = 0.05

def clean_key(text):
    return hashlib.sha1(text.strip().lower().encode()).hexdigest()[:16]

def load_clean_corpus():
    """Return list of (clean_text, corpus_name)."""
    items = []
    for fn in sorted(os.listdir(C.CLEAN_DIR)):
        if not fn.endswith(".txt"):
            continue
        name = fn[:-4]
        for line in open(os.path.join(C.CLEAN_DIR, fn), encoding="utf-8"):
            t = line.strip()
            if len(t.split()) >= 2:
                items.append((t, name))
    return items

def main():
    corpus = load_clean_corpus()
    # dedupe clean by normalised text, keep first corpus label
    seen = {}
    for t, name in corpus:
        k = clean_key(t)
        if k not in seen:
            seen[k] = (t, name)
    clean_items = list(seen.values())
    random.shuffle(clean_items)
    print(f"[build] unique clean transcripts: {len(clean_items)}")

    # Assign each CLEAN key to train or val up-front (split by source sentence).
    split_of = {}
    for t, name in clean_items:
        k = clean_key(t)
        split_of[k] = "val" if random.random() < VAL_FRACTION else "train"

    def _dedup(rows):
        ids, outl = set(), []
        for ex in rows:
            if ex["id"] in ids:
                continue
            ids.add(ex["id"])
            outl.append(ex)
        return outl

    llm = _dedup(C.read_jsonl(os.path.join(C.DATA_DIR, "llm.jsonl")))
    traps = _dedup(C.read_jsonl(os.path.join(C.DATA_DIR, "traps.jsonl")))
    n_llm, n_trap = len(llm), len(traps)
    real = C.load_real_log()

    # Target mix rule 45 / trap 30 / llm 20 / real 5. The scarce sources (llm,
    # traps) bound the total; the rule subsample is sized off that so the mix
    # holds whenever this is rebuilt (background jobs grow over time ->
    # rebuild for a bigger, still-balanced dataset).
    bounds = []
    if n_llm:
        bounds.append(n_llm / LLM_SHARE)
    if n_trap:
        bounds.append(n_trap / TRAP_SHARE)
    target_total = min(bounds) if bounds else len(clean_items)
    n_rule_target = min(int(round(RULE_SHARE * target_total)), len(clean_items))
    n_real = min(int(round(REAL_SHARE * target_total)), len(real))
    n_llm_use = min(n_llm, int(round(LLM_SHARE * target_total)))
    n_trap_use = min(n_trap, int(round(TRAP_SHARE * target_total)))

    rng = random.Random(99)
    out = {"train": [], "val": []}
    src_counts = Counter()
    label_counts = Counter()
    lengths = []
    filler_words = 0
    total_words = 0
    corpus_src_counts = Counter()

    def add(ex, split):
        ok, why = C.validate_example(ex["words"], ex["labels"], ex.get("clean"))
        if not ok:
            return False
        rec = {"id": ex["id"], "source": ex["source"],
               "words": ex["words"], "labels": ex["labels"]}
        out[split].append(rec)
        src_counts[ex["source"]] += 1
        lengths.append(len(ex["words"]))
        for l in ex["labels"]:
            label_counts[l] += 1
        return True

    # ---- rule-corrupted: corrupt a subsample of the clean corpus once ----
    # clean_items is already shuffled; take the first n_rule_target.
    for i, (t, name) in enumerate(clean_items[:n_rule_target]):
        k = clean_key(t)
        split = split_of[k]
        ex, why = R.make_example(f"rule-{i:06d}", t, rng)
        if ex is None:
            continue
        if add(ex, split):
            corpus_src_counts[name] += 1

    # ---- llm-corrupted ----
    # Assign each llm example's split by its clean text (so its clean seed's
    # split is respected; unknown clean -> hash-based split).
    rng.shuffle(llm)
    for ex in llm[:n_llm_use]:
        k = clean_key(ex.get("clean", " ".join(
            w for w, l in zip(ex["words"], ex["labels"]) if l == "KEEP")))
        split = split_of.get(k)
        if split is None:
            split = "val" if (int(k, 16) % 100) < VAL_FRACTION * 100 else "train"
        add(ex, split)

    # ---- traps (hard negatives) ----
    # Split by the trap's SEED sentence when it has one (so a seed's rule-
    # corrupted variant and its trap decoration never straddle the split);
    # standalone template traps split by their own text hash. Sample evenly
    # across categories so no trap type dominates.
    trap_cat_counts = Counter()
    by_cat = {}
    for ex in traps:
        by_cat.setdefault(ex.get("cat", "?"), []).append(ex)
    for cat in by_cat:
        rng.shuffle(by_cat[cat])
    # round-robin take until n_trap_use
    taken, ptr = [], {c: 0 for c in by_cat}
    while len(taken) < n_trap_use:
        progressed = False
        for c in sorted(by_cat):
            if ptr[c] < len(by_cat[c]) and len(taken) < n_trap_use:
                taken.append(by_cat[c][ptr[c]])
                ptr[c] += 1
                progressed = True
        if not progressed:
            break
    for ex in taken:
        key_text = ex.get("seed") or " ".join(ex["words"])
        k = clean_key(key_text)
        split = split_of.get(k)
        if split is None:
            split = "val" if (int(k, 16) % 100) < VAL_FRACTION * 100 else "train"
        if add(ex, split):
            trap_cat_counts[ex.get("cat", "?")] += 1

    # ---- real verbatim logs (all-KEEP) ----
    # Real log lines are ALSO corpus seeds (seed_log.txt), so they MUST use
    # the same seed split as their rule-corrupted variants.
    for j, t in enumerate(real[:n_real if n_real > 0 else len(real)]):
        ws = t.split()
        rec = {"id": f"real-{j:04d}", "source": "real",
               "words": ws, "labels": ["KEEP"] * len(ws), "clean": t}
        k = clean_key(t)
        split = split_of.get(k)
        if split is None:
            split = "val" if (int(k, 16) % 100) < VAL_FRACTION * 100 else "train"
        add(rec, split)

    # ---- write ----
    random.shuffle(out["train"])
    random.shuffle(out["val"])
    for path, split in ((TRAIN, "train"), (VAL, "val")):
        with open(path, "w", encoding="utf-8") as f:
            for rec in out[split]:
                ok, why = C.validate_example(rec["words"], rec["labels"])
                assert ok, why
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(f"[build] train={len(out['train'])} val={len(out['val'])}")

    # ---- stats ----
    for rec in out["train"] + out["val"]:
        total_words += len(rec["words"])
        for w, l in zip(rec["words"], rec["labels"]):
            if l == "DEL_FILLER":
                filler_words += 1
    write_stats(out, src_counts, label_counts, lengths, filler_words,
                total_words, len(clean_items), n_llm, trap_cat_counts)

def _hist(lengths):
    buckets = [("1-3", 0, 3), ("4-8", 4, 8), ("9-20", 9, 20),
               ("21-40", 21, 40), ("41-80", 41, 80), ("81-120", 81, 120),
               ("120+", 121, 10**9)]
    counts = {b[0]: 0 for b in buckets}
    for L in lengths:
        for name, lo, hi in buckets:
            if lo <= L <= hi:
                counts[name] += 1
                break
    return counts

def write_stats(out, src_counts, label_counts, lengths, filler_words,
                total_words, n_clean, n_llm, trap_cat_counts=None):
    # real material comparison
    real = C.load_real_log()
    real_words = sum(len(t.split()) for t in real)
    real_fill = 0
    fw = set(f for f, _ in R._FILLER_WEIGHTED)
    for t in real:
        for w in t.split():
            if C.norm_word(w) in fw:
                real_fill += 1
    total = len(out["train"]) + len(out["val"])
    tot_labels = sum(label_counts.values())
    hist = _hist(lengths)
    lines = []
    A = lines.append
    A("# Bouncer training-data stats\n")
    A(f"_Generated by gen/build_dataset.py. Clean-source transcripts: {n_clean}._\n")
    A("## Dataset size")
    A(f"- train: **{len(out['train'])}**  transcripts")
    A(f"- val:   **{len(out['val'])}**  transcripts")
    A(f"- total: **{total}**  transcripts, {total_words} words\n")
    A("## Counts per source")
    for s in ("rule", "trap", "llm", "real"):
        c = src_counts.get(s, 0)
        A(f"- `{s}`: {c}  ({100*c/max(1,total):.1f}%)")
    A("")
    if trap_cat_counts:
        A("## Trap categories (hard negatives, KEEP-labeled lookalikes)")
        for cat in sorted(trap_cat_counts):
            A(f"- `{cat}`: {trap_cat_counts[cat]}")
        A("")
    # val composition — the whole point of the trap slice is that val must
    # predict gold, so report the val-side source mix explicitly.
    val_src = Counter(r["source"] for r in out["val"])
    nv = max(1, len(out["val"]))
    A("## Val composition (must predict gold)")
    for s in ("rule", "trap", "llm", "real"):
        A(f"- `{s}`: {val_src.get(s, 0)}  ({100*val_src.get(s,0)/nv:.1f}%)")
    A("")
    A("## Label distribution (token-level)")
    for lb in C.LABELS:
        c = label_counts.get(lb, 0)
        A(f"- `{lb}`: {c}  ({100*c/max(1,tot_labels):.2f}%)")
    del_tot = sum(label_counts.get(l, 0) for l in C.DEL_LABELS)
    A(f"- **any DELETE**: {del_tot}  ({100*del_tot/max(1,tot_labels):.2f}%)\n")
    A("## Length histogram (words per transcript)")
    for name, c in hist.items():
        bar = "#" * int(40 * c / max(1, max(hist.values())))
        A(f"- {name:>6}: {c:6d} {bar}")
    A("")
    A("## Filler-rate calibration vs real logs")
    syn_rate = 100 * filler_words / max(1, total_words)
    real_rate = 100 * real_fill / max(1, real_words)
    A(f"- real polished log:   {real_rate:.2f}% filler/word  "
      f"({real_fill}/{real_words})")
    A(f"- synthetic dataset:   {syn_rate:.2f}% filler/word  "
      f"({filler_words}/{total_words})")
    A("- Note: synthetic is intentionally denser than the *polished* log, "
      "since raw Parakeet ASR (what the model sees at inference) is more "
      "disfluent than the rule-polished log lines. ~25-30% of rule "
      "transcripts are fully clean (all-KEEP) to teach abstention.")
    A("")
    A("## Provenance")
    A("- clean seeds: 226 real pours + polished log lines (Ben's voice)")
    A("- template/slot generation in his registers (SEO/dev/trades/planning)")
    A("- gemma4:latest local generation (clean corpus + LLM self-corrections)")
    A("- hard-negative traps (gen/corrupt_traps.py) calibrated to "
      "data/gold-review.md judgment calls after v1 gold-precision collapse")
    A("- The ONLY eval that counts is data/gold.jsonl (built separately).")
    with open(STATS, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("[build] wrote", STATS)
    print("\n".join(lines))

if __name__ == "__main__":
    main()
