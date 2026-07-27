#!/usr/bin/env python3
"""Hand-labelling of the flywheel real material into real-v3.jsonl.

Run of 2026-07-27 (supersedes the 2026-07-15 pass, which saw only 28 LLM-tier
pours). Every raw->served alignment and every correction event was reviewed by
hand; the decisions live in the SPECS tables below. Labels are expressed as
CONTEXT PATTERNS (normalised word sequences), not bare indices, so a spec can
never silently drift onto the wrong token: each pattern must match exactly once
(or the stated occurrence) or the script hard-fails.

Sources:
  1. LLM-tier pours (tier in {apple, local}): raw -> served is a cleaning edit.
     Only the UNAMBIGUOUS deletions are labelled; LLM rewordings, content cuts
     and politeness trims are labelled KEEP (the Bouncer may only delete
     disfluency, never content).
  2. Correction events: the user's own keyboard fix of a served pour. Words the
     user left in place are human-verified content -> KEEP. Where the user's fix
     deleted a dangling/false-start token, that is verified DELETE evidence.

Precedent (ml/data/gold-review.md), applied throughout:
  - sentence-initial So/Okay/Also/Now/See/Like/Yes/Yeah/Brilliant/Good = KEEP
    (Ben's voice, even when the LLM stripped it)
  - literally / genuinely / actually / or whatever = KEEP
  - swearing and tone = KEEP (the LLM censors; we do not)
  - ASR garble = KEEP (never delete on noise)
  - reword/spelling/casing differences = KEEP (the Bouncer only deletes)
  - immediate repeats: first copy DEL_REPEAT, intact copy KEEP
  - cut-off non-word fragments (m/t/w/c/d/f/s/n/b/v/r/y/com/sti/compl/fr)
    = DEL_REPARANDUM
  - dangling trailing fragments (gold-009 "and the") = DEL_REPARANDUM
  - cardinal rule: a false DELETE is the sin; when unsure, KEEP.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

FLY = os.path.expanduser("~/Library/Application Support/Beers/flywheel.jsonl")
OUT = os.path.join(C.DATA_DIR, "real-v3.jsonl")

F, R, P, I = "DEL_FILLER", "DEL_REPEAT", "DEL_REPARANDUM", "DEL_INTERREGNUM"
_ = None  # leave KEEP

EVENT_TYPES = ("correction", "rejection", "redictation")


def load_records():
    recs = [json.loads(l) for l in open(FLY, encoding="utf-8") if l.strip()]
    pours = [r for r in recs if "raw" in r and "served" in r
             and r.get("type") not in EVENT_TYPES]
    seen, uniq = set(), []
    for r in pours:
        k = (r.get("raw", ""), r.get("served", ""))
        if k in seen:
            continue
        seen.add(k)
        uniq.append(r)
    events = [r for r in recs if r.get("type") in EVENT_TYPES]
    return uniq, events


# --------------------------------------------------------------------------
# LLM-tier pour specs. Key = index into load_llm_pours() order (the order the
# review dump was produced in). Value = list of (pattern, labels) ops, or None
# to DISCARD the pair. Absent key => all-KEEP.
POUR_SPECS = {
    0: [(["um", "so"], [F, _]),
        (["basically", "i", "i"], [F, R, _]),
        (["like", "send"], [F, _]),
        (["the", "the", "report"], [R, _, _]),
        (["dave", "no", "wait", "send", "it", "to", "sarah"],
         [P, I, I, P, P, P, _]),
        (["you", "know", "just"], [F, F, _])],
    1: [(["mm", "this", "is", "a", "m", "this", "is", "a", "test"],
         [F, P, P, P, P, _, _, _, _])],
    2: [(["actually", "d", "taken"], [_, P, _])],
    3: [(["only", "w", "train"], [_, P, _])],
    7: [(["next", "w", "of"], [_, P, _])],
    9: None,   # DISCARD: heavy reword; profanity is KEEP, restart ambiguous
    10: [(["numbers", "this", "they're"], [_, P, _])],
    11: [(["um", "so"], [F, _]),
         (["basically", "i", "i"], [F, R, _]),
         (["uh", "ship"], [F, _]),
         (["the", "the", "thing"], [R, _, _])],
    12: [(["um", "so"], [F, _]),
         (["a", "a", "remote"], [R, _, _])],
    13: [(["um", "so"], [F, _]),
         (["basically", "i", "i"], [F, R, _]),
         (["uh", "test"], [F, _]),
         (["the", "the", "flag"], [R, _, _])],
    14: [(["um", "final", "final"], [F, R, _]),
         (["uh", "check"], [F, _])],
    17: [(["posted", "and", "posting", "sorry", "to"], [_, P, P, I, _])],
    18: [(["is", "is", "at"], [R, _, _])],
    19: [(["order", "to", "for", "them"], [_, P, _, _])],
    20: [(["strategies", "to", "again"], [_, P, _])],
    21: [(["be", "com", "comparing"], [_, P, _]),
         (["just", "m", "editing"], [_, P, _])],
    24: [(["top", "top", "do"], [R, _, _])],
    25: [(["top", "top", "do"], [R, _, _])],
    27: [(["don't", "f", "apply"], [_, P, _])],
    29: [(["in", "in", "the", "location"], [R, _, _, _])],
    30: [(["so", "m", "run", "it", "again"], [_, P, _, _, _])],
    31: [(["the", "the", "project"], [R, _, _])],
    34: [(["is", "a", "effectively"], [_, P, _])],
    38: [(["deployed", "y", "i'm"], [_, P, _])],
    40: [(["when", "v", "viewing"], [_, P, _])],
    41: [(["keeper", "or", "or", "the"], [_, R, _, _]),
         (["back", "of", "of", "argentina"], [_, R, _, _]),
         (["just", "s", "sti", "sitting"], [_, P, P, _])],
    44: [(["in", "the", "the", "footer"], [_, R, _, _])],
    45: [(["manage", "i", "mean", "i"], [_, P, P, P])],
    47: [(["them", "and", "and", "allow"], [_, R, _, _])],
    49: [(["you", "r", "redesign"], [_, P, _])],
    51: [(["i've", "n", "you've"], [_, P, _])],
    52: [(["to", "the", "one", "the", "website"], [_, P, P, _, _])],
    53: [(["a", "big", "big", "thing"], [_, R, _, _])],
    55: [(["and", "and", "like", "conversion"], [R, _, F, _])],
    57: [(["okay", "let's", "i", "think"], [_, P, _, _])],
    59: [(["deploy", "an", "agent", "an", "opus"], [_, P, P, _, _])],
    60: [(["even", "the", "even", "the", "red"], [R, R, _, _, _])],
    61: [(["built", "w", "recently"], [_, P, _])],
    62: [(["hits", "the", "the", "main"], [_, R, _, _]),
         (["of", "the", "the", "big"], [_, R, _, _]),
         (["selling", "fr"], [_, P])],
    66: [(["too", "b", "bloated"], [_, P, _])],
    67: [(["phones", "and", "and", "try"], [_, R, _, _])],
    68: [(["now", "it", "that", "that", "nothing"], [_, P, P, P, _])],
    73: [(["onto", "whether", "on", "whether", "or"], [_, _, P, P, _]),
         (["because", "i", "i", "heard"], [_, R, _, _])],
    79: [(["because", "i", "i", "am"], [_, R, _, _])],
    81: [(["them", "let's", "i", "want", "you", "to", "write"],
          [_, P, _, _, _, _, _])],
    83: [(["just", "m", "mm", "make"], [_, P, F, _])],
    85: [(["for", "it", "at", "it", "for", "me"], [_, _, P, P, _, _])],
    92: [(["google", "their", "sign", "up"], [_, P, _, _])],
    96: [(["some", "article", "more", "articles"], [_, P, _, _])],
    102: [(["much", "s", "space"], [_, P, _])],
    105: [(["written", "it's", "the", "content"], [_, P, _, _]),
          (["have", "like", "suggestions"], [_, F, _]),
          (["needlessly", "that's", "let's"], [_, P, _])],
    107: [(["fine", "on", "the", "on", "on", "the", "application"],
           [_, P, P, P, _, _, _])],
    112: [(["the", "like", "mascot"], [_, F, _]),
          (["for", "the", "the", "application"], [_, R, _, _]),
          (["but", "i", "i", "so", "i", "think"], [_, P, P, _, _, _])],
    113: [(["and", "a", "a", "level"], [_, R, _, _])],
    114: [(["you've", "you've", "got"], [R, _, _]),
          (["the", "icons", "the", "icons", "look"], [R, R, _, _, _])],
    118: [(["above", "the", "all", "the", "icons"], [_, P, _, _, _]),
          (["icons", "i", "w", "i", "want"], [_, P, P, _, _]),
          (["like", "a", "a", "bunch"], [_, R, _, _]),
          (["but", "it", "can", "but", "it", "can", "hold"],
           [R, R, R, _, _, _, _])],
    119: [(["i", "if", "we"], [P, _, _])],
    128: [(["now", "as", "a", "as", "opposed"], [_, P, P, _, _])],
    129: [(["it", "m", "makes"], [_, P, _])],
    130: [(["generate", "their", "at", "their", "unique"], [_, P, P, _, _])],
    135: [(["to", "like", "segregate"], [_, F, _])],
    137: [(["yeah", "we", "you", "need"], [_, P, _, _])],
}

# --------------------------------------------------------------------------
# Correction-event specs. Key = index into the full event list (corrections +
# rejections + redictations, order of appearance in the flywheel — the same
# numbering the review dump used). Value = ops applied to the PAIRED POUR'S RAW
# text. Absent key => all-KEEP (the user reviewed the text and left it alone,
# so every word is human-verified content).
CORR_SPECS = {
    6:  [(["out", "it", "i", "genuinely"], [_, P, _, _])],      # user deleted "It"
    15: [(["finished", "um", "won't"], [_, F, _])],
    27: [(["work", "with"], [_, P])],                           # user cut dangling "with"
    44: [(["extremely", "deep", "and"], [_, _, P])],            # user cut dangling "and"
    46: [(["to", "uh", "break"], [_, F, _])],
    48: [(["whisper", "flow", "uh"], [_, _, F])],
    50: [(["here", "um", "i've"], [_, F, _])],
    72: [(["to", "compl", "be", "completely"], [_, P, _, _])],
    77: [(["do", "with", "with", "some"], [_, R, _, _]),
         (["right", "side", "side", "box"], [_, R, _, _])],
    79: [(["two", "uh", "different"], [_, F, _])],
    82: [(["work", "trees", "and"], [_, _, P])],                # user cut dangling "and"
    90: [(["kind", "or", "or", "maybe"], [_, R, _, _])],
}


def apply_ops(words, ops, tag):
    """Apply context-pattern ops to a word list, returning labels."""
    labels = ["KEEP"] * len(words)
    norm = [C.norm_word(w) for w in words]
    for pattern, ops_labels in ops:
        assert len(pattern) == len(ops_labels), f"{tag}: spec length mismatch"
        hits = [i for i in range(len(norm) - len(pattern) + 1)
                if norm[i:i + len(pattern)] == pattern]
        assert len(hits) == 1, (
            f"{tag}: pattern {pattern} matched {len(hits)} times (need exactly 1)")
        start = hits[0]
        for k, lab in enumerate(ops_labels):
            if lab is not None:
                assert labels[start + k] == "KEEP", f"{tag}: double-label at {start+k}"
                labels[start + k] = lab
    return labels


def build_record(rid, words, labels, gold_norm, tag):
    ok, why = C.validate_example(words, labels)
    assert ok, f"{tag}: {why}"
    rok, rwhy = C.repeat_invariant_ok(words, labels)
    assert rok, f"{tag}: repeat-invariant: {rwhy}"
    assert tuple(C.norm_tokens(words)) not in gold_norm, f"{tag}: OVERLAPS GOLD"
    return {"id": rid, "source": "real", "words": words, "labels": labels}


def main():
    pours, events = load_records()
    llm = [r for r in pours if r.get("tier") in ("apple", "local")]
    by_ts = {p.get("ts"): p for p in pours if p.get("ts")}
    corrections = [e for e in events if e.get("type") == "correction"]
    rejections = [e for e in events if e.get("type") == "rejection"]
    redictations = [e for e in events if e.get("type") == "redictation"]

    # Every pour 0..REVIEWED-1 was eyeballed in this run; an absent spec key is a
    # reviewed "all-KEEP" verdict, so the guard is on the count, not the keys.
    REVIEWED = 139
    print(f"llm-tier pours : {len(llm)}   (reviewed: {REVIEWED})")
    assert len(llm) == REVIEWED, (
        f"flywheel now has {len(llm)} LLM-tier pours but only {REVIEWED} were "
        f"hand-reviewed — re-review indices {REVIEWED}..{len(llm)-1} before running")

    gold = C.read_jsonl(os.path.join(C.DATA_DIR, "gold.jsonl"))
    gold_norm = {tuple(C.norm_tokens(g["words"])) for g in gold}

    out, seen_norm = [], set()
    discarded, dup_skipped = [], 0
    n_from_pours = n_from_corr = 0

    def emit(words, labels, tag):
        nonlocal dup_skipped
        key = tuple(C.norm_tokens(words))
        if not key or key in seen_norm:
            dup_skipped += 1
            return False
        seen_norm.add(key)
        rid = f"real3-{len(out):03d}"
        out.append(build_record(rid, words, labels, gold_norm, tag))
        return True

    # 1. LLM-tier pours
    for i, r in enumerate(llm):
        tag = f"pour[{i:03d}]"
        if i in POUR_SPECS and POUR_SPECS[i] is None:
            discarded.append((i, r["raw"]))
            continue
        words = r["raw"].split()
        labels = apply_ops(words, POUR_SPECS.get(i, []), tag)
        if emit(words, labels, tag):
            n_from_pours += 1
            ndel = sum(1 for l in labels if l != "KEEP")
            if ndel:
                deleted = [words[k] for k in range(len(words)) if labels[k] != "KEEP"]
                print(f"{tag} {ndel} del: {deleted}")

    # 2. Correction events -> the paired pour's RAW (human-verified content)
    for i, e in enumerate(events):
        if e.get("type") != "correction":
            continue
        tag = f"corr[{i:03d}]"
        p = by_ts.get(e.get("pourTs", ""))
        if p is None:
            continue
        words = (p.get("raw") or "").split()
        if not words:
            continue
        labels = apply_ops(words, CORR_SPECS.get(i, []), tag)
        if emit(words, labels, tag):
            n_from_corr += 1
            ndel = sum(1 for l in labels if l != "KEEP")
            if ndel:
                deleted = [words[k] for k in range(len(words)) if labels[k] != "KEEP"]
                print(f"{tag} {ndel} del: {deleted}")

    with open(OUT, "w", encoding="utf-8") as f:
        for rec in out:
            ok, why = C.validate_example(rec["words"], rec["labels"])
            assert ok, why
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    del_tok = sum(1 for r in out for l in r["labels"] if l != "KEEP")
    n_keep_only = sum(1 for r in out if all(l == "KEEP" for l in r["labels"]))
    from collections import Counter
    dist = Counter(l for r in out for l in r["labels"])
    print("=" * 70)
    print(f"llm-tier pours seen      : {len(llm)}")
    print(f"  discarded (reword)     : {len(discarded)}  {[d[0] for d in discarded]}")
    print(f"  emitted from pours     : {n_from_pours}")
    print(f"correction events        : {len(corrections)} "
          f"(rejections {len(rejections)}, redictations {len(redictations)} — not labelled)")
    print(f"  emitted from corrections: {n_from_corr}")
    print(f"duplicates skipped       : {dup_skipped}")
    print(f"real-v3 total            : {len(out)}")
    print(f"  with >=1 DELETE        : {len(out) - n_keep_only}")
    print(f"  all-KEEP               : {n_keep_only}")
    print(f"total tokens             : {sum(len(r['words']) for r in out)}")
    print(f"total DELETE tokens      : {del_tok}")
    for lab in C.LABELS:
        print(f"    {lab:<16}: {dist.get(lab, 0)}")
    print(f"wrote -> {OUT}")


if __name__ == "__main__":
    main()
