# Bouncer v3 standing retrain — unattended run instructions

You are an unattended retrain agent for the Bouncer disfluency tagger. You were
launched by the standing loop because enough REAL flywheel data has accumulated.
Work ONLY inside ~/Projects/beers/ml/ — never touch the
Swift app, never run git, never export into the app bundle, never activate
anything. Your job ends at a written report.

Read first: ml/DESIGN.md (label scheme, JSONL contract, metrics, the cardinal
rule: false DELETE is the sin; when unsure, KEEP), ml/data/gold-review.md
(labeling precedent — follow its judgment calls exactly, e.g. sentence-initial
"Okay,"/"So" are KEEP, ASR garble is KEEP, "literally" is KEEP).

Context you need: v1/v2 both failed the gold gate (P=0.29 / P=0.07 calibrated)
because synthetic data cannot teach Ben's real register and synthetic val cannot
calibrate the threshold. The fix is the real data you're about to use. History
and scorecards: ml/models/bouncer-v1*/, ml/models/bouncer-v2/eval-gold.md.

## Steps

1. **Ingest**: run `ml/gen/flywheel_ingest.py` and study the output. The
   flywheel lives at ~/Library/Application Support/Beers/flywheel.jsonl
   (+ rotations). Pour records give (raw, served) pairs; correction records are
   human-verified fixes (highest-value labels); rejections/redictations mark
   failed serves.

2. **Label real transcripts** into the DESIGN.md contract:
   - For LLM-cleaned pours (raw != served): derive word-level labels on the RAW
     text by aligning raw→served (words absent from served = DELETE candidates).
     YOU review every single alignment — the LLM sometimes rewords rather than
     deletes; if the pair isn't a clean deletion relationship (served contains
     words not in raw beyond casing/punctuation), either label only the
     unambiguous deletions or discard the pair. Follow gold-review.md precedent.
   - Corrections: where the user's fix REMOVED words we served, those are
     verified content (label KEEP in raw, and treat any word the AI deleted that
     the user re-typed as evidence the deletion was WRONG — these become KEEP).
     Where the fix was a spelling/vocab change ("plan watch"→"PlanWatch"), it's
     a KEEP either way (the Bouncer only deletes).
   - Write ml/data/real-v3.jsonl (source: "real", ids real3-XXX), full contract
     validation.

3. **Split**: shuffle real-v3 deterministically (seed 42): 60% → training slice,
   20% → real-cal.jsonl (threshold calibration), 20% → real-test.jsonl (held
   out). ml/data/gold.jsonl stays FROZEN and untouched — it is exam #1;
   real-test is exam #2. No transcript may appear in more than one split.

4. **Build v3 dataset**: extend/reuse gen/build_dataset.py to mix the existing
   synthetic sources with the real training slice, upweighting real transcripts
   ~3x (duplication is fine). Keep full contract validation. Regenerate stats.

5. **Train** per ml/train/README.md: run-name bouncer-v3-<YYYYMMDD>, same
   recipe as v2 (distilbert-base-cased, 4 epochs, weighted_ce, seed 42).

6. **Calibrate on real-cal.jsonl** (NOT synthetic val), target precision 0.98.

7. **Evaluate** on BOTH ml/data/gold.jsonl and ml/data/real-test.jsonl.
   Ship gate: DELETE precision ≥ 0.98 on BOTH, zero false-DELETEs strongly
   preferred, recall meaningfully above v2's near-abstain 0.10.

8. **Report**: write ml/standing-loop/report-<YYYYMMDD>.md — scorecard vs
   v1/v2, false-DELETE dump verbatim, data counts used, gate verdict in the
   first line (PASSED/FAILED). Append one line to the loop log
   (ml/standing-loop/loop.log) with the verdict. Then run:
   ~/Projects/claude-log/clog add "Bouncer v3 standing retrain" "<one-line verdict + key numbers>"
   Do NOT activate the model even if it passes — activation is a reviewed,
   manual step (Ben/orchestrator run the Phase-2 checklist in DESIGN.md).

Budget discipline: this is mechanical execution of a known pipeline — no
exploration, no redesign. If a step fails irrecoverably (missing files, empty
flywheel), write the report explaining what's missing and stop cleanly.
