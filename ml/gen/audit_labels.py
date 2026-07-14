"""Audit + repair the two v2 label-poison bugs in the synthetic data.

Re-runnable and deterministic. Reports before/after counts per file per bug,
repairs records in place, and re-validates every touched file against the
full DESIGN contract (len match + KEEP-reconstruction where a clean ref
exists) plus the repeat invariant.

BUG A — repeat labels taught double-deletion.
  Poison signature repaired: an immediate repeat hidden inside a non-REPEAT
  deletion — a DEL_INTERREGNUM/DEL_FILLER token that duplicates the very next
  KEEP word (gemma restated the corrected value inside the marker, e.g.
  "...no wait it was David | David at ..."). Repair: relabel that deleted
  first copy to DEL_REPEAT (C.normalize_hidden_repeats). KEEP set unchanged,
  so reconstruction is preserved; the subtype is now correct and the
  "delete both copies" signal is removed.
  Also REPORTED (not altered): fragmented rule DEL_REPEAT runs whose kept
  copy is split by an interleaved filler. These still delete the first copy
  and leave exactly one intact copy after deletion, so they are
  contract-valid and realistic; the generator is fixed so new data emits the
  repeat contiguously, but existing records are left as-is.

BUG B — residual deletion of protected "voice" words.
  Gold protects literally / genuinely / actually / "or whatever" as Ben's
  voice (KEEP) whenever used as an intensifier / hedge / connective. They may
  only be DELETE inside a genuine self-correction span (DEL_REPARANDUM), a
  genuine correction-interregnum (DEL_INTERREGNUM), or as the deleted first
  copy of a repeat (DEL_REPEAT). Repair: flip standalone DEL_FILLER labels on
  these words to KEEP. DEL_INTERREGNUM/DEL_REPARANDUM/DEL_REPEAT are LEFT
  (real correction / abandoned clause / repeat).

Usage:
  python gen/audit_labels.py            # audit + repair in place
  python gen/audit_labels.py --dry-run  # report only, write nothing
"""
from __future__ import annotations
import sys, os, json
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

FILES = ["data/train.jsonl", "data/val.jsonl", "data/llm.jsonl", "data/traps.jsonl"]
PROTECTED_LABEL = "protected voice words"


def _protected_mask(words):
    """Boolean mask: token positions covered by a protected voice word/phrase."""
    mask = [False] * len(words)
    i = 0
    while i < len(words):
        L = C.is_protected_voice_at(words, i)
        if L:
            for j in range(i, i + L):
                mask[j] = True
            i += L
        else:
            i += 1
    return mask


def _count_hidden_repeats(rec):
    """non-REPEAT DEL token immediately duplicating the next KEEP word."""
    w, l = rec["words"], rec["labels"]
    c = 0
    for k in range(len(l) - 1):
        if l[k] in ("DEL_INTERREGNUM", "DEL_FILLER") and l[k + 1] == "KEEP":
            a = C.norm_word(w[k])
            if a and a == C.norm_word(w[k + 1]):
                c += 1
    return c


def _count_fragmented_repeats(rec):
    """DEL_REPEAT runs NOT immediately followed by an identical intact KEEP
    copy (contract-valid but non-contiguous; reported, not repaired)."""
    w, l = rec["words"], rec["labels"]
    n = len(l)
    bad = 0
    i = 0
    while i < n:
        if l[i] == "DEL_REPEAT":
            j = i
            while j + 1 < n and l[j + 1] == "DEL_REPEAT":
                j += 1
            L = j - i + 1
            unit = [C.norm_word(x) for x in w[i:j + 1]]
            foll = w[j + 1:j + 1 + L]
            foll_l = l[j + 1:j + 1 + L]
            if (len(foll) != L or any(x != "KEEP" for x in foll_l)
                    or [C.norm_word(x) for x in foll] != unit):
                bad += 1
            i = j + 1
        else:
            i += 1
    return bad


def _protected_label_counts(recs):
    """Counter keyed (voice_word, label) over protected occurrences."""
    cnt = Counter()
    for rec in recs:
        w, l = rec["words"], rec["labels"]
        i = 0
        while i < len(w):
            L = C.is_protected_voice_at(w, i)
            if L:
                key = " ".join(C.norm_word(w[j]) for j in range(i, i + L))
                # collapse the phrase to a stable name
                name = "or whatever" if L == 2 else key
                for j in range(i, i + L):
                    cnt[(name, l[j])] += 1
                i += L
            else:
                i += 1
    return cnt


def audit_and_repair(dry_run=False):
    ml = C.ML_DIR
    grand = {}
    for rel in FILES:
        path = os.path.join(ml, rel)
        recs = C.read_jsonl(path)

        # ---- BUG A: before ----
        a_hidden_before = sum(_count_hidden_repeats(r) for r in recs)
        a_frag = sum(_count_fragmented_repeats(r) for r in recs)

        # ---- BUG B: before ----
        b_before = _protected_label_counts(recs)

        # ---- repairs (deterministic, per record) ----
        a_fixed = 0
        b_flipped = Counter()
        b_skipped = 0
        for rec in recs:
            w, l = rec["words"], rec["labels"]
            clean = rec.get("clean")
            # BUG A: relabel hidden repeats -> DEL_REPEAT (KEEP set unchanged).
            a_fixed += C.normalize_hidden_repeats(l, w)
            # BUG B: flip standalone DEL_FILLER on protected voice words -> KEEP.
            mask = _protected_mask(w)
            for k in range(len(l)):
                if mask[k] and l[k] == "DEL_FILLER":
                    if clean is not None:
                        trial = list(l); trial[k] = "KEEP"
                        ok, _ = C.validate_example(w, trial, clean)
                        if not ok:
                            b_skipped += 1
                            continue
                    l[k] = "KEEP"
                    b_flipped[C.norm_word(w[k])] += 1

        # ---- validate every record against the full contract ----
        bad = []
        for rec in recs:
            ok, why = C.validate_example(rec["words"], rec["labels"], rec.get("clean"))
            if not ok:
                bad.append((rec.get("id"), why))
        assert not bad, f"{rel}: contract violations after repair: {bad[:5]}"

        # ---- BUG A/B: after ----
        a_hidden_after = sum(_count_hidden_repeats(r) for r in recs)
        b_after = _protected_label_counts(recs)

        # ---- write back (only if something changed) ----
        changed = a_fixed + sum(b_flipped.values())
        if changed and not dry_run:
            with open(path, "w", encoding="utf-8") as f:
                for rec in recs:
                    f.write(json.dumps(rec, ensure_ascii=False) + "\n")

        grand[rel] = dict(
            n=len(recs),
            a_hidden_before=a_hidden_before, a_hidden_after=a_hidden_after,
            a_fixed=a_fixed, a_fragmented=a_frag,
            b_before=b_before, b_after=b_after,
            b_flipped=dict(b_flipped), b_skipped=b_skipped,
            changed=changed,
        )

    _report(grand, dry_run)
    return grand


def _report(grand, dry_run):
    print("=" * 72)
    print("BOUNCER LABEL AUDIT" + (" (DRY RUN)" if dry_run else " (REPAIRED IN PLACE)"))
    print("=" * 72)
    for rel, g in grand.items():
        print(f"\n### {rel}  ({g['n']} records)")
        print("  BUG A (repeat double-deletion):")
        print(f"    hidden-repeat DELs (repairable): before={g['a_hidden_before']} "
              f"after={g['a_hidden_after']}  relabelled->DEL_REPEAT={g['a_fixed']}")
        print(f"    fragmented DEL_REPEAT runs (reported, left in place; "
              f"contract-valid, generator now emits contiguously): {g['a_fragmented']}")
        print("  BUG B (protected voice words):")
        for name in ("literally", "genuinely", "actually", "or whatever"):
            bef = {lb: g['b_before'][(name, lb)] for (nm, lb) in g['b_before'] if nm == name}
            aft = {lb: g['b_after'][(name, lb)] for (nm, lb) in g['b_after'] if nm == name}
            if not bef and not aft:
                continue
            print(f"    {name:12}  before={_fmt(bef)}")
            print(f"    {'':12}  after ={_fmt(aft)}")
        if g['b_flipped']:
            print(f"    DEL_FILLER->KEEP flips: {g['b_flipped']}  skipped(clean-guard)={g['b_skipped']}")
    print("\n" + "=" * 72)
    print("All touched files re-validated against the full contract: PASS")
    print("=" * 72)


def _fmt(d):
    order = ["KEEP", "DEL_FILLER", "DEL_REPEAT", "DEL_REPARANDUM", "DEL_INTERREGNUM"]
    return {k: d[k] for k in order if k in d}


if __name__ == "__main__":
    audit_and_repair(dry_run="--dry-run" in sys.argv)
