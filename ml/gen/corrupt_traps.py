"""Hard-negative trap generator — KEEP-labeled lookalikes.

v1 gold failure analysis: every false DELETE on gold was a synthetic-lookalike
trap (legit "then and then", sentence-initial "Also, so", garbled-ASR function
words, repair sharing words with the reparandum). This module generates the
KEEP side of those patterns so the model learns which deletions-lookalikes
must survive. All calibrated to data/gold-review.md judgment calls.

Categories (record field "cat"):
  t1_repeat   legit adjacent repeats + emphatic appositions      (all KEEP)
  t2_opener   sentence-initial connectives Ben keeps             (all KEEP)
  t3_content  filler-lookalike words in content senses           (all KEEP)
  t4_garble   unpatterned ASR-noise function words               (all KEEP)
  t5_restart  truncated false start whose repair must stay KEEP  (mostly KEEP)

Output: data/traps.jsonl. Records carry "seed" = the clean-corpus sentence a
trap was derived from (build_dataset splits train/val by seed, so a seed and
all its decorated variants land on the same side).

Usage:
  python gen/corrupt_traps.py rules          # t1..t5 rule-based (fast)
  python gen/corrupt_traps.py gemma 400      # +N gemma t3 sentences (resumable)
  python gen/corrupt_traps.py all
"""
from __future__ import annotations
import sys, os, re, random, json, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
import build_corpus as B

OUT = os.path.join(C.DATA_DIR, "traps.jsonl")
rng = random.Random(4242)

_TRAIL = ".,!?;:"
def _strip(w): return w.strip(_TRAIL)

def _mk_id(words, cat):
    h = hashlib.sha1((cat + "|" + " ".join(words)).encode()).hexdigest()[:12]
    return f"trap-{h}"

def _rec(text_or_words, labels, cat, seed=None):
    words = text_or_words.split() if isinstance(text_or_words, str) else list(text_or_words)
    if labels == "KEEP":
        labels = ["KEEP"] * len(words)
    ok, why = C.validate_example(words, labels)
    if not ok:
        return None
    r = {"id": _mk_id(words, cat), "source": "trap", "cat": cat,
         "words": words, "labels": labels}
    if seed:
        r["seed"] = seed
    return r

def pick(seq):
    return rng.choice(seq)

def _corpus_sentences(min_w=4, max_w=40):
    """Clean-corpus sentences to decorate (seed tracking preserved)."""
    out = []
    for fn in ("template.txt", "ollama.txt", "seed_pours.txt"):
        p = os.path.join(C.CLEAN_DIR, fn)
        if not os.path.exists(p):
            continue
        for line in open(p, encoding="utf-8"):
            t = " ".join(line.split()).strip()
            if min_w <= len(t.split()) <= max_w:
                out.append(t)
    rng.shuffle(out)
    return out

# ===========================================================================
# t1 — legit adjacent repeats + emphatic appositions (all KEEP)
# ===========================================================================
T1_TEMPLATES = [
    # "then and then" — sequencing (gold-017: "for me then and then I'll paste")
    "Save that for me then and then I'll {act2}.",
    "Run the audit first then and then we can {act2}.",
    "Get {name} to sign it off then and then push it live.",
    "Check the backlinks then and then decide if it's worth {money}.",
    # "that that" — complementiser + demonstrative
    "I think that that domain is worth a punt.",
    "It's clear that that council is the slowest in the country.",
    "You said that that approach wouldn't scale, remember?",
    "The problem is that that page has no internal links.",
    # "had had" — pluperfect
    "The domain had had no traffic since 2019.",
    "If we had had the Ahrefs data earlier we'd have skipped it.",
    "By the time I checked, the site had had three owners.",
    # "is is" / "was is" — clausal subject
    "The thing is, is that the sitemap never got submitted.",
    "What it is is a thin content problem.",
    "Where the money is is in the {trade} verticals.",
    # "do do" — clause boundary
    "Whatever you do, do it before the deploy window closes.",
    "If you do, do you think it'll actually rank?",
    "What we normally do, do you reckon it applies here?",
    # "it it" style boundary / "in in"
    "If the crawler finds it, it gets flagged the same day.",
    "Before you paste it, it needs the tracking parameters.",
    # intensifier doubling
    "The Oracle box is very, very slow tonight.",
    "That audit was really, really thorough, credit to {name}.",
    "It's a very, very thin margin on the {money} tier.",
    # emphatic apposition (gold-029: "my Discord, my Hermes Discord")
    "Post the snipes in my Discord, my Hermes Discord, every morning.",
    "Run it through the config, the SEO config, before it goes out.",
    "Send it to the channel, the leads channel, not general.",
    "Check the report, the backlinks report, before the call with {name}.",
    "I mean the pipeline, the REVIV pipeline, not the trading one.",
    "Ask Dave, Dave from the dev team, about the schema markup.",
    "Use the key, the live Stripe key, for this one.",
    # parallel rhetorical structure (gold-025, NOT a repeat)
    "How do we get there earlier, how do we get there first?",
    "Why is it slow, why is it always slow on Mondays?",
    "What ranks in {council}, what ranks anywhere these days?",
]

def _pad(s: str) -> str:
    """Optionally append a normal filled template sentence so trap patterns
    appear inside longer multi-sentence transcripts too (and to expand
    combinatorics past the trap templates' own slot space)."""
    roll = rng.random()
    if roll < 0.40:
        return s
    extra = B.fill(pick(B.TEMPLATES))
    if roll < 0.70:
        return s + " " + extra
    return extra + " " + s

def gen_t1(target=900):
    out, seen = [], set()
    tries = 0
    while len(out) < target and tries < target * 40:
        tries += 1
        tpl = pick(T1_TEMPLATES).replace("{act2}", pick(
            ["paste it into the sheet", "sort the invoices", "ping the client",
             "review the stats", "kick off the crawl", "check the rankings"]))
        s = _pad(B.fill(tpl))
        if s.lower() in seen:
            continue
        seen.add(s.lower())
        r = _rec(s, "KEEP", "t1_repeat")
        if r:
            out.append(r)
    return out

# ===========================================================================
# t2 — sentence-initial connectives KEPT (gold judgment call #1)
# ===========================================================================
T2_OPENERS = [
    ("Okay,", 5), ("So", 4), ("Also, so", 2), ("Right,", 3), ("See,", 3),
    ("Again,", 3), ("I mean", 2), ("Okay then", 2), ("Also,", 3),
    ("Well,", 2), ("Basically,", 2), ("Look,", 2), ("Anyway,", 2),
]

def gen_t2(target=1200):
    sents = _corpus_sentences(3, 35)
    ops = [o for o, w in T2_OPENERS for _ in range(w)]
    out, seen = [], set()
    for base in sents:
        if len(out) >= target:
            break
        op = pick(ops)
        # lowercase the base's first word after a connective opener
        bw = base.split()
        w0 = bw[0]
        if w0[:1].isupper() and not w0.isupper():
            bw[0] = w0[0].lower() + w0[1:]
        s = op + " " + " ".join(bw)
        if s.lower() in seen:
            continue
        seen.add(s.lower())
        r = _rec(s, "KEEP", "t2_opener", seed=base)
        if r:
            out.append(r)
    return out

# ===========================================================================
# t3 — filler-lookalike words in content senses (all KEEP)
# ===========================================================================
T3_TEMPLATES = [
    # like = verb / such-as / comparative (gold-013)
    "I like the new {proj} design, ship it.",
    "It looks like the sitemap is broken again.",
    "Companies like Whisperflow use a script for exactly this.",
    "What's the mobile version like on {url}?",
    "We'd like {name} to review the {file} first.",
    "Domains like that never pass the vetting.",
    "I'd like ten more leads like the {council} ones.",
    # you know = literal knowledge
    "Do you know the password for the Oracle box?",
    "Do you know what the DR is on that domain?",
    "You know the drill, run the preflight first.",
    "Do you know when {name} is back from leave?",
    "You know that marketplace I mentioned? Scrape it.",
    # right = direction / correctness / confirmation
    "Put the CTA on the right side of the hero.",
    "That's right, deploy it tonight.",
    "The right domain makes all the difference here.",
    "Am I right in thinking the cron runs at ten?",
    "The nav collapses on the right at tablet width.",
    "Pick the right council or the odds are useless.",
    # actually = genuine contrast/emphasis
    "The traffic actually doubled after the migration.",
    "What actually happened to the {council} rankings?",
    "It's actually cheaper than DataForSEO for backlinks.",
    "I want them to actually have authority of some kind.",
    "Did the fix actually go live or just get committed?",
    # literally = emphasis, Ben's voice (gold #5)
    "The scraper literally returns nothing after midnight.",
    "It's literally a one-line fix in the middleware.",
    "I literally have an entire project for {url} already.",
    "We're literally just rearranging and rewriting words.",
    "There are literally two hundred orphan pages on there.",
    # sort/kind = classification (gold-006 "this kind of thing")
    "What sort of budget are we talking for {proj}?",
    "That's the sort of domain we want in the portfolio.",
    "Sort the list by referring domains, descending.",
    "What kind of authority does {url} actually have?",
    "See for this kind of thing we need a tiny model.",
    "This kind of lead converts at triple the rate.",
    # basically = genuine summary opener
    "Basically, the whole funnel is broken and we need to rebuild it.",
    "Basically the council data is stale from March onwards.",
    # so = degree / result / "so far"
    "So far the {trade} vertical is beating everything else.",
    "The build is so slow it times out the runner.",
    "Make it so the form validates before submit.",
    "It costs so much more than the {money} we budgeted.",
    # well = adverb/noun
    "The site performs well on mobile now.",
    "That audit went down well with the client.",
    "The migration went well, no dropped rankings.",
    # I mean = genuine explanation opener (gold-003)
    "I mean it's gotten too caught up in {proj} and {trade}.",
    "I mean the whole point is the authority, not the traffic.",
    # or whatever = genuine dismissive content (gold keeps these)
    "It doesn't have to be services or whatever, any niche works.",
    "Extensions or whatever, however you've done it, broaden it.",
]

def gen_t3_templates(target=700):
    out, seen = [], set()
    tries = 0
    while len(out) < target and tries < target * 40:
        tries += 1
        s = _pad(B.fill(pick(T3_TEMPLATES)))
        if s.lower() in seen:
            continue
        seen.add(s.lower())
        r = _rec(s, "KEEP", "t3_content")
        if r:
            out.append(r)
    return out

GEMMA_SYS = (
    "You generate CLEAN dictation transcripts for a busy UK software "
    "entrepreneur (SEO, web dev, lead generation, planning data, trading "
    "bots). Informal British English, UK spellings, direct tone. Each "
    "sentence must use the REQUIRED WORD in its CONTENT sense (not as a "
    "verbal filler): 'like' as verb/such-as, 'you know' as literal knowing, "
    "'right' as direction/correctness, 'actually'/'literally' as genuine "
    "emphasis, 'sort of'/'kind of' as classification, 'basically' opening a "
    "real summary, 'so' as degree/result, 'well' as adverb. No filler usage, "
    "no self-corrections, no um/uh. Output valid JSON only."
)
GEMMA_TASK = ("Write {k} different clean transcripts (5-30 words each), every "
              "one using the word/phrase \"{word}\" in a CONTENT sense as "
              "described. Return ONLY a JSON array of strings.")
GEMMA_WORDS = ["like", "you know", "right", "actually", "literally",
               "sort of", "kind of", "basically", "so", "well"]

def gen_t3_gemma(target, existing_texts):
    out = []
    seen = set(existing_texts)
    fails = 0
    while len(out) < target and fails < 25:
        word = pick(GEMMA_WORDS)
        k = rng.randint(15, 22)
        try:
            resp = C.ollama_chat(
                [{"role": "system", "content": GEMMA_SYS},
                 {"role": "user", "content": GEMMA_TASK.format(k=k, word=word)}],
                temperature=1.0, fmt="json")
        except Exception as e:
            print("[traps-gemma] error", e); fails += 1
            continue
        arr = C.extract_json(resp)
        if isinstance(arr, dict):
            for v in arr.values():
                if isinstance(v, list):
                    arr = v; break
        if not isinstance(arr, list):
            fails += 1
            continue
        added = 0
        seen_ids = C.load_seen_ids(OUT)
        for s in arr:
            if not isinstance(s, str):
                continue
            s = " ".join(s.split()).strip()
            wlen = len(s.split())
            if wlen < 4 or wlen > 40:
                continue
            if word not in s.lower():
                continue  # must actually contain the target word
            if s.lower() in seen:
                continue
            seen.add(s.lower())
            r = _rec(s, "KEEP", "t3_content")
            if r and r["id"] not in seen_ids:
                C.append_jsonl(OUT, r)  # incremental: crash-safe resume
                out.append(r); added += 1
                if len(out) >= target:
                    break
        print(f"[traps-gemma] +{added} ({len(out)}/{target}) word={word}")
    return out

# ===========================================================================
# t4 — garbled-ASR simulation: unpatterned function-word noise, all KEEP
#      (gold-016 "subscription for in using Claude" -> keep everything)
# ===========================================================================
_NOISE_WORDS = ["for", "in", "of", "to", "the", "a", "on", "it", "is", "and",
                "at", "as", "be", "or"]

def gen_t4(target=900):
    sents = _corpus_sentences(5, 35)
    out, seen = [], set()
    for base in sents:
        if len(out) >= target:
            break
        bw = base.split()
        n_ins = rng.choices([1, 2], weights=[6, 4])[0]
        words = list(bw)
        for _ in range(n_ins):
            pos = rng.randint(1, len(words) - 1)  # interior only
            noise = pick(_NOISE_WORDS)
            # avoid creating an exact adjacent duplicate (that's DEL_REPEAT
            # territory and would poison the repeat signal)
            if _strip(words[pos - 1]).lower() == noise or \
               (pos < len(words) and _strip(words[pos]).lower() == noise):
                continue
            words.insert(pos, noise)
        if words == bw:
            continue
        s = " ".join(words)
        if s.lower() in seen:
            continue
        seen.add(s.lower())
        r = _rec(words, "KEEP", "t4_garble", seed=base)
        if r:
            out.append(r)
    return out

# ===========================================================================
# t5 — truncated false start; the repair SHARES WORDS and must stay KEEP
#      (gold-035 "What do you m and also what do you mean API")
# ===========================================================================
def gen_t5(target=600):
    sents = _corpus_sentences(6, 35)
    out, seen = [], set()
    for base in sents:
        if len(out) >= target:
            break
        bw = base.split()
        # choose a clause start: index 0 or the word after . ? !
        starts = [0] + [i + 1 for i, w in enumerate(bw[:-3])
                        if w and w[-1] in ".?!"]
        i = pick(starts)
        k = rng.randint(2, min(4, len(bw) - i - 1))
        span = [_strip(w) for w in bw[i:i + k]]
        last = span[-1]
        if len(last) < 4 or not last.isalpha():
            continue
        # truncate the last word to a 1-2 char fragment ("mean" -> "m")
        frag = last[:rng.randint(1, 2)]
        rep = span[:-1] + [frag]
        words = bw[:i] + rep + bw[i:]
        labels = (["KEEP"] * i + ["DEL_REPARANDUM"] * len(rep)
                  + ["KEEP"] * (len(bw) - i))
        s = " ".join(words)
        if s.lower() in seen:
            continue
        seen.add(s.lower())
        ok, why = C.validate_example(words, labels, base)
        if not ok:
            continue
        r = {"id": _mk_id(words, "t5_restart"), "source": "trap",
             "cat": "t5_restart", "words": words, "labels": labels,
             "seed": base, "clean": base}
        out.append(r)
    return out

# ===========================================================================
def write_all(records):
    seen = C.load_seen_ids(OUT)
    added = 0
    for r in records:
        if r["id"] in seen:
            continue
        seen.add(r["id"])
        C.append_jsonl(OUT, r)
        added += 1
    print(f"[traps] appended {added} (file now "
          f"{sum(1 for _ in open(OUT, encoding='utf-8'))})")

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"
    if cmd in ("rules", "all"):
        recs = []
        recs += gen_t1(900)
        recs += gen_t2(1200)
        recs += gen_t3_templates(700)
        recs += gen_t4(900)
        recs += gen_t5(600)
        from collections import Counter
        print("[traps] rule-based:", Counter(r["cat"] for r in recs))
        write_all(recs)
    if cmd in ("gemma", "all"):
        target = int(sys.argv[2]) if len(sys.argv) > 2 else 400
        existing = set()
        if os.path.exists(OUT):
            for l in open(OUT, encoding="utf-8"):
                try:
                    existing.add(" ".join(json.loads(l)["words"]).lower())
                except Exception:
                    pass
        recs = gen_t3_gemma(target, existing)
        write_all(recs)

if __name__ == "__main__":
    main()
