# Beers — project map (canonical)

**This is the one standing reference for this project. Agents: read this first.**
Behavioral rules live in AGENTS.md; this file is the map of what exists, where,
and what the current state is. Keep it updated when the state changes.

Beers is an open-source push-to-talk dictation app for macOS
(`/Applications/Beers.app`, bundle `com.llatser.listen`, log
`/tmp/beers.log`). Hold the hotkey, speak, release — text pastes at
the cursor. **Terminology: a "pour" = one dictation. Pints are *pulled*
(1,000 words = 1 pint), never "poured".** Repo: github.com/llatser-dot/beers
Local checkout: `~/Projects/beers`.

> The bundle identifier is `com.llatser.listen` and is deliberately frozen.
> It predates the Beers name and is load-bearing for TCC: macOS keys every
> Microphone / Input Monitoring / Accessibility grant to it, so changing it
> would silently revoke permissions and reset saved settings for every
> existing user. It is never shown in the UI — macOS displays "Beers".

## Repo layout

```
Beers/            Swift app source (xcodegen; project.yml is truth, .xcodeproj generated)
  AppState.swift          Central state; pour lifecycle lives in stopRecordingAndTranscribe
  BeersSnapshot.swift     Deterministic off-screen UI capture; synthetic state only, never reads personal pours/dictionary/Pub Wall credentials
  ASRBenchmark.swift      Opt-in local WAV capture + same-audio v3/v2 benchmark runner
  OrderKitchen.swift      Apple-on-device Command Mode + legacy diagnostic tiers
  AITranscriptRewriter.swift  Retired endpoint client; excluded from the app target
  AIEndpointTrust.swift   Retired endpoint classifier; excluded from the app target
  Bouncer.swift           On-device disfluency tagger: Swift WordPiece tokenizer + Core ML inference
  CorrectionWatcher.swift Post-paste AX watcher harvesting the user's keyboard fixes
  FlywheelLog.swift       Local-only training-data log (pours + corrections)
  PubWallController.swift Opt-in leaderboard identity, Keychain-backed sync queue, live totals
  Resources/Bouncer/      Model bundle: Bouncer.mlpackage (Git LFS) + vocab/threshold/labels
ml/                       Everything machine-learning (Python; ml/.venv and ALL of ml/data/ are local-only, gitignored — real speech never ships)
  DESIGN.md               The ML contract: label scheme, JSONL format, metrics, ship gate
  data/gold.jsonl         FROZEN exam: 38 real labeled dictations. NEVER train on it, never edit
  data/gold-review.md     Labeling precedent — follow its judgment calls for any new labeling
  data/{train,val,llm,traps}.jsonl  Synthetic v2 dataset (local-only with all ml/data; regenerable via gen/)
  gen/                    Data pipeline: rule corruptor, gemma4 correction generator, traps, flywheel ingest
  train/                  Training/eval/calibration harness (MPS) — see train/README.md for commands
  export/                 HF checkpoint → Core ML export + parity verification
  models/                 Checkpoints + baselines (NOT committed — regenerable, see reports inside)
  standing-loop/          Weekly launchd retrain loop: check-and-train.sh + RETRAIN-PROMPT.md + reports
scripts/agent-install.sh  THE build+install command (stable signing, TCC preserved)
scripts/export-brand-assets.py  Rebuild the true-SVG + longest-edge 4096px logo pack
index.html                Public website, served at the repo root by GitHub Pages
web/                      Website assets (brand marks, screenshots) for index.html
brand/source-raster-v2/   Approved clean Imagen badge + square application-icon masters
brand/exports-v1/         Current clean v2 SVG/4K PNG logo pack + compatibility mark
```

## The production dictation pipeline

Every ordinary pour now flows: audio → ASR (Parakeet v3, multilingual auto) →
minimal transcript sanitation → explicit vocabulary corrections → paste. This
`parakeet-fast` path is the default for new and migrated installs. Sanitation
collapses whitespace and removes isolated one-letter consonant artefacts while
preserving `a` and `I`; it has no Bouncer pass, ramble gate or generative rewrite.

The old deterministic normaliser/rule polisher remains as an explicit **Legacy
rule polish** comparison switch; it is on in the standard new-install profile,
matching the maintainer's proven daily configuration, and remains user-controlled.
Command Mode can use only
Apple's system-managed on-device Foundation model when the Mac supports it.
The retired endpoint client is excluded from the application target: production
Beers cannot launch, prewarm or call Ollama, and has no remote rewrite path.

Reactivation now requires two reviewed gates: a bundle whose `threshold.json`
has `"target_met": true`, and an explicit code change restoring Bouncer to the
production path. A file swap alone cannot affect text. Currently v1/v2/v3 all
failed and the research is parked.

## Bouncer status (2026-07-18)

| Version | Gold DELETE precision | Verdict |
|---|---|---|
| v1 (synthetic) | 0.29 | failed — lookalike blindness |
| v2 (synthetic + traps) | 0.07 calibrated / 1.0 only near-abstain | failed — solved the generator, not real speech |
| v3 (2026-07-15) | 0.222 calibrated / 0.333 ceiling at useful recall | failed — real data too thin; parked |

Key lesson (proven, don't re-litigate): synthetic data cannot teach the user's
register, and synthetic validation cannot calibrate the threshold. Sub-8B LLMs
cannot do this task via prompting either (benched: they answer/refuse the text).
The lever is real user data. Ship gate: DELETE precision ≥ 0.98 on gold AND on
held-out real data. False deletions are the cardinal sin; when unsure, KEEP.

## The flywheel (app-local; Beers has no upload path)

- Every pour → `~/Library/Application Support/Beers/flywheel.jsonl`:
  {ts, raw, rulePolished, served, tier, bouncerWouldDelete, bouncerMs}
- Keyboard fixes within ~2min of a paste → correction/rejection records
  (CorrectionWatcher; terminals skipped in v1, secure fields always).
- Immediate re-dictation → failure flag on the prior pour.
- Reader: `ml/gen/flywheel_ingest.py` (counts, correction stats, clean-corpus export).
- Toggles: UserDefaults `flywheelLoggingEnabled` and `correctionWatcherEnabled`
  default on. `bouncerShadowEnabled` is migrated off and Bouncer is not invoked
  by the production path while the research is parked.

## ASR benchmark capture (explicit opt-in; local only)

- Brew Settings → **Capture ASR benchmark audio** is off by default.
- When enabled, each pour adds a 16 kHz mono WAV plus its raw production
  transcript under `~/Library/Application Support/Beers/ASR Benchmarks/`.
- Fill the `gold` fields in `manifest.jsonl`, then run
  `scripts/run-asr-benchmark.sh`. One model-loading run compares v3 auto, v3
  English-hinted and v2 English on exactly the same audio, writing WER, faulty
  sentence rate and median latency.
- The app has no upload path for these files. The confirmed **Pour it away**
  action deletes the benchmark directory as well as flywheel records.

## Standing loop

launchd `com.beers.bouncer-loop` (Mon 06:57) runs
`ml/standing-loop/check-and-train.sh`: local count; when
dirty-pairs + 2×corrections ≥ 300 and ≥10 days since last run, launches a
headless `claude -p --model opus` executing `ml/standing-loop/RETRAIN-PROMPT.md`
(label real data → train v3 → dual exam → report). **It never activates the
model and never commits** — activation is a reviewed manual step (checklist in
the Phase-2 report; export → parity → copy bundle → agent-install). This is a
separate reference automation, not installed or run by the app; it sends selected
flywheel text to Anthropic and requires the operator's own Claude access.

## Key commands

```
bash scripts/agent-install.sh                                  # build + install (signing/TCC safe)
/Applications/Beers.app/Contents/MacOS/Beers --beers-polish-test "text"     # legacy/model diagnostic only
/Applications/Beers.app/Contents/MacOS/Beers --beers-bouncer-test "text"    # Bouncer word:prob dump
/Applications/Beers.app/Contents/MacOS/Beers --beers-snapshot               # UI PNGs to /tmp/beers-snapshots
ml/.venv/bin/python ml/gen/flywheel_ingest.py                  # flywheel counts + correction stats
scripts/run-asr-benchmark.sh                                   # same-audio Parakeet comparison
tail -f /tmp/beers.log                                # live app log
```

## Hard rules

- ☠️ NEVER run a MANUAL `tccutil reset` on `com.llatser.listen` — it kills the
  app's permission grants. The one supported reset is `install.sh`'s own scoped,
  automatic one (service-scoped: ListenEvent/Accessibility/Microphone on the
  bundle id), fired only when the signing identity actually changed so a single
  clean re-grant works. Let the installer handle it; never do it by hand.
- NEVER edit `ml/data/gold.jsonl` or train on it; extend evals via new real-test files.
- The Bouncer only deletes — any feature that makes it write text is out of scope.
- Flywheel data is private: no upload path or telemetry in the app. Keep external
  tooling separate and make any cloud boundary explicit before an operator runs it.
- Benchmark audio is more sensitive than text and must remain explicit opt-in,
  local-only, disabled by default, and covered by the confirmed wipe action.
- Pub Wall is explicit opt-in only. It may send a verified private email, public
  handle and aggregate word/pour counts; it must never send transcripts or audio.
- Build via `scripts/agent-install.sh` only (ad-hoc signing breaks TCC).
- Site/brand: one logo (the transparent scalloped badge replacing the B)
  throughout the app and site. The orange square is reserved for OS-level app
  icons such as the macOS Dock/Finder icon. No beer-strip hero dividers; pour =
  dictation everywhere.

## Related (outside this repo)

- Public site: `index.html` at the repo root, assets in `web/`, live via GitHub Pages at https://llatser-dot.github.io/beers/
- Earlier loose site draft: `~/Projects/beers-wireframes/site.html` (reference only).
- Brand assets: `brand/` here (concept boards in `brand/concept/`).
- Current raster masters: `brand/source-raster-v2/` (clean
  transparent menu badge and opaque square application icon).
- Current logo exports: `brand/exports-v1/` (clean v2 SVG masters,
  4K PNG pairs, preview, usage guide; rebuild with
  `python3 scripts/export-brand-assets.py`).
