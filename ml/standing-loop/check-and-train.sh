#!/bin/bash
# Bouncer standing loop — weekly threshold check, fortnightly-effective retrain.
# Cheap when below threshold (pure local counting, no tokens). Only launches the
# retrain agent when enough REAL flywheel data exists AND >=10 days since last run.
set -uo pipefail
ML="$HOME/Projects/beers/ml"
LOOP="$ML/standing-loop"
LOG="$LOOP/loop.log"
STATE="$LOOP/state.json"
FLY="$HOME/Library/Application Support/Beers/flywheel.jsonl"
THRESHOLD=300
MIN_DAYS=10
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if pmset -g batt | head -1 | grep -q "Battery Power"; then log "on battery — skipping"; exit 0; fi

COUNTS=$(python3 - "$FLY" <<'EOF'
import json, sys, glob, os
p = sys.argv[1]
files = [p] + glob.glob(os.path.join(os.path.dirname(p), 'flywheel-*.jsonl'))
dirty = corr = 0
for f in files:
    try:
        for line in open(f):
            try: d = json.loads(line)
            except Exception: continue
            t = d.get('type')
            if t in ('correction', 'rejection'): corr += 1
            elif 'raw' in d:
                # dirty = words were actually REMOVED (deletion-teachable pair),
                # not just punctuation/casing touched by the rule polisher
                rw = len(d.get('raw','').split()); sw = len(d.get('served','').split())
                if rw - sw >= 1: dirty += 1
    except FileNotFoundError: pass
print(dirty, corr)
EOF
)
DIRTY=$(echo "$COUNTS" | awk '{print $1}'); CORR=$(echo "$COUNTS" | awk '{print $2}')
SCORE=$((DIRTY + 2*CORR))

LAST=$(python3 -c "import json;print(json.load(open('$STATE')).get('last_train','never'))" 2>/dev/null || echo never)
TOO_SOON=0
if [ "$LAST" != "never" ]; then
  D=$(python3 -c "from datetime import datetime as dt;print((dt.now()-dt.fromisoformat('$LAST')).days)" 2>/dev/null || echo 99)
  [ "$D" -lt "$MIN_DAYS" ] && TOO_SOON=1
fi

log "dirty=$DIRTY corrections=$CORR score=$SCORE/$THRESHOLD last_train=$LAST"
if [ "$SCORE" -lt "$THRESHOLD" ]; then log "below threshold — nothing to do"; exit 0; fi
if [ "$TOO_SOON" = "1" ]; then log "trained <${MIN_DAYS}d ago — waiting"; exit 0; fi

log "THRESHOLD MET — launching v3 retrain (opus, unattended)"
python3 -c "import json,datetime;json.dump({'last_train':datetime.datetime.now().isoformat()},open('$STATE','w'))"
cd "$HOME/Projects/beers"
"$(command -v claude || echo "$HOME/.local/bin/claude")" -p \
  "Read ~/Projects/beers/ml/standing-loop/RETRAIN-PROMPT.md and execute it fully and exactly." \
  --model opus --dangerously-skip-permissions >> "$LOOP/retrain-$(date +%Y%m%d).log" 2>&1
log "retrain agent finished (exit $?) — see retrain-$(date +%Y%m%d).log and report in $LOOP"
