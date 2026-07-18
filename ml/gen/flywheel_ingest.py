#!/usr/bin/env python3
"""Ingest the Beers flywheel log — the app's local capture of real dictation
pairs — into (raw, served) training material and a bouncer-shadow-vs-LLM
disagreement report.

The app writes one JSON record per served pour to
    ~/Library/Application Support/Beers/flywheel.jsonl
(plus rotated flywheel-<stamp>.jsonl siblings once the live file passes ~5 MB).
Two kinds of record share the file:
  POUR   {"ts", "raw", "rulePolished"|null, "served", "tier",
          "bouncerWouldDelete": [word indices]|null, "bouncerMs": float|null}
  EVENT  the user's keyboard fix of a pasted pour (CorrectionWatcher):
          {"ts", "type": "correction"|"rejection"|"redictation",
           "pourTs": <pour ts>, "app", "served", "corrected"|null,
           "changedWords": [[index, "old", "new"|null], ...]}
          (redictation events instead carry {"pourTs", "newPourTs"}).

This reads those files IN PLACE (they never leave the user's machine), dedupes,
and prints a summary. It does NOT touch ml/data/*.jsonl — piping into the
training corpus is a deliberate, separate step.

stdlib only. Python 3.

Usage:
    flywheel_ingest.py                       # default Application Support path
    flywheel_ingest.py --path /some/dir      # dir of flywheel*.jsonl
    flywheel_ingest.py --path file.jsonl     # a single log file
    flywheel_ingest.py --emit-clean out.txt  # write served texts, one/line
    flywheel_ingest.py --emit-clean -        # ...to stdout
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter

DEFAULT_DIR = os.path.expanduser("~/Library/Application Support/Beers")
LOG_GLOB_PREFIX = "flywheel"  # flywheel.jsonl + flywheel-<stamp>.jsonl
EVENT_TYPES = ("correction", "rejection", "redictation")


def is_event(r: dict) -> bool:
    return r.get("type") in EVENT_TYPES


def is_pour(r: dict) -> bool:
    # Pour records carry raw+served and no event type.
    return "raw" in r and "served" in r and r.get("type") not in EVENT_TYPES


def resolve_files(path: str) -> list[str]:
    """A file -> [file]; a directory -> every flywheel*.jsonl inside it."""
    if os.path.isfile(path):
        return [path]
    if os.path.isdir(path):
        files = [
            os.path.join(path, name)
            for name in sorted(os.listdir(path))
            if name.startswith(LOG_GLOB_PREFIX) and name.endswith(".jsonl")
        ]
        return files
    return []


def load_records(files: list[str]) -> tuple[list[dict], int]:
    """Return (valid records, malformed line count)."""
    records: list[dict] = []
    malformed = 0
    for fpath in files:
        try:
            with open(fpath, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        malformed += 1
                        continue
                    if isinstance(obj, dict) and (is_pour(obj) or is_event(obj)):
                        records.append(obj)
                    else:
                        malformed += 1
        except OSError as exc:
            print(f"warning: could not read {fpath}: {exc}", file=sys.stderr)
    return records, malformed


def dedupe(records: list[dict]) -> list[dict]:
    """Collapse identical (raw, served) pairs, keeping first occurrence."""
    seen: set[tuple[str, str]] = set()
    unique: list[dict] = []
    for r in records:
        key = (r.get("raw", ""), r.get("served", ""))
        if key in seen:
            continue
        seen.add(key)
        unique.append(r)
    return unique


def llm_tier(tier: str) -> bool:
    return tier in ("apple", "local")


def disagreement_stats(records: list[dict]) -> dict:
    """Bouncer shadow vs. what actually served.

    For records where the shadow ran (bouncerWouldDelete is not null) we compare
    two independent opinions on whether the pour needed cleaning:
      - shadow "fired" = it proposed >= 1 deletion
      - the served text differs from raw (something was removed/reworded)
    On LLM-served pours (apple/local) the served text is the closest thing to a
    ground-truth clean, so the 2x2 below is the useful disagreement signal.
    """
    shadow_ran = [r for r in records if isinstance(r.get("bouncerWouldDelete"), list)]
    fired = [r for r in shadow_ran if len(r["bouncerWouldDelete"]) > 0]

    # 2x2 on LLM-served pours: shadow fired? vs. LLM changed the text?
    both_dirty = shadow_miss = shadow_eager = both_clean = 0
    for r in shadow_ran:
        if not llm_tier(r.get("tier", "")):
            continue
        s_fired = len(r["bouncerWouldDelete"]) > 0
        llm_changed = r.get("raw", "") != r.get("served", "")
        if s_fired and llm_changed:
            both_dirty += 1
        elif not s_fired and llm_changed:
            shadow_miss += 1
        elif s_fired and not llm_changed:
            shadow_eager += 1
        else:
            both_clean += 1

    ms = [r["bouncerMs"] for r in shadow_ran if isinstance(r.get("bouncerMs"), (int, float))]
    total_del = sum(len(r["bouncerWouldDelete"]) for r in fired)

    return {
        "shadow_ran": len(shadow_ran),
        "shadow_fired": len(fired),
        "total_proposed_deletions": total_del,
        "avg_bouncer_ms": (sum(ms) / len(ms)) if ms else None,
        "llm_both_dirty": both_dirty,
        "llm_shadow_miss": shadow_miss,
        "llm_shadow_eager": shadow_eager,
        "llm_both_clean": both_clean,
    }


def _words(s: str) -> list[str]:
    return (s or "").split()


def correction_stats(pours: list[dict], events: list[dict]) -> dict:
    """Pair correction/rejection/redictation events to their pour via pourTs.

    - corrections harvested / rejection count / redictation count
    - top corrected word pairs (old -> new)
    - AI-tier fixes vs pure-ASR fixes: for each correction, decide whether the
      word(s) being fixed were introduced by the AI/rule tier (i.e. NOT present
      in the pour's raw ASR text) or were already in the raw (a pure-ASR fix).
    """
    by_ts: dict[str, dict] = {}
    for p in pours:
        ts = p.get("ts")
        if ts:
            by_ts[ts] = p

    corrections = [e for e in events if e.get("type") == "correction"]
    rejections = [e for e in events if e.get("type") == "rejection"]
    redictations = [e for e in events if e.get("type") == "redictation"]

    pairs: Counter = Counter()
    ai_tier = pure_asr = unpaired = 0

    for e in corrections:
        # Top corrected word pairs (skip pure insertions with empty old).
        for ch in e.get("changedWords") or []:
            if not isinstance(ch, list) or len(ch) < 3:
                continue
            old, new = ch[1], ch[2]
            if new is None:
                continue
            if str(old).strip() == "":
                continue
            pairs[(str(old), str(new))] += 1

        # AI-tier vs pure-ASR: compare the fixed old-words against the pour raw.
        pour = by_ts.get(e.get("pourTs", ""))
        if pour is None:
            unpaired += 1
            continue
        raw_words = {w.lower() for w in _words(pour.get("raw", ""))}
        old_words = [str(ch[1]) for ch in (e.get("changedWords") or [])
                     if isinstance(ch, list) and len(ch) >= 2 and str(ch[1]).strip() != ""]
        # If any fixed word was NOT in the raw ASR text, the AI/rule tier put it
        # there -> the user is correcting an AI-tier edit. Otherwise pure-ASR.
        if any(w.lower() not in raw_words for w in old_words):
            ai_tier += 1
        else:
            pure_asr += 1

    redictated_ts = {e.get("pourTs") for e in redictations}

    return {
        "corrections": len(corrections),
        "rejections": len(rejections),
        "redictations": len(redictations),
        "redictation_paired": sum(1 for ts in redictated_ts if ts in by_ts),
        "top_pairs": pairs.most_common(15),
        "fix_ai_tier": ai_tier,
        "fix_pure_asr": pure_asr,
        "fix_unpaired": unpaired,
    }


def bar(n: int, total: int, width: int = 24) -> str:
    if total <= 0:
        return ""
    filled = int(round(width * n / total))
    return "#" * filled + "-" * (width - filled)


def print_summary(pours: list[dict], unique: list[dict], events: list[dict],
                  malformed: int, files: list[str]) -> None:
    tiers = Counter(r.get("tier", "?") for r in unique)
    changed = sum(1 for r in unique if r.get("raw", "") != r.get("served", ""))
    rule_ran = sum(1 for r in unique if r.get("rulePolished") is not None)
    stats = disagreement_stats(unique)
    corr = correction_stats(unique, events)

    print("=" * 60)
    print("Beers flywheel ingest")
    print("=" * 60)
    print(f"files read           : {len(files)}")
    for f in files:
        print(f"  - {f}")
    print(f"pour records (raw)   : {len(pours)}")
    print(f"pour records (dedup) : {len(unique)}")
    print(f"correction events    : {len(events)}")
    print(f"malformed lines      : {malformed}")
    print(f"pairs raw != served  : {changed}")
    print(f"rule-polisher ran    : {rule_ran}")
    print()

    print("serving tier".ljust(22) + "count   share")
    print("-" * 60)
    total = max(1, len(unique))
    for tier in (
        "parakeet-fast", "rule-polish", "bouncer-shadow-only",
        "clean-gate", "apple", "local", "rule-fallback",
    ):
        c = tiers.get(tier, 0)
        print(f"{tier.ljust(22)}{str(c).rjust(5)}   {bar(c, total)} {100*c/total:4.0f}%")
    other = sum(v for k, v in tiers.items()
                if k not in (
                    "parakeet-fast", "rule-polish", "bouncer-shadow-only",
                    "clean-gate", "apple", "local", "rule-fallback",
                ))
    if other:
        print(f"{'(other)'.ljust(22)}{str(other).rjust(5)}")
    print()

    print("Bouncer shadow vs. LLM")
    print("-" * 60)
    print(f"shadow ran on            : {stats['shadow_ran']} pours")
    print(f"shadow fired (>=1 del)   : {stats['shadow_fired']}")
    print(f"proposed deletions       : {stats['total_proposed_deletions']}")
    if stats["avg_bouncer_ms"] is not None:
        print(f"avg shadow latency       : {stats['avg_bouncer_ms']:.1f} ms")
    print()
    print("  on LLM-served pours (apple/local):")
    print(f"    both say dirty         : {stats['llm_both_dirty']}  (shadow fired, LLM changed)")
    print(f"    shadow MISS            : {stats['llm_shadow_miss']}  (LLM changed, shadow silent)")
    print(f"    shadow OVER-EAGER      : {stats['llm_shadow_eager']}  (shadow fired, LLM kept as-is)")
    print(f"    both say clean         : {stats['llm_both_clean']}")
    print()

    print("Corrections harvested (the user's own keyboard fixes)")
    print("-" * 60)
    print(f"corrections              : {corr['corrections']}")
    print(f"rejections (deleted)     : {corr['rejections']}")
    print(f"re-dictations            : {corr['redictations']}  "
          f"({corr['redictation_paired']} linked to a known pour)")
    print()
    print("  what the user was fixing:")
    print(f"    AI/rule-tier edits     : {corr['fix_ai_tier']}  (fixed a word the AI tier introduced)")
    print(f"    pure-ASR errors        : {corr['fix_pure_asr']}  (fixed a word already in the raw ASR)")
    if corr["fix_unpaired"]:
        print(f"    unpaired (no pour)     : {corr['fix_unpaired']}")
    print()
    if corr["top_pairs"]:
        print("  top corrected word pairs:")
        for (old, new), n in corr["top_pairs"]:
            print(f"    {n:>3}x  {old!r} -> {new!r}")
    else:
        print("  top corrected word pairs: (none yet)")
    print("=" * 60)


def emit_clean(unique: list[dict], dest: str) -> None:
    """Write served texts, one per line, for the clean corpus. '-' => stdout."""
    lines = []
    seen: set[str] = set()
    for r in unique:
        served = r.get("served", "").strip()
        if served and served not in seen:
            seen.add(served)
            lines.append(served)
    payload = "\n".join(lines) + ("\n" if lines else "")
    if dest == "-":
        sys.stdout.write(payload)
    else:
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(payload)
        print(f"wrote {len(lines)} clean lines -> {dest}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--path", default=DEFAULT_DIR,
                    help="flywheel*.jsonl file or a directory of them "
                         f"(default: {DEFAULT_DIR})")
    ap.add_argument("--emit-clean", metavar="OUT",
                    help="write deduped served texts one-per-line to OUT ('-' for stdout)")
    args = ap.parse_args()

    files = resolve_files(args.path)
    if not files:
        print(f"no flywheel log found at {args.path}", file=sys.stderr)
        return 1

    records, malformed = load_records(files)
    pours = [r for r in records if is_pour(r)]
    events = [r for r in records if is_event(r)]
    unique = dedupe(pours)

    print_summary(pours, unique, events, malformed, files)

    if args.emit_clean:
        emit_clean(unique, args.emit_clean)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
