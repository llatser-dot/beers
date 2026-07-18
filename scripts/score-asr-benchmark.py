#!/usr/bin/env python3
"""Score same-audio Beers ASR outputs after gold transcripts are filled in."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


SYSTEMS = ("productionTranscript", "v3Auto", "v3English", "v2English")


def words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def edit_distance(left: list[str], right: list[str]) -> int:
    previous = list(range(len(right) + 1))
    for row, source in enumerate(left, 1):
        current = [row]
        for column, target in enumerate(right, 1):
            current.append(min(
                previous[column] + 1,
                current[column - 1] + 1,
                previous[column - 1] + (source != target),
            ))
        previous = current
    return previous[-1]


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        assert words("Pints, don't change.") == ["pints", "don't", "change"]
        assert edit_distance(words("the pints metric"), words("the points metric")) == 1
        assert edit_distance(words("one two"), words("one two three")) == 1
        print("ASR benchmark scorer smoke passed.")
        return 0
    if len(sys.argv) != 2:
        raise SystemExit("usage: score-asr-benchmark.py RESULTS.jsonl")
    path = Path(sys.argv[1]).expanduser()
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    scored = [row for row in rows if row.get("gold", "").strip()]
    if not scored:
        print(f"Benchmark ran for {len(rows)} samples, but none has a gold transcript yet.")
        print("Fill the 'gold' field in manifest.jsonl, then rerun the benchmark.")
        return 2

    print(f"ASR benchmark: {len(scored)} gold samples ({len(rows)} captured)")
    print("system                 WER     faulty sentences    median latency")
    print("----------------------------------------------------------------")
    for system in SYSTEMS:
        errors = reference_words = faulty = 0
        for row in scored:
            gold = words(row["gold"])
            candidate = words(row.get(system, ""))
            errors += edit_distance(gold, candidate)
            reference_words += len(gold)
            faulty += candidate != gold
        wer = errors / max(1, reference_words)
        latency_key = f"{system}Ms"
        latencies = sorted(float(row[latency_key]) for row in scored if latency_key in row)
        median = latencies[len(latencies) // 2] if latencies else 0
        latency = f"{median:.0f} ms" if latencies else "captured live"
        print(
            f"{system:<22} {wer:>6.1%}   "
            f"{faulty:>4}/{len(scored)} ({faulty/len(scored):.1%})   {latency:>13}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
