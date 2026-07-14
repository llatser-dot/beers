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
    p = "~/Library/Application Support/Beers/pours.json"
    with open(p, encoding="utf-8") as f:
        rows = json.load(f)
    return [r["text"].strip() for r in rows if r.get("text", "").strip()]

def load_real_log():
    """Return the polished-transcription lines (deduped) from the log."""
    path = "/tmp/llatser-listen.log"
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
