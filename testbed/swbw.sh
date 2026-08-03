#!/bin/zsh
# SLIDING WINDOW vs BLOCK RS under SCARCITY (the second shipping gate).
#
# swn8.sh judges the codes where loss is INJECTED and independent of what we
# send. This run judges them where loss is SELF-INFLICTED: at --bw=0.8 the
# queue is the enemy and parity feeds it — redundancy-is-congestion killed a
# plausible FEC change exactly here, and scarcity-hurts-without-loss measured
# ~90% of that regime's concealment as lateness no parity can repair. The
# window's extra 3pp overhead (33% vs 30% at the top rung) could plausibly
# LOSE this regime while winning iid loss; both gates must pass before the
# default moves. Same pairing/alternation/null design as swn8.sh.
set -e
S=/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad
cd "/Users/earningsgpt/video calling"
mkdir -p $S/swbw

have() { node -e 'try{process.exit(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).result?0:1)}catch{process.exit(1)}' "$1"; }

run() { # run <json> <swA> <swB> <label>
  if have "$1"; then echo "  SKIP $4"; return; fi
  echo "=== $4   $(date +%H:%M:%S)"
  node testbed/relpair.mjs --swA=$2 --swB=$3 --relA=2 --relB=2 \
    --bw=0.8 --loss=0 --hole=0 --settle=15 --recover=60 \
    --json="$1" > "${1%.json}.log" 2>&1 || echo "  $4 FAILED (see log)"
  sleep 20
}

REPS=${1:-3}
run $S/swbw/null.json 0 0 "null (both RS, bw 0.8)"
i=1
while [ $i -le $REPS ]; do
  run $S/swbw/r${i}a.json 1 0 "rep $i: window on A"
  run $S/swbw/r${i}b.json 0 1 "rep $i: window on B"
  i=$((i+1))
done

echo "== SUMMARY: window arm vs RS arm under scarcity =="
node -e '
const fs=require("fs");const D=process.argv[1]+"/swbw";
const rows=[];
for (const f of fs.readdirSync(D).filter(x=>x.endsWith(".json")).sort()) {
  let j; try{ j=JSON.parse(fs.readFileSync(`${D}/${f}`,"utf8")); }catch{ continue; }
  if (!j.result) { console.log(`${f}: no result`); continue; }
  const m=j.meta, o=j.result, auth=o.authority??"?";
  if (m.swA===m.swB) {
    console.log(`${f.padEnd(10)} NULL  A conceal ${o.A.steadyLost}f e2e ${o.A.steadyLastThirdE2E?.toFixed(1)}  B ${o.B.steadyLost}f ${o.B.steadyLastThirdE2E?.toFixed(1)}  auth ${auth}`);
    continue;
  }
  const win=m.swA?"B":"A", rs=m.swA?"A":"B";
  const r={f, auth, winC:o[win].steadyLost, rsC:o[rs].steadyLost,
           winE:o[win].steadyLastThirdE2E, rsE:o[rs].steadyLastThirdE2E};
  rows.push(r);
  console.log(`${f.padEnd(10)} WINDOW conceal ${r.winC}f e2e ${r.winE?.toFixed(1)}ms   RS conceal ${r.rsC}f e2e ${r.rsE?.toFixed(1)}ms   auth ${auth}`);
}
const ok=rows.filter(r=>r.auth==="full");
if (ok.length) {
  const wins=ok.filter(r=>r.winC<r.rsC).length, ties=ok.filter(r=>r.winC===r.rsC).length;
  const mean=a=>a.reduce((x,y)=>x+y,0)/a.length;
  console.log(`\npaired (auth=full n=${ok.length}): window better on conceal ${wins}/${ok.length-ties} (ties ${ties})`);
  console.log(`mean delta conceal ${mean(ok.map(r=>r.winC-r.rsC)).toFixed(1)}f  mean delta e2e ${mean(ok.map(r=>r.winE-r.rsE)).toFixed(1)}ms  (negative = window better)`);
} else console.log("\nno full-authority paired runs — nothing to claim");
' $S
echo SWBW-DONE
