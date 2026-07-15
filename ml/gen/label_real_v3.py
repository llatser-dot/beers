#!/usr/bin/env python3
"""Hand-labelling of the flywheel LLM-tier pours + correction into real-v3.jsonl.

Decisions were made by a human-equivalent review of every raw->served alignment
(see report-20260715.md). DELETE maps are keyed by RAW word index. Everything
not in the map is KEEP. Follows gold-review.md precedent:
  - sentence-initial So/Okay/Also/Now/See = KEEP (Ben's voice)
  - literally/genuinely/actually = protected voice = KEEP
  - ASR garble = KEEP (don't delete on noise)
  - immediate repeats: first copy DEL_REPEAT, intact copy KEEP
  - cut-off non-word fragments (m/t/w/c/d/com) = DEL_REPARANDUM
  - cardinal rule: when unsure, KEEP.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

FLY = os.path.expanduser("~/Library/Application Support/Beers/flywheel.jsonl")
OUT = os.path.join(C.DATA_DIR, "real-v3.jsonl")

def load_llm_pours():
    recs = [json.loads(l) for l in open(FLY) if l.strip()]
    pours = [r for r in recs if "raw" in r and "served" in r
             and r.get("type") not in ("correction", "rejection", "redictation")]
    seen, uniq = set(), []
    for r in pours:
        k = (r.get("raw", ""), r.get("served", ""))
        if k in seen: continue
        seen.add(k); uniq.append(r)
    return [r for r in uniq if r.get("tier") in ("apple", "local")]

# DELETE maps keyed by raw-word index -> label. Index order = load_llm_pours order.
# (indices verified against the dump printed earlier)
DEL = {
 0:  {0:"DEL_FILLER",2:"DEL_FILLER",3:"DEL_REPEAT",8:"DEL_FILLER",10:"DEL_REPEAT",
      15:"DEL_REPARANDUM",16:"DEL_INTERREGNUM",17:"DEL_INTERREGNUM",
      18:"DEL_REPARANDUM",19:"DEL_REPARANDUM",20:"DEL_REPARANDUM",
      24:"DEL_FILLER",25:"DEL_FILLER"},
 1:  {36:"DEL_FILLER",37:"DEL_REPARANDUM",38:"DEL_REPARANDUM",39:"DEL_REPARANDUM",40:"DEL_REPARANDUM"},
 2:  {26:"DEL_REPARANDUM"},
 3:  {26:"DEL_REPARANDUM"},
 4:  {},                       # all-KEEP (raw==served)
 5:  {},                       # all-KEEP (only voice stripped by LLM)
 6:  {},                       # all-KEEP ("c" = address "C", not a fragment)
 7:  {22:"DEL_REPARANDUM"},
 8:  {},                       # all-KEEP
 9:  None,                     # DISCARD: heavy reword, ambiguous restart, profanity=KEEP
 10: {47:"DEL_REPARANDUM"},
 11: {0:"DEL_FILLER",2:"DEL_FILLER",3:"DEL_REPEAT",8:"DEL_FILLER",10:"DEL_REPEAT"},
 12: {0:"DEL_FILLER",4:"DEL_REPEAT"},
 13: {0:"DEL_FILLER",2:"DEL_FILLER",3:"DEL_REPEAT",8:"DEL_FILLER",10:"DEL_REPEAT"},
 14: {0:"DEL_FILLER",1:"DEL_REPEAT",4:"DEL_FILLER"},
 15: {},                       # all-KEEP (raw==served; emphatic content)
 16: {},                       # all-KEEP (leading So = voice)
 17: {10:"DEL_REPARANDUM",11:"DEL_REPARANDUM",12:"DEL_INTERREGNUM"},
 18: {12:"DEL_REPEAT"},
 19: {65:"DEL_REPARANDUM"},
 20: None,                     # placeholder -> fixed below by pattern (trailing 'to')
 21: None,                     # placeholder -> fixed below by pattern (com / m fragments)
 22: {},                       # all-KEEP (only punctuation)
 23: {},                       # all-KEEP
 24: {4:"DEL_REPEAT"},
 25: {0:"DEL_REPEAT"},
 26: {},                       # all-KEEP (ASR garble -> KEEP)
 27: {1:"DEL_REPARANDUM"},      # "Don't f apply" -> "f" cut-off fragment
}

def main():
    pours = load_llm_pours()
    print(f"llm-tier pours present now: {len(pours)} (labelled indices: 0..{max(DEL)})")
    excluded_new = [i for i in range(len(pours)) if i not in DEL]
    if excluded_new:
        print(f"WARNING excluding un-reviewed new pours: {excluded_new}")

    # gold overlap guard
    gold = C.read_jsonl(os.path.join(C.DATA_DIR, "gold.jsonl"))
    gold_norm = {tuple(C.norm_tokens(g["words"])) for g in gold}

    out = []
    discarded = []
    del_token_total = 0
    for i, r in enumerate(pours):
        if i not in DEL:
            continue
        words = r["raw"].split()
        dmap = DEL[i]

        # pattern-fixed placeholders (avoid hand-index errors on long transcripts)
        if i == 20:
            # trailing dangling 'to' right before 'Again,'
            dmap = {}
            for j in range(len(words) - 1):
                if words[j].strip(".,") == "to" and words[j+1] == "Again,":
                    dmap = {j: "DEL_REPARANDUM"}; break
        if i == 21:
            # cut-off fragments: 'com' before 'comparing', 'm' before 'editing,'
            dmap = {}
            for j in range(len(words) - 1):
                if words[j] == "com" and words[j+1] == "comparing":
                    dmap[j] = "DEL_REPARANDUM"
                if words[j] == "m" and words[j+1] == "editing,":
                    dmap[j] = "DEL_REPARANDUM"

        if dmap is None:
            discarded.append((i, r["raw"]))
            continue

        labels = ["KEEP"] * len(words)
        for idx, lab in dmap.items():
            assert 0 <= idx < len(words), f"[{i}] idx {idx} OOB (len {len(words)})"
            labels[idx] = lab

        ok, why = C.validate_example(words, labels)
        assert ok, f"[{i}] {why}"
        rok, rwhy = C.repeat_invariant_ok(words, labels)
        assert rok, f"[{i}] repeat-invariant: {rwhy}"

        # leakage guard
        assert tuple(C.norm_tokens(words)) not in gold_norm, f"[{i}] OVERLAPS GOLD"

        ndel = sum(1 for l in labels if l != "KEEP")
        del_token_total += ndel
        deleted = [words[k] for k in range(len(words)) if labels[k] != "KEEP"]
        keep = " ".join(words[k] for k in range(len(words)) if labels[k] == "KEEP")
        print(f"[{i:02d}] {ndel} del: {deleted}")
        print(f"      KEEP-> {keep}")
        out.append({"id": f"real3-{i:03d}", "source": "real", "words": words, "labels": labels})

    # correction event -> all-KEEP served transcript (fix was spelling/casing only)
    corr_words = "i think plan watch should rank for the planning keywords this month".split()
    corr_labels = ["KEEP"] * len(corr_words)
    assert tuple(C.norm_tokens(corr_words)) not in gold_norm
    out.append({"id": "real3-corr-000", "source": "real",
                "words": corr_words, "labels": corr_labels})
    print(f"[corr] all-KEEP: {' '.join(corr_words)}")

    with open(OUT, "w", encoding="utf-8") as f:
        for rec in out:
            ok, why = C.validate_example(rec["words"], rec["labels"])
            assert ok, why
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    n_keep_only = sum(1 for r in out if all(l == "KEEP" for l in r["labels"]))
    n_with_del = len(out) - n_keep_only
    print("=" * 70)
    print(f"llm-tier pours labelled  : {sum(1 for i in range(len(pours)) if i in DEL)}")
    print(f"discarded (reword/ambig) : {len(discarded)}  {[d[0] for d in discarded]}")
    print(f"correction transcripts   : 1")
    print(f"labelled real-v3 total   : {len(out)}")
    print(f"  with >=1 DELETE        : {n_with_del}")
    print(f"  all-KEEP               : {n_keep_only}")
    print(f"total DELETE tokens      : {del_token_total}")
    print(f"wrote -> {OUT}")

if __name__ == "__main__":
    main()
