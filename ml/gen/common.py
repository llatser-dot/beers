"""Shared helpers for the Bouncer training-data pipeline.

Label scheme (see ml/DESIGN.md):
  KEEP, DEL_FILLER, DEL_REPEAT, DEL_REPARANDUM, DEL_INTERREGNUM

Contract: JSONL, one object per transcript:
  {"id", "source": "rule|llm|real", "words": [...], "labels": [...]}
  len(words) == len(labels); concatenating KEEP words reconstructs the
  intended clean text (modulo punctuation/casing seams).
"""
from __future__ import annotations
import json, os, re, sys, time, urllib.request, urllib.error, random

ML_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ML_DIR, "data")
CLEAN_DIR = os.path.join(DATA_DIR, "clean")

LABELS = ["KEEP", "DEL_FILLER", "DEL_REPEAT", "DEL_REPARANDUM", "DEL_INTERREGNUM"]
DEL_LABELS = {"DEL_FILLER", "DEL_REPEAT", "DEL_REPARANDUM", "DEL_INTERREGNUM"}

OLLAMA_URL = "http://127.0.0.1:11434/api/chat"
OLLAMA_MODEL = "gemma4:latest"

# ---------------------------------------------------------------------------
# Filler lexicon — calibrated against Ben's real logs.
# Multi-word fillers listed longest-first so matching is greedy.
FILLERS_MULTI = [
    "you know what i mean", "do you know what i mean", "you know",
    "sort of", "kind of", "i mean", "i guess", "or whatever", "or something",
    "at the end of the day", "if that makes sense",
]
FILLERS_SINGLE = [
    "um", "uh", "erm", "er", "uhh", "umm", "hmm", "like", "basically",
    "literally", "actually", "right", "so", "well", "okay", "obviously",
    "honestly", "essentially", "anyway",
]
# Interregnum (correction) markers for the LLM generator + rules.
INTERREGNUM_MARKERS = [
    "no wait", "wait no", "actually no", "actually", "scratch that",
    "i mean", "hang on", "hold on", "forget that", "sorry i mean",
    "no sorry", "or rather", "let me rephrase", "no",
]

# ---------------------------------------------------------------------------
# Word-level normalisation for the reconstruction invariant.
_PUNCT = ".,!?;:\"'`()[]{}…—-"

def norm_word(w: str) -> str:
    """Lowercase + strip surrounding punctuation for invariant checks."""
    return w.strip(_PUNCT).lower()

def norm_tokens(text_or_words) -> list[str]:
    if isinstance(text_or_words, str):
        toks = text_or_words.split()
    else:
        toks = list(text_or_words)
    out = [norm_word(w) for w in toks]
    return [t for t in out if t]

def validate_example(words, labels, clean_text=None) -> tuple[bool, str]:
    """Return (ok, reason). Enforces the DESIGN contract."""
    if len(words) != len(labels):
        return False, f"len mismatch {len(words)}!={len(labels)}"
    if not words:
        return False, "empty"
    for lb in labels:
        if lb not in LABELS:
            return False, f"bad label {lb!r}"
    if clean_text is not None:
        keep = [w for w, l in zip(words, labels) if l == "KEEP"]
        if norm_tokens(keep) != norm_tokens(clean_text):
            return False, "KEEP words do not reconstruct clean text"
    return True, "ok"

# ---------------------------------------------------------------------------
# Protected "voice" words (gold-review.md judgment calls #1 and #5). These
# carry Ben's register and are KEEP whenever they are used as an
# intensifier / hedge / discourse connective. They may only ever be DELETE
# inside a genuine self-correction span (DEL_REPARANDUM: an abandoned clause
# that happens to contain them) or a genuine correction-interregnum
# ("...Wednesday, actually Tuesday" -> "actually" = DEL_INTERREGNUM), or as
# the deleted FIRST copy of an immediate repeat (DEL_REPEAT). They must NEVER
# be a standalone DEL_FILLER — that is the label-poison this guard prevents.
PROTECTED_VOICE_SINGLE = {"literally", "genuinely", "actually"}
PROTECTED_VOICE_PHRASES = [("or", "whatever")]

def is_protected_voice_at(words, i) -> int:
    """If a protected voice word/phrase starts at index i, return its token
    length (1 or 2); else 0. Uses normalised matching."""
    ni = norm_word(words[i])
    if ni in PROTECTED_VOICE_SINGLE:
        return 1
    if i + 1 < len(words):
        pair = (ni, norm_word(words[i + 1]))
        if pair in PROTECTED_VOICE_PHRASES:
            return 2
    return 0

# ---------------------------------------------------------------------------
# Repeat invariant (bug A). The generators emit an immediate repeat by
# DELETING the FIRST copy and KEEPING exactly one intact copy that follows.
# Two failure modes poison the "delete-both-copies" behaviour we saw in v2:
#   1. a DEL_REPEAT run not immediately followed by its intact KEEP twin
#      (fragmented / wrong-copy);
#   2. an immediate repeat hidden inside a non-REPEAT deletion — a
#      DEL_INTERREGNUM/DEL_FILLER token that duplicates the very next KEEP
#      word (gemma often restates the corrected value inside the marker,
#      e.g. "...no wait it was David | David at ...").
def repeat_invariant_ok(words, labels) -> tuple[bool, str]:
    n = len(labels)
    # (1) every DEL_REPEAT run is followed by an identical intact KEEP copy.
    i = 0
    while i < n:
        if labels[i] == "DEL_REPEAT":
            j = i
            while j + 1 < n and labels[j + 1] == "DEL_REPEAT":
                j += 1
            L = j - i + 1
            unit = [norm_word(w) for w in words[i:j + 1]]
            foll = words[j + 1:j + 1 + L]
            foll_l = labels[j + 1:j + 1 + L]
            if (len(foll) != L or any(x != "KEEP" for x in foll_l)
                    or [norm_word(w) for w in foll] != unit):
                return False, f"DEL_REPEAT run at {i} lacks an intact KEEP copy"
            i = j + 1
        else:
            i += 1
    # (2) no interregnum/filler token immediately duplicates the next KEEP
    #     word (that is a repeat mislabelled as a non-REPEAT deletion).
    for k in range(n - 1):
        if labels[k] in ("DEL_INTERREGNUM", "DEL_FILLER") and labels[k + 1] == "KEEP":
            a = norm_word(words[k])
            if a and a == norm_word(words[k + 1]):
                return False, f"non-REPEAT DEL at {k} duplicates following KEEP"
    return True, "ok"

def normalize_hidden_repeats(labels, words) -> int:
    """In-place fix for failure mode (2): relabel any DEL_INTERREGNUM/
    DEL_FILLER token that duplicates the immediately-following KEEP word to
    DEL_REPEAT (the correct subtype for a deleted first copy). All DEL_*
    collapse to DELETE at inference, so this never changes the KEEP set and
    the reconstruction invariant is preserved. Returns the number fixed."""
    n = len(labels)
    fixed = 0
    for k in range(n - 1):
        if labels[k] in ("DEL_INTERREGNUM", "DEL_FILLER") and labels[k + 1] == "KEEP":
            a = norm_word(words[k])
            if a and a == norm_word(words[k + 1]):
                labels[k] = "DEL_REPEAT"
                fixed += 1
    return fixed

# ---------------------------------------------------------------------------
# Ollama native chat client.
def ollama_chat(messages, *, temperature=0.9, timeout=120, retries=3,
                fmt=None):
    payload = {
        "model": OLLAMA_MODEL,
        "messages": messages,
        "stream": False,
        "think": False,
        "keep_alive": "30m",
        "options": {"temperature": temperature},
    }
    if fmt is not None:
        payload["format"] = fmt
    data = json.dumps(payload).encode()
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                OLLAMA_URL, data=data,
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                obj = json.loads(r.read().decode())
            return obj.get("message", {}).get("content", "")
        except Exception as e:  # noqa
            last = e
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"ollama failed after {retries}: {last}")

def extract_json(text: str):
    """Pull the first JSON object/array out of a model response."""
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n?", "", text)
        text = re.sub(r"\n?```$", "", text).strip()
    # direct
    try:
        return json.loads(text)
    except Exception:
        pass
    # find first {...} or [...]
    for opn, cls in (("[", "]"), ("{", "}")):
        i = text.find(opn)
        if i < 0:
            continue
        depth = 0
        for j in range(i, len(text)):
            if text[j] == opn:
                depth += 1
            elif text[j] == cls:
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(text[i:j + 1])
                    except Exception:
                        break
    return None

# ---------------------------------------------------------------------------
# JSONL checkpoint helpers.
def load_seen_ids(path: str) -> set[str]:
    seen = set()
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    seen.add(json.loads(line)["id"])
                except Exception:
                    pass
    return seen

def append_jsonl(path: str, obj: dict):
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")

def read_jsonl(path: str):
    out = []
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out

# ---------------------------------------------------------------------------
# Real-material loaders.
def load_pours():
    p = os.path.expanduser("~/Library/Application Support/Beers/pours.json")
    with open(p, encoding="utf-8") as f:
        rows = json.load(f)
    return [r["text"].strip() for r in rows if r.get("text", "").strip()]

def load_real_log():
    """Return the polished-transcription lines (deduped) from the log."""
    path = "/tmp/beers.log"
    if not os.path.exists(path):
        return []
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    out, seen = [], set()
    for l in lines:
        if "polished transcription=" not in l:
            continue
        m = re.search(r"polished transcription='(.*)'\s*$", l) or \
            re.search(r"polished transcription='(.*)", l)
        t = (m.group(1) if m else "").strip()
        if len(t) >= 2 and t not in seen:
            seen.add(t)
            out.append(t)
    return out
