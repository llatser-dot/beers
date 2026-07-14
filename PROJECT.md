# Beers — project map (canonical)

**This is the one standing reference for this project. Agents: read this first.**
Behavioral rules live in AGENTS.md; this file is the map of what exists, where,
and what the current state is. Keep it updated when the state changes.

Beers is a free, open-source push-to-talk dictation app for macOS
(`/Applications/Beers.app`, bundle `com.llatser.listen`, log
`/tmp/llatser-listen.log`). Hold the hotkey, speak, release — text pastes at
the cursor. **Terminology: a "pour" = one dictation. Pints are *pulled*
(1,000 words = 1 pint), never "poured".** Repo: github.com/llatser-dot/beers
(renamed from llatser-listen 2026-07-14; old URL redirects). Local checkout: `~/Projects/beers`.

## Repo layout

```
LlatserListen/            Swift app source (xcodegen; project.yml is truth, .xcodeproj generated)
  AppState.swift          Central state; pour lifecycle lives in stopRecordingAndTranscribe
  OrderKitchen.swift      The cleanup tier system (see pipeline below) + PolishResult
  AITranscriptRewriter.swift  Local-LLM client (native Ollama /api/chat, think:false, OpenAI-compat fallback)
  Bouncer.swift           On-device disfluency tagger: Swift WordPiece tokenizer + Core ML inference
  CorrectionWatcher.swift Post-paste AX watcher harvesting the user's keyboard fixes
  FlywheelLog.swift       Local-only training-data log (pours + corrections)
  Resources/Bouncer/      Model bundle: Bouncer.mlpackage (Git LFS) + vocab/threshold/labels
ml/                       Everything machine-learning (Python; venv at ml/.venv, NOT committed)
  DESIGN.md               The ML contract: label scheme, JSONL format, metrics, ship gate
  data/gold.jsonl         FROZEN exam: 38 real labeled dictations. NEVER train on it, never edit
  data/gold-review.md     Labeling precedent — follow its judgment calls for any new labeling
  data/{train,val,llm,traps}.jsonl  Synthetic v2 dataset (committed; regenerable via gen/)
  gen/                    Data pipeline: rule corruptor, gemma4 correction generator, traps, flywheel ingest
  train/                  Training/eval/calibration harness (MPS) — see train/README.md for commands
  export/                 HF checkpoint → Core ML export + parity verification
  models/                 Checkpoints + baselines (NOT committed — regenerable, see reports inside)
  standing-loop/          Weekly launchd retrain loop: check-and-train.sh + RETRAIN-PROMPT.md + reports
scripts/agent-install.sh  THE build+install command (stable signing, TCC preserved)
```

## The cleanup pipeline (OrderKitchen.polish)

Every pour flows: ASR (Parakeet v3) → rule polisher → **tier 0 Bouncer**
(shadow mode: predicts deletions in ~10ms, logs, does NOT touch text) → ramble
gate (clean pours serve instantly) → LLM race (Apple on-device model vs local
Ollama `gemma4:latest`, one shared 4s deadline, first acceptable answer wins;
keep-ratio guard rejects over-trimmed rewrites) → vocabulary corrections → paste.

**Bouncer activation is a file swap, not a code change**: when the bundle's
`threshold.json` has `"target_met": true` (the export tool stamps it from the
gold-set gate), tier 0 serves its cleaned text. Currently false — v1/v2 failed.

## Bouncer status (2026-07-14)

| Version | Gold DELETE precision | Verdict |
|---|---|---|
| v1 (synthetic) | 0.29 | failed — lookalike blindness |
| v2 (synthetic + traps) | 0.07 calibrated / 1.0 only near-abstain | failed — solved the generator, not real speech |
| v3 | pending | trains automatically on REAL flywheel data via the standing loop |

Key lesson (proven, don't re-litigate): synthetic data cannot teach the user's
register, and synthetic validation cannot calibrate the threshold. Sub-8B LLMs
cannot do this task via prompting either (benched: they answer/refuse the text).
The lever is real user data. Ship gate: DELETE precision ≥ 0.98 on gold AND on
held-out real data. False deletions are the cardinal sin; when unsure, KEEP.

## The flywheel (all local, never leaves the Mac)

- Every pour → `~/Library/Application Support/Beers/flywheel.jsonl`:
  {ts, raw, rulePolished, served, tier, bouncerWouldDelete, bouncerMs}
- Keyboard fixes within ~2min of a paste → correction/rejection records
  (CorrectionWatcher; terminals skipped in v1, secure fields always).
- Immediate re-dictation → failure flag on the prior pour.
- Reader: `ml/gen/flywheel_ingest.py` (counts, correction stats, clean-corpus export).
- Toggles: UserDefaults `flywheelLoggingEnabled`, `correctionWatcherEnabled`,
  `bouncerShadowEnabled` (all default on).

## Standing loop

launchd `com.beers.bouncer-loop` (Mon 06:57) runs
`ml/standing-loop/check-and-train.sh`: free local count; when
dirty-pairs + 2×corrections ≥ 300 and ≥10 days since last run, launches a
headless `claude -p --model opus` executing `ml/standing-loop/RETRAIN-PROMPT.md`
(label real data → train v3 → dual exam → report). **It never activates the
model and never commits** — activation is a reviewed manual step (checklist in
the Phase-2 report; export → parity → copy bundle → agent-install).

## Key commands

```
bash scripts/agent-install.sh                                  # build + install (signing/TCC safe)
/Applications/Beers.app/Contents/MacOS/Beers --beers-polish-test "text"     # end-to-end polish test
/Applications/Beers.app/Contents/MacOS/Beers --beers-bouncer-test "text"    # Bouncer word:prob dump
/Applications/Beers.app/Contents/MacOS/Beers --beers-snapshot               # UI PNGs to /tmp/beers-snapshots
ml/.venv/bin/python ml/gen/flywheel_ingest.py                  # flywheel counts + correction stats
tail -f /tmp/llatser-listen.log                                # live app log
```

## Hard rules

- ☠️ NEVER `tccutil reset` on `com.llatser.listen` — kills the app's permission grants.
- NEVER edit `ml/data/gold.jsonl` or train on it; extend evals via new real-test files.
- The Bouncer only deletes — any feature that makes it write text is out of scope.
- Flywheel data is private: no upload paths, no telemetry, ever.
- Build via `scripts/agent-install.sh` only (ad-hoc signing breaks TCC).
- Site/brand: one logo (the scalloped badge replacing the B), no beer-strip
  hero dividers, pour = dictation everywhere.

## Related (outside this repo)

- Public site draft: `~/Projects/beers-wireframes/site.html` (NOT deployed).
- Brand assets: `~/Projects/beers-wireframes/brand/`, `Beers-Brand-Assets/` here.
