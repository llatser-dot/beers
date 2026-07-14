# Bouncer — on-device disfluency tagger for Beers

The Bouncer stands at the door of every pour and removes words that don't
belong: fillers, stutters, false starts, and self-corrected text. It is a
token-classification model (BERT-class encoder, token labels), NOT a
generative model — it can only delete, never write, so it cannot
hallucinate, answer the dictation, or summarise. It becomes tier 0 in
`OrderKitchen` (instant, always-on); the Apple/Ollama LLM race stays as the
fallback for pours needing semantic rewording.

## Why this exists (context for agents)
gemma4:8b is the smallest local LLM that reliably edits-not-answers
dictation (benched 2026-07-14: 1-4B models refuse/answer/hallucinate/leak
CoT). Google ships a 3.1M-param token-tagger for exactly this task in
Android Live Captions but never released it. We're building our own.
Reference: arXiv 2104.10769 (small-BERT disfluency), arXiv 2403.08229
(LLM as disfluency generator for training data).

## Task definition
- Input: one dictated transcript (as produced by Parakeet v3 ASR + the
  app's rule polisher — i.e. the text `OrderKitchen.polish` receives).
  Whitespace-split into words. Words keep their punctuation attached.
- Output: one label per word:
  - `KEEP`
  - `DEL_FILLER`      — um, uh, erm, like, you know, basically, sort of…
  - `DEL_REPEAT`      — immediate word/phrase repeats ("the the", "tell her tell her")
  - `DEL_REPARANDUM`  — abandoned/corrected content ("send it to Dave" before "no wait")
  - `DEL_INTERREGNUM` — the correction marker itself ("no wait", "actually", "scratch that", "I mean")
- At inference all DEL_* collapse to DELETE. Subtypes exist only to help
  training and error analysis.
- INVARIANT: concatenating the KEEP words must yield the intended clean
  text, modulo punctuation/casing seams (a downstream regex pass in the
  app fixes orphaned commas and sentence-initial casing — not this model's
  job).
- Cardinal rule, in data and in threshold calibration: **a false DELETE is
  far worse than a false KEEP.** The whole reason this project exists is
  that models were cutting real content. When unsure, KEEP.

## Data format (single contract for every stage)
JSONL, one object per transcript:
```json
{"id": "rule-000123", "source": "rule|llm|real",
 "words": ["Send", "the", "report", "to", "um,", "Dave", "no", "wait", "send", "it", "to", "Sarah."],
 "labels": ["KEEP", "KEEP", "KEEP", "KEEP", "DEL_FILLER", "DEL_REPARANDUM", "DEL_INTERREGNUM", "DEL_INTERREGNUM", "KEEP", "KEEP", "KEEP", "KEEP"]}
```
- `len(words) == len(labels)` always. Validate on write AND on read.
- `words` are `text.split()` tokens of the corrupted/verbatim text.

## Directory layout (all under ml/)
```
DESIGN.md            this file
data/clean/          clean source sentences (one .txt per corpus, one sentence/line)
data/train.jsonl     training set
data/val.jsonl       validation set (held-out corruption seeds, no overlap)
data/gold.jsonl      REAL transcripts, labeled — the only eval that counts
data/gold-review.md  human-readable gold set for Ben/lead to eyeball
gen/                 corpus assembly + corruption pipeline scripts
train/               training + eval + calibration harness
models/              checkpoints and exported artifacts (gitignored)
.venv/               uv venv — Python 3.12 (torch wheels), NOT 3.14
```

## Base model + constraints
- Primary: `distilbert-base-cased` (66M). Cased matters: transcripts carry
  casing signal and names.
- Tokenizer MUST be WordPiece (Core ML + Swift port later; SentencePiece
  models like DeBERTa are disqualified regardless of benchmark scores).
- Word-level labels → label the first subtoken of each word, `-100` on
  continuation subtokens (standard HF token-classification alignment).
- Training on Apple Silicon MPS. Keep runs under ~2h.

## Real material available
- `/tmp/llatser-listen.log` — 69 `polished transcription='...'` lines =
  near-verbatim real dictations (rule-polished, fillers largely intact).
  Ben's actual voice: UK English, SEO/planning/dev vocabulary, informal.
- `~/Library/Application Support/Beers/pours.json` — 226 final (cleaned)
  pours: use as clean-source seeds for corruption and style calibration,
  NOT as verbatim gold.
- Calibrate corruption rates against the real log lines, not intuition.

## Metrics + acceptance
- Report: per-class P/R/F1, overall DELETE precision/recall at the chosen
  threshold, transcript-level exact-match, all on gold.jsonl.
- Acceptance for shipping tier 0: DELETE precision ≥ 0.98 on gold at
  whatever recall that costs. Recall is nice; precision is sacred.
- Calibration: sweep the DELETE probability threshold on val, verify on
  gold. Model may abstain (all-KEEP) — that's a safe no-op pour.

## Phases
1. (this build) data pipeline + gold set + training harness → trained
   checkpoint + gold-set report
2. Core ML export + Swift WordPiece tokenizer + OrderKitchen tier 0
3. Flywheel: app logs (verbatim, LLM-cleaned) pairs locally for future
   retraining on Ben's own speech
