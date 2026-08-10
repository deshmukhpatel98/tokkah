#!/bin/zsh
# WHAT DOES 72 fps COST IN PICTURE QUALITY? (task #30 — the gate on the 72 fps default)
#
# Direction is known (rcQp 28.5 -> 36.4 when the ask rose), size is not: a third run gave
# WORSE QP on LESS bandwidth, so the GCC budget varies too much between runs for n=1 per
# arm. INTERLEAVED, 3 reps per rate, order rotated so no rate always follows a cold start.
# Fixed QP 24 so the encoder is not also a variable; what moves is delivered bitrate and
# delivered frames, and both are REPORTED beside VMAF because VMAF cannot see a dropped
# frame. The verdict is quality-at-cost, not quality.
#
# FIXTURE: motion1080_72.y4m (72 fps), NOT cam1080.mjpeg (30 fps) — the first attempt ran
# all three arms camera-bound at 30 and measured nothing but its own noise floor
# ([[stimulus-can-be-the-bottleneck]], fourth occurrence).
set -e
S=/private/tmp/claude-501/-Users-earningsgpt-video-calling/477cd6ea-c192-43a3-b107-a2011157fa96/scratchpad
cd "/Users/deveshpatel/Downloads/video calling"
mkdir -p $S/fpsq

have() { node -e 'try{process.exit(JSON.parse(require("fs").readFileSync(process.argv[1]+"/run.json","utf8")).tag?0:1)}catch{process.exit(1)}' "$1"; }

run() { # run <fps> <rep>
  local d=$S/fpsq/f$1-r$2
  if have "$d"; then echo "  SKIP f$1-r$2"; return; fi
  echo "=== fps=$1 rep=$2  $(date +%H:%M:%S)"
  node testbed/vmaf-call.mjs --tag="f$1-r$2" --q="tape=2&pcmaudio=1&qp=24&fpsmax=$1" \
    --video=media/motion1080_72.y4m --out="$d" --capms=22000 > "$d.log" 2>&1 || echo "  f$1-r$2 FAILED"
  sleep 20
}

# Rotated order: each rate appears in every position once.
run 30 1; run 48 1; run 72 1
run 48 2; run 72 2; run 30 2
run 72 3; run 30 3; run 48 3

for d in $S/fpsq/f*-r*; do
  [ -d "$d" ] || continue
  [ -f "$d/scores.json" ] && continue
  node testbed/vmaf-score.mjs --dir="$d" --src=testbed/media/motion1080_72.y4m >> "$d.log" 2>&1 || echo "score failed: $d"
done

echo "== SUMMARY (VMAF beside DELIVERED rate — never quality alone) =="
node -e '
const fs=require("fs");
const S=process.argv[1]+"/fpsq";
const by={};
for (const d of fs.readdirSync(S).filter(x=>/^f\d+-r\d/.test(x) && !x.endsWith(".log"))) {
  try {
    const r=JSON.parse(fs.readFileSync(`${S}/${d}/run.json`,"utf8"));
    const sc=JSON.parse(fs.readFileSync(`${S}/${d}/scores.json`,"utf8"));
    const s=r.lane.senderA, fps=d.match(/^f(\d+)/)[1];
    (by[fps]??=[]).push({d, vmaf:sc.vmaf.mean, p5:sc.vmaf.p5, mbps:s.mbpsAtFps,
      del:s.framesEncoded, in:s.framesIn, age:s.ageP50, qp:s.rcQp});
  } catch {}
}
console.log("fps  n   VMAF (each rep)          p5 worst   Mbps (each)        delivered/captured   age");
for (const f of Object.keys(by).sort((a,b)=>a-b)) {
  const v=by[f];
  console.log(`${f.padStart(3)}  ${v.length}   ${v.map(x=>x.vmaf.toFixed(2)).join(", ").padEnd(22)} ${Math.min(...v.map(x=>x.p5)).toFixed(1).padStart(7)}   ${v.map(x=>x.mbps).join(", ").padEnd(17)} ${v.map(x=>`${x.del}/${x.in}`).join(" ")}  ${v.map(x=>x.age).join(",")}`);
}
console.log("\nSpread within a rate is the run-to-run GCC noise; a between-rate claim must clear it.");
' $S
echo FPSQ-DONE
