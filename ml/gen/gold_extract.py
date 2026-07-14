#!/usr/bin/env python3
"""Extract real dictations from the app log for the gold eval set.

The log carries two flavours of each dictation:
  - `AppState: polished transcription='...'`      (rule-polished, fillers intact)  <- what we want
  - `AppState: AI-polished transcription='...'`   (LLM-cleaned duplicate)           <- skip

We take ONLY the rule-polished lines: they are the near-verbatim text that
`OrderKitchen.polish` receives and therefore exactly the input distribution the
Bouncer must tag. Transcripts may contain apostrophes, so we anchor on the
`polished transcription='` prefix and the trailing `'` at end of line.

Usage: python gold_extract.py [LOGFILE]  -> prints one dictation per line.
"""
import re
import sys

LOG = sys.argv[1] if len(sys.argv) > 1 else "/tmp/llatser-listen.log"
# Rule-polished only: a space before "polished" excludes "AI-polished".
PAT = re.compile(r"AppState: polished transcription='(.*)'\s*$")


def extract(path):
    seen, out = set(), []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = PAT.search(line.rstrip("\n"))
            if not m:
                continue
            text = m.group(1).strip()
            if not text or text in seen:
                continue  # dedupe exact repeats (e.g. automated test replays)
            seen.add(text)
            out.append(text)
    return out


if __name__ == "__main__":
    for t in extract(LOG):
        print(t)
