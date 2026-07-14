"""LLM-driven self-correction generator (the semantically hard cases).

Strategy that makes labels mechanically derivable (per DESIGN.md):
  gemma4 returns STRUCTURED JSON describing a self-correction over a CLEAN
  sentence. We ASSEMBLE the corrupted transcript + labels in Python by
  INSERTING deletable tokens around the clean words. Because we never modify
  or drop a clean word, the KEEP-reconstruction invariant holds by
  construction; the only failure mode is a malformed generation, which we
  reject.

Two families:
  replace : an entity/number/word was mis-spoken then corrected.
            "send it to <wrong=Dave> <marker=no wait> Sarah by five"
            -> prefix KEEP | wrong DEL_REPARANDUM | marker DEL_INTERREGNUM
               | target+rest KEEP
  restart : an abandoned opening false start.
            "<wrong=let me just> <marker=actually> send the invoice today"
            -> wrong DEL_REPARANDUM | marker DEL_INTERREGNUM | clean KEEP

Usage:
  python gen/corrupt_llm.py pilot            # 200 examples -> llm_pilot.jsonl
  python gen/corrupt_llm.py full 6000        # -> llm.jsonl  (run under nohup)
Resume is automatic (seen-id set + JSONL append).
"""
from __future__ import annotations
import sys, os, re, random, json, time, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

OUT_FULL = os.path.join(C.DATA_DIR, "llm.jsonl")
OUT_PILOT = os.path.join(C.DATA_DIR, "llm_pilot.jsonl")

_TRAIL = ".,!?;:"
def _strip(w):
    return w.strip(_TRAIL)

SYS = (
    "You build training data for a SPEECH self-correction detector. You invent "
    "realistic spoken self-corrections that a busy UK software entrepreneur "
    "(SEO, web dev, local-business lead gen, planning-permission data, trading "
    "bots) makes while DICTATING voice notes. Informal British English, UK "
    "spellings, real-sounding names/numbers/URLs/products. Output MUST be valid "
    "JSON only, no prose."
)

TASK = """Produce {k} DIFFERENT spoken self-correction examples as a JSON array.
Each element is an object with these fields:

For a value/entity mind-change use type "replace":
  {{"type":"replace",
    "clean":"<the FINAL intended sentence, fully clean, no disfluencies>",
    "target":"<the exact word or short phrase from clean that got corrected TO - must appear verbatim in clean>",
    "wrong":"<what he mistakenly said FIRST instead of target - a different name/number/word of the same kind>",
    "marker":"<the correction phrase: no wait / wait no / actually / scratch that / I mean / hang on / sorry I mean / forget that>"}}

For an abandoned false-start use type "restart":
  {{"type":"restart",
    "clean":"<the FINAL intended sentence, fully clean>",
    "wrong":"<the abandoned opening phrase he started with then dropped>",
    "marker":"<correction phrase as above>"}}

Rules:
- clean is ALWAYS fully clean (no um/uh, no correction words inside it).
- For replace: target MUST be a verbatim substring of clean; wrong MUST differ from target.
- Make replacements semantically interesting: names, councils, numbers, money,
  domains, file names, priorities, decisions.
- Keep it in his register. Vary sentence length (4-40 words).
Theme hint: {theme}. Return ONLY the JSON array."""

THEMES = [
    "sending work to a team member then changing who", "changing a number or quantity",
    "changing a price or budget", "changing which council or location",
    "changing which domain or URL", "changing a deadline or day",
    "changing which project to prioritise", "changing a file or config name",
    "abandoning a thought and restarting", "changing a decision about deploying",
    "changing which tool to use", "changing an SEO tactic mid-sentence",
]

def _find_span(clean_words, target):
    """Return start index where target token-sequence occurs, else -1."""
    tw = [C.norm_word(t) for t in target.split()]
    tw = [t for t in tw if t]
    if not tw:
        return -1
    cw = [C.norm_word(w) for w in clean_words]
    hits = [i for i in range(0, len(cw) - len(tw) + 1) if cw[i:i + len(tw)] == tw]
    if len(hits) != 1:
        return -1  # not found, or ambiguous (appears twice) -> reject
    return hits[0]

def assemble(item, rng):
    """Turn one structured item into (words, labels, clean) or None."""
    typ = item.get("type")
    clean = " ".join(str(item.get("clean", "")).split()).strip()
    wrong = " ".join(str(item.get("wrong", "")).split()).strip()
    marker = " ".join(str(item.get("marker", "")).split()).strip()
    if not clean or not wrong or not marker:
        return None
    cw = clean.split()
    if len(cw) < 3 or len(cw) > 45:
        return None

    wrong_toks = [_strip(w) for w in wrong.split() if _strip(w)]
    marker_toks = [_strip(w) for w in marker.split() if _strip(w)]
    if not wrong_toks or not marker_toks or len(wrong_toks) > 8:
        return None

    # Precise ambiguity guard: reject only if the CHOSEN marker phrase also
    # occurs inside clean (that would put an identical phrase in both a KEEP
    # and a DEL_INTERREGNUM position -> contradictory supervision). A clean
    # sentence that merely contains "actually" as a normal adverb is fine.
    ncw = [C.norm_word(w) for w in cw]
    nmk = [C.norm_word(w) for w in marker_toks if C.norm_word(w)]
    if nmk:
        for i in range(0, len(ncw) - len(nmk) + 1):
            if ncw[i:i + len(nmk)] == nmk:
                return None
    # Also reject the strongest multi-word correction phrases anywhere in clean.
    low = " " + re.sub(r"[^a-z0-9\s]", " ", clean.lower()) + " "
    low = re.sub(r"\s+", " ", low)
    for m in ("no wait", "wait no", "scratch that", "sorry i mean"):
        if " " + m + " " in low:
            return None

    if typ == "replace":
        target = str(item.get("target", "")).strip()
        i = _find_span(cw, target)
        if i < 0:
            return None
        if C.norm_tokens(wrong) == C.norm_tokens(target):
            return None  # wrong must differ
        words, labels = [], []
        words += cw[:i]; labels += ["KEEP"] * i
        # optional hesitation filler before the mis-spoken value
        if rng.random() < 0.30:
            fil = rng.choice(["um,", "uh,", "erm,", "like,"])
            words.append(fil); labels.append("DEL_FILLER")
        words += wrong_toks; labels += ["DEL_REPARANDUM"] * len(wrong_toks)
        words += marker_toks; labels += ["DEL_INTERREGNUM"] * len(marker_toks)
        words += cw[i:]; labels += ["KEEP"] * (len(cw) - i)
    elif typ == "restart":
        if len(wrong_toks) < 2:
            return None
        words, labels = [], []
        # capitalise the abandoned opener
        wrong_toks = wrong_toks[:]
        wrong_toks[0] = wrong_toks[0][:1].upper() + wrong_toks[0][1:]
        words += wrong_toks; labels += ["DEL_REPARANDUM"] * len(wrong_toks)
        words += marker_toks; labels += ["DEL_INTERREGNUM"] * len(marker_toks)
        # lowercase clean's first word (casing seam, allowed) so it reads naturally
        cw2 = cw[:]
        core, tr = cw2[0], ""
        if core[:1].isupper() and not core.isupper():
            cw2[0] = core[0].lower() + core[1:]
        words += cw2; labels += ["KEEP"] * len(cw2)
        clean = " ".join(cw)  # invariant checked case-insensitively
    else:
        return None

    ok, reason = C.validate_example(words, labels, clean)
    if not ok:
        return None
    return words, labels, clean

def _mk_id(words):
    h = hashlib.sha1((" ".join(words)).encode()).hexdigest()[:12]
    return "llm-" + h

def run(out_path, target_n):
    seen = C.load_seen_ids(out_path)
    have = sum(1 for _ in open(out_path, encoding="utf-8")) if os.path.exists(out_path) else 0
    print(f"[llm] resuming: {have} examples, target {target_n}, seen-ids {len(seen)}")
    kept = have
    attempts = 0
    reject = 0
    t0 = time.time()
    fails = 0
    while kept < target_n:
        attempts += 1
        k = random.randint(20, 28)
        theme = random.choice(THEMES)
        msgs = [{"role": "system", "content": SYS},
                {"role": "user", "content": TASK.format(k=k, theme=theme)}]
        try:
            resp = C.ollama_chat(msgs, temperature=1.0, fmt="json")
        except Exception as e:
            print("[llm] ollama error", e); fails += 1
            if fails > 30:
                print("[llm] too many failures, stopping"); break
            continue
        arr = C.extract_json(resp)
        if isinstance(arr, dict):
            for v in arr.values():
                if isinstance(v, list):
                    arr = v; break
        if not isinstance(arr, list):
            reject += k
            continue
        rng = random.Random(attempts * 7919)
        for item in arr:
            if not isinstance(item, dict):
                reject += 1; continue
            res = assemble(item, rng)
            if res is None:
                reject += 1; continue
            words, labels, clean = res
            ex_id = _mk_id(words)
            if ex_id in seen:
                continue
            seen.add(ex_id)
            C.append_jsonl(out_path, {"id": ex_id, "source": "llm",
                                      "words": words, "labels": labels,
                                      "clean": clean})
            kept += 1
        if attempts % 5 == 0 or kept >= target_n:
            rate = reject / max(1, reject + (kept - have))
            el = time.time() - t0
            print(f"[llm] kept={kept}/{target_n} rejects={reject} "
                  f"reject_rate={rate:.0%} elapsed={el:.0f}s")
    print(f"[llm] done kept={kept} rejects={reject}")

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "pilot"
    if mode == "pilot":
        run(OUT_PILOT, 200)
    elif mode == "full":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 6000
        run(OUT_FULL, n)

if __name__ == "__main__":
    main()
