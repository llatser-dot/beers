# Bouncer training-data pipeline (`ml/gen/`)

Builds the clean corpus, corrupts it into labelled disfluency-tagged
transcripts, and assembles `ml/data/{train,val}.jsonl`. See `../DESIGN.md`
for the label scheme and JSONL contract. Everything uses the shared venv at
`ml/.venv` (Python 3.12) and the local Ollama model `gemma4:latest` at
`http://127.0.0.1:11434`.

## Files
| file | what it does |
|------|--------------|
| `common.py` | shared: labels, validation, Ollama client, JSONL checkpoint, real-material loaders |
| `build_corpus.py` | clean corpus → `data/clean/*.txt` (seeds + templates + Ollama) |
| `corrupt_rules.py` | rule-based corruptor (fillers/repeats/restarts/hesitations), calibrated |
| `corrupt_llm.py` | gemma4 self-correction generator; **assembles labels in Python** |
| `corrupt_traps.py` | hard negatives: KEEP-labeled deletion lookalikes (legit repeats, kept connective openers, content-sense filler words, garbled-ASR noise, truncated restarts whose repair shares words) — added after v1's gold DELETE-precision collapse; calibrated to `data/gold-review.md` |
| `build_dataset.py` | merge (rule 45 / trap 30 / llm 20 / real 5) + 95/5 split by clean-source seed + validate + `data/stats.md` |

## Full rebuild from scratch
```bash
cd ml
.venv/bin/python gen/build_corpus.py templates          # 16k templates + seeds (fast)
nohup .venv/bin/python gen/build_corpus.py ollama 5000 > gen/logs/corpus_ollama.log 2>&1 &
nohup .venv/bin/python gen/corrupt_llm.py full 5000     > gen/logs/llm_full.log     2>&1 &
.venv/bin/python gen/corrupt_traps.py rules             # ~4.3k rule-based traps (fast)
nohup .venv/bin/python -u gen/corrupt_traps.py gemma 500 > gen/logs/traps_gemma.log 2>&1 &
# ...wait for the background jobs (see monitoring)...
.venv/bin/python gen/build_dataset.py                   # writes train/val/stats
```

## Monitoring the background runs
```bash
cd ml
# clean-corpus Ollama generation
wc -l data/clean/ollama.txt          # grows toward the target
# LLM self-correction generation
wc -l data/llm.jsonl                 # grows toward the target (5000)
tail -f gen/logs/llm_full.log        # note: stdout is block-buffered; the
                                     # .jsonl line-count is the live signal
pgrep -fl 'gen/.*\.py'               # are the jobs still alive?
```
Both writers are **checkpoint/resume**: they read existing output (Ollama
corpus dedupes on text; LLM dedupes on a content hash `seen-ids`) and only
append. If a run dies, just re-launch the exact same command — it continues.

## Resuming / topping up
```bash
# add more clean Ollama sentences (raise the target):
nohup .venv/bin/python gen/build_corpus.py ollama 8000 > gen/logs/corpus_ollama.log 2>&1 &
# add more LLM corrections:
nohup .venv/bin/python gen/corrupt_llm.py full 8000    > gen/logs/llm_full.log 2>&1 &
# then rebuild the dataset (cheap, deterministic):
.venv/bin/python gen/build_dataset.py
```

## Invariants enforced on every example
- `len(words) == len(labels)`
- labels ∈ {KEEP, DEL_FILLER, DEL_REPEAT, DEL_REPARANDUM, DEL_INTERREGNUM}
- concatenating the KEEP words reconstructs the clean text (case/punct-insensitive)

The LLM generator only ever *inserts* deletable tokens around untouched clean
words, so the reconstruction invariant holds by construction; malformed
generations are rejected (expect a meaningful reject rate from an 8B model —
that is fine, it is free).

## Do NOT touch
`ml/train/` (training harness, another agent) and `ml/data/gold*` (gold set,
another agent). The gold set is the only eval that counts.
```
