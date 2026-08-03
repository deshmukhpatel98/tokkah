#!/bin/zsh
# IS THE "SAFARI 8x CONCEALMENT" ACTUALLY HOST LOAD? (task #33, goal #1)
#
# The cross-engine measurement blamed co-location: WebKit's media processes ran 86-103% of
# a core, host scheduler lateness tripled, and 15 of 16 stalls were coincident within
# 25 ms against 0.2 expected by chance. That predicts the 8x is not WebKit's decoder or
# network stack at all — it is what ANY extra core of load does to this audio pipeline.
#
# TEST WITHOUT SAFARI: Chrome-to-Chrome, unshaped link, and a synthetic ~1-core burner
# during the middle third of the call. If concealment multiplies like the WebKit runs did,
# the mechanism is host load and the fix (worklet/thread priority, shed paths) helps every
# loaded machine. If it stays flat, the engine mattered after all.
#
# The burner is spawned/killed by THIS script so its exhaust is accounted for, not
# discovered ([[a-guard-that-fires-on-its-own-exhaust]], [[an-instrument-needs-an-alibi]]).
# Paired inside one call is impossible for a HOST-wide stressor (both sides share the
# machine), so this is before/during/after within one call instead: each call is its own
# control, and the null arm (no burner) measures the drift of that design.
set -e
S=/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad
cd "/Users/earningsgpt/video calling"
mkdir -p $S/load

have() { node -e 'try{process.exit(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).result?0:1)}catch{process.exit(1)}' "$1"; }

# relpair with equal everything = a null release A/B; we only want its per-2s series and
# stall ledger. The burner runs from t=+35s for 30s (the middle of the 90s window
# settle 15 + recover 75). One spinning zsh loop ~= one core.
run() { # run <json> <burn:0|1> <label>
  if have "$1"; then echo "  SKIP $3"; return; fi
  echo "=== $3   $(date +%H:%M:%S)"
  if [ "$2" = "1" ]; then
    # ONE spinner was not enough stimulus: 3 burner runs moved concealment by at most 6
    # frames on a 10-core host. The WebKit signature was scheduler lateness TRIPLING,
    # and one core of 10 does not queue anything. 8 spinners approximates the all-cores
    # pressure a busy laptop actually has. Escalate the stimulus, then judge.
    ( sleep 35
      end=$((SECONDS+30))
      for _ in 1 2 3 4 5 6 7 8; do
        ( while [ $SECONDS -lt $end ]; do :; done ) &
      done
      wait ) &
    BURN_PID=$!
  fi
  node testbed/relpair.mjs --relA=2 --relB=2 --hole=0 --settle=15 --recover=75 \
    --json="$1" > "${1%.json}.log" 2>&1 || echo "  $3 FAILED (see log)"
  [ "$2" = "1" ] && { kill $BURN_PID 2>/dev/null || true; wait $BURN_PID 2>/dev/null || true; }
  sleep 30
}

run $S/load/h-n1.json 0 "null 1 (no burner)"
run $S/load/h-b1.json 1 "burn 1 (1 core, t=35..65)"
run $S/load/h-b2.json 1 "burn 2"
run $S/load/h-n2.json 0 "null 2"
run $S/load/h-b3.json 1 "burn 3"

echo "== SUMMARY: concealment per third (before / during / after the burner window) =="
node -e '
const fs=require("fs");const D=process.argv[1]+"/load";
for (const f of fs.readdirSync(D).filter(x=>x.endsWith(".json")).sort()) {
  let j; try{ j=JSON.parse(fs.readFileSync(`${D}/${f}`,"utf8")); }catch{ continue; }
  if (!j.result) { console.log(`${f}: no result`); continue; }
  const s=j.series;
  const seg=(a,b)=>{ // lost frames accumulated in series window [a,b) seconds, both sides summed
    const rows=s.filter(r=>r.t>=a&&r.t<b);
    if (rows.length<2) return null;
    return (rows.at(-1).A.lost-rows[0].A.lost)+(rows.at(-1).B.lost-rows[0].B.lost);
  };
  // burner runs t=35..65 relative to page-join; series t starts after settle(15) so
  // the burner window is series t ~ 20..50.
  console.log(`${f.padEnd(9)} before(0-20) ${seg(0,20)}  during(20-50) ${seg(20,50)}  after(50-75) ${seg(50,75)}   depthPeak ${Math.max(...s.map(r=>Math.max(r.A.depth,r.B.depth)))}`);
}
console.log("\nburner arms should spike DURING only; nulls flat. If during ~ 8x before, the");
console.log("cross-engine 8x is host load and Safari is innocent of most of it.");
' $S
echo LOAD-SEQUENCE-DONE
