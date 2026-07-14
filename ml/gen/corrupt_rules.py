"""Rule-based disfluency corruptor.

Takes a clean transcript, injects fillers / repeats / phrase-restarts /
hesitation fragments, and emits perfect word-level labels per DESIGN.md.

Calibration (measured 2026-07-14 on the real material):
  - real polished log: filler-rate/word = 4.12%, 51% of transcripts carry
    a filler; pours (fully cleaned): 2.57%, 34%.
  - The raw ASR the model actually sees is *more* disfluent than the polished
    log, so we push corrupted transcripts a bit denser, while keeping
    CLEAN_FRACTION fully clean so the model learns to abstain.

Public API:
  corrupt(clean_text, rng) -> (words, labels)   # may return all-KEEP
  make_example(id, clean_text, rng) -> dict      # validated JSONL object
"""
from __future__ import annotations
import sys, os, re, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

# Fraction of transcripts left entirely clean (all-KEEP).
CLEAN_FRACTION = 0.25

# Filler pools with realistic weights (mirrors the real top-fillers:
# so / okay / like / or whatever / literally dominate; um/uh/erm are the
# classic ASR fillers that survive into raw Parakeet output).
_FILLER_WEIGHTED = [
    ("um", 10), ("uh", 8), ("erm", 5), ("er", 3), ("like", 12), ("so", 8),
    ("okay", 4), ("basically", 5), ("actually", 4),
    ("right", 4), ("well", 4), ("you know", 5), ("sort of", 4),
    ("kind of", 4), ("i mean", 4), ("or whatever", 4), ("obviously", 3),
    ("honestly", 2), ("essentially", 2),
]
# NOTE (gold-review alignment, 2026-07-14):
# - "literally" removed from the delete pool — gold rules it as Ben's voice
#   (KEEP always, judgment call #5).
# - Sentence-initial connectives ("Okay,"/"So"/"Also,"/"See,"/"I mean") are
#   KEEP per gold judgment call #1; only true hesitation sounds are deletable
#   at sentence start. See _OPENER_HESITATIONS + gen/corrupt_traps.py which
#   teaches the KEEP side of these patterns.
_OPENER_HESITATIONS = ["um", "um", "uh", "erm", "er"]
_FILLER_WORDS = [w for w, _ in _FILLER_WEIGHTED]
_FILLER_WTS = [n for _, n in _FILLER_WEIGHTED]

_HESITATIONS = ["th-", "wh-", "s-", "the-", "wa-", "co-", "pr-", "b-", "d-"]

_TRAIL = ".,!?;:"

def _split_trail(word: str) -> tuple[str, str]:
    """Return (core, trailing_punct)."""
    i = len(word)
    while i > 0 and word[i - 1] in _TRAIL:
        i -= 1
    return word[:i], word[i:]

def _weighted_filler(rng) -> str:
    return rng.choices(_FILLER_WORDS, weights=_FILLER_WTS, k=1)[0]

def _emit_filler(rng, sentence_initial=False) -> list[str]:
    """Return the word-tokens for one filler event (ASR-style punctuation)."""
    if sentence_initial:
        # Only genuine hesitation sounds are deletable openers ("Um," / "Erm").
        # Connective openers like "Okay,"/"So"/"Also, so" are KEEP in Ben's
        # usage (gold judgment call #1) and are taught as traps instead.
        f = rng.choice(_OPENER_HESITATIONS)
        tok = f.capitalize()
        if rng.random() < 0.7:
            tok += ","
        return [tok]
    f = _weighted_filler(rng)
    toks = f.split()
    # ASR frequently attaches a comma after a mid-sentence filler.
    if rng.random() < 0.55:
        toks[-1] = toks[-1] + ","
    return toks


def corrupt(clean_text: str, rng: random.Random):
    """Corrupt one clean transcript. Returns (words, labels)."""
    clean_words = clean_text.split()
    n = len(clean_words)
    if n == 0:
        return [], []

    # A quarter stay entirely clean.
    if rng.random() < CLEAN_FRACTION:
        return list(clean_words), ["KEEP"] * n

    out_words: list[str] = []
    out_labels: list[str] = []

    # Per-word filler probability, scaled so short transcripts still get ~1
    # filler and long ones do not get carpet-bombed. Target mean ~0.06-0.09
    # filler/word across corrupted transcripts.
    base_p = rng.uniform(0.04, 0.09)

    # Decide global events for this transcript.
    do_restart = rng.random() < 0.18 and n >= 5
    do_hesitation = rng.random() < 0.12

    # ---- optional sentence-initial hesitation ("Um, ...") ----
    if rng.random() < 0.20:
        for t in _emit_filler(rng, sentence_initial=True):
            out_words.append(t)
            out_labels.append("DEL_FILLER")
        # lowercase the first real word (casing seam, allowed)
        core, tr = _split_trail(clean_words[0])
        if core[:1].isupper() and not core.isupper():
            clean_words = list(clean_words)
            clean_words[0] = core[0].lower() + core[1:] + tr

    # ---- phrase restart near the start of a clause ----
    # Re-speak first k words: first copy = DEL_REPARANDUM, then KEEP originals.
    restart_at = 0
    if do_restart:
        k = rng.randint(2, min(6, n - 1))
        # optional trailing cut-off marker on the reparandum
        rep = [w for w in clean_words[:k]]
        # strip terminal punctuation from reparandum copy (it was cut off)
        rep = [_split_trail(w)[0] for w in rep]
        for w in rep:
            out_words.append(w)
            out_labels.append("DEL_REPARANDUM")

    # ---- main pass over the clean words ----
    # Pick at most one hesitation position up front (deterministic).
    hes_pos = rng.randint(1, n - 1) if (do_hesitation and n >= 2) else -1

    idx = 0
    while idx < n:
        w = clean_words[idx]

        # hesitation fragment right before a content word ("s- send it")
        if idx == hes_pos:
            out_words.append(rng.choice(_HESITATIONS))
            out_labels.append("DEL_FILLER")

        # filler before this word (never before the very first real word;
        # the sentence-initial opener handled that case already)
        if idx > 0 and rng.random() < base_p:
            for t in _emit_filler(rng, sentence_initial=False):
                out_words.append(t)
                out_labels.append("DEL_FILLER")

        # immediate repeat, emitted BEFORE the real word so the kept copy is
        # the final one ("the the report" -> DEL_REPEAT KEEP KEEP).
        r = rng.random()
        if r < 0.015 and idx < n - 1:
            # bigram repeat: "tell her tell her" -> first pair deleted
            c0 = _split_trail(clean_words[idx])[0]
            c1 = _split_trail(clean_words[idx + 1])[0]
            out_words += [c0, c1]
            out_labels += ["DEL_REPEAT", "DEL_REPEAT"]
        elif r < 0.05:
            # single-word repeat
            out_words.append(_split_trail(w)[0])
            out_labels.append("DEL_REPEAT")

        # the real word (keeps its original punctuation/casing)
        out_words.append(w)
        out_labels.append("KEEP")
        idx += 1

    return out_words, out_labels


def make_example(ex_id: str, clean_text: str, rng: random.Random):
    words, labels = corrupt(clean_text, rng)
    ok, reason = C.validate_example(words, labels, clean_text)
    if not ok:
        return None, reason
    return {"id": ex_id, "source": "rule", "words": words,
            "labels": labels, "clean": clean_text}, "ok"


# ---------------------------------------------------------------------------
def _demo():
    rng = random.Random(7)
    samples = [
        "Send the report to Dave and cc Sarah.",
        "Push the PlanWatch redesign to localhost and run it through the config.",
        "What goes into building the model ourselves?",
        "Go and find me some domains with a crazy amount of backlinks.",
        "Deploy it to Cloudflare and make sure the schema is correct.",
    ]
    for i, s in enumerate(samples):
        ex, reason = make_example(f"demo-{i}", s, rng)
        if ex is None:
            print("REJECT", reason, s); continue
        print("CLEAN:", s)
        for w, l in zip(ex["words"], ex["labels"]):
            mark = "" if l == "KEEP" else "  <-- " + l
            print(f"   {w!r:20} {l}{mark}")
        print()


if __name__ == "__main__":
    _demo()
