#!/bin/zsh
# SLIDING WINDOW vs BLOCK RS, paired inside one call (task #16, goal #1).
#
# `?pcmsw=1` is SENDER-side, so one call carries both arms: side A's audio is
# window-protected and judged at B's receiver, side B's is RS and judged at A.
# Sides alternate across reps so a side asymmetry (mic fixture, page order)
# cannot masquerade as a code difference. A null run (both RS) first prices the
# design's own floor, exactly as capn.sh does.
#
# 5% iid loss both directions, no stall injection: this is the regime the
# window was built for (repair delay bounded by stride, not by group span —
# block RS left 67% of position-0 repairs late at K=10). Both arms run their
# SHIPPED adaptive ladders (fecN for RS, stride for the window) — the fair
# comparison is code vs code as each would actually ship, not pinned rungs.
# Overhead at the 5%-loss rung: RS n=3 = 30%, window stride 3 = 33% — the
# window pays ~3pp more; it must win THROUGH that handicap, not net of it.
#
# DO NOT ship on a win here without reading MEASURED.md's redundancy-is-
# congestion entry: a lateness-driven ladder also looked obviously right and
# lost on three metrics. The gate for shipping is this A/B plus a --bw=0.8
# scarcity run (parity feeds the queue that causes lateness there).
set -e
S=/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad
cd "/Users/earningsgpt/video calling"
mkdir -p $S/swab

have() { node -e 'try{process.exit(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).result?0:1)}catch{process.exit(1)}' "$1"; }

run() { # run <json> <swA> <swB> <label>
  if have "$1"; then echo "  SKIP $4"; return; fi
  echo "=== $4   $(date +%H:%M:%S)"
  node testbed/relpair.mjs --swA=$2 --swB=$3 --relA=2 --relB=2 \
    --loss=5 --hole=0 --settle=15 --recover=60 \
    --json="$1" > "${1%.json}.log" 2>&1 || echo "  $4 FAILED (see log)"
  sleep 20
}

REPS=${1:-4}
run $S/swab/null.json 0 0 "null (both RS)"
i=1
while [ $i -le $REPS ]; do
  run $S/swab/r${i}a.json 1 0 "rep $i: window on A"
  run $S/swab/r${i}b.json 0 1 "rep $i: window on B"
  i=$((i+1))
done

echo "== SUMMARY: window arm vs RS arm, per paired call =="
node -e '
const fs=require("fs");const D=process.argv[1]+"/swab";
const rows=[];
for (const f of fs.readdirSync(D).filter(x=>x.endsWith(".json")).sort()) {
  let j; try{ j=JSON.parse(fs.readFileSync(`${D}/${f}`,"utf8")); }catch{ continue; }
  if (!j.result) { console.log(`${f}: no result`); continue; }
  const m=j.meta, o=j.result, auth=o.authority??"?";
  if (m.swA===m.swB) { // null
    console.log(`${f.padEnd(10)} NULL  A conceal ${o.A.steadyLost}f e2e ${o.A.steadyLastThirdE2E?.toFixed(1)}  B ${o.B.steadyLost}f ${o.B.steadyLastThirdE2E?.toFixed(1)}  auth ${auth}`);
    continue;
  }
  const win=m.swA?"B":"A", rs=m.swA?"A":"B"; // judged at the RECEIVER
  const r={f, auth, winC:o[win].steadyLost, rsC:o[rs].steadyLost,
           winE:o[win].steadyLastThirdE2E, rsE:o[rs].steadyLastThirdE2E};
  rows.push(r);
  console.log(`${f.padEnd(10)} WINDOW conceal ${r.winC}f e2e ${r.winE?.toFixed(1)}ms   RS conceal ${r.rsC}f e2e ${r.rsE?.toFixed(1)}ms   auth ${auth}`);
}
const ok=rows.filter(r=>r.auth==="full");
if (ok.length) {
  const wins=ok.filter(r=>r.winC<r.rsC).length, ties=ok.filter(r=>r.winC===r.rsC).length;
  const dC=ok.map(r=>r.winC-r.rsC), dE=ok.map(r=>r.winE-r.rsE);
  const mean=a=>a.reduce((x,y)=>x+y,0)/a.length;
  console.log(`\npaired (auth=full n=${ok.length}): window better on conceal ${wins}/${ok.length-ties} (ties ${ties})`);
  console.log(`mean delta conceal ${mean(dC).toFixed(1)}f  mean delta e2e ${mean(dE).toFixed(1)}ms  (negative = window better)`);
} else console.log("\nno full-authority paired runs — nothing to claim");
' $S
echo SWAB-DONE
