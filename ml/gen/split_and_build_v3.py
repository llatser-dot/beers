#!/usr/bin/env python3
"""Split real-v3.jsonl 60/20/20 (seed 42) and build train-v3.jsonl.

  real-train-v3.jsonl  60%  -> mixed into training, upweighted 3x
  real-cal.jsonl       20%  -> threshold calibration (step 6)
  real-test.jsonl      20%  -> held-out exam #2 (step 7)

train-v3.jsonl = existing synthetic train.jsonl (exactly what v2 saw)
                 + 3x real-train-v3  (isolates the "real trickle" delta over v2)
val stays the existing synthetic val.jsonl (same early-stop recipe as v2).
gold.jsonl is FROZEN, untouched.
"""
import json, os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

D = C.DATA_DIR
REAL = os.path.join(D, "real-v3.jsonl")
UPWEIGHT = 3

def del_tokens(recs):
    return sum(1 for r in recs for l in r["labels"] if l != "KEEP")

def main():
    real = C.read_jsonl(REAL)
    n = len(real)
    idx = list(range(n))
    random.Random(42).shuffle(idx)
    n_train = round(0.60 * n)
    n_cal = round(0.20 * n)
    n_test = n - n_train - n_cal
    tr_i = idx[:n_train]
    cal_i = idx[n_train:n_train + n_cal]
    test_i = idx[n_train + n_cal:]
    assert not (set(tr_i) & set(cal_i)) and not (set(cal_i) & set(test_i)) and not (set(tr_i) & set(test_i))

    real_train = [real[i] for i in tr_i]
    real_cal = [real[i] for i in cal_i]
    real_test = [real[i] for i in test_i]

    for name, recs in (("real-train-v3", real_train), ("real-cal", real_cal), ("real-test", real_test)):
        p = os.path.join(D, name + ".jsonl")
        with open(p, "w", encoding="utf-8") as f:
            for r in recs:
                ok, why = C.validate_example(r["words"], r["labels"]); assert ok, why
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    # build train-v3 = synthetic train + 3x real-train
    syn_train = C.read_jsonl(os.path.join(D, "train.jsonl"))
    out = list(syn_train)
    for k in range(UPWEIGHT):
        for r in real_train:
            rr = dict(r); rr["id"] = f"{r['id']}-x{k}"
            out.append(rr)
    random.Random(2026).shuffle(out)
    outp = os.path.join(D, "train-v3.jsonl")
    with open(outp, "w", encoding="utf-8") as f:
        for r in out:
            f.write(json.dumps({"id": r["id"], "source": r["source"],
                                "words": r["words"], "labels": r["labels"]}, ensure_ascii=False) + "\n")

    print(f"real-v3 total          : {n}")
    print(f"  train slice (60%)    : {len(real_train)}  ({del_tokens(real_train)} DEL tokens)")
    print(f"  real-cal (20%)       : {len(real_cal)}  ({del_tokens(real_cal)} DEL tokens)")
    print(f"  real-test (20%)      : {len(real_test)}  ({del_tokens(real_test)} DEL tokens)")
    print(f"real-train upweight    : {UPWEIGHT}x -> {len(real_train)*UPWEIGHT} added rows")
    print(f"synthetic train        : {len(syn_train)}")
    print(f"train-v3.jsonl total   : {len(out)}  -> {outp}")
    print(f"real-cal ids           : {[r['id'] for r in real_cal]}")
    print(f"real-test ids          : {[r['id'] for r in real_test]}")
    # per-transcript DEL counts in test
    print("real-test breakdown:")
    for r in real_test:
        nd = sum(1 for l in r["labels"] if l != "KEEP")
        print(f"    {r['id']}: {nd} DEL / {len(r['words'])} tok")

if __name__ == "__main__":
    main()
