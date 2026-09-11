#!/usr/bin/env node
/**
 * Ad engine — score a render against a reference film by the metrics in
 * REPLICATE.md. Numbers, not opinions:
 *   - structure: shot-boundary times (scene-score peaks) matched within a tolerance
 *   - light: per-second mean luminance, Pearson correlation and mean absolute delta
 *   - motion: per-second mean scene score correlation
 *   - type: on chosen frames, dark-text bounding boxes compared (position, size)
 *
 *   node ad/engine/score.mjs <ours.mp4> <reference.mp4> [--type 34.8,36.6] [--tol-frames 2] [--json out.json]
 * Requires ffmpeg on PATH or ~/.local/bin; python3 with Pillow + numpy for type boxes.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const FFMPEG = fs.existsSync(path.join(os.homedir(), ".local/bin/ffmpeg")) ? path.join(os.homedir(), ".local/bin/ffmpeg") : "ffmpeg";
const argv = process.argv.slice(2);
const [ours, ref] = argv.filter(a => !a.startsWith("--"));
if (!ours || !ref) { console.error("usage: score.mjs <ours.mp4> <reference.mp4> [--type t1,t2] [--tol-frames 2] [--json out]"); process.exit(2); }
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const typeTimes = (opt("--type", "") || "").split(",").map(Number).filter(x => isFinite(x) && x > 0);
const tolFrames = +opt("--tol-frames", 2);

function probe(file) {
  const out = spawnSync(FFMPEG, ["-nostats", "-hide_banner", "-i", file, "-vf", "select='gte(scene,0)',metadata=print:key=lavfi.scene_score,signalstats,metadata=print:key=lavfi.signalstats.YAVG", "-f", "null", "-"], { encoding: "utf8", maxBuffer: 1 << 28 }).stderr;
  const frames = new Map(); let cur = null;
  for (const line of out.split("\n")) {
    const m = line.match(/frame:(\d+)\s+pts:\d+\s+pts_time:([\d.]+)/);
    if (m) { cur = frames.get(+m[1]) || { i: +m[1], t: +m[2] }; frames.set(+m[1], cur); continue; }
    if (!cur) continue;
    const s = line.match(/lavfi\.scene_score=([\d.]+)/); if (s) cur.scene = +s[1];
    const y = line.match(/lavfi\.signalstats\.YAVG=([\d.]+)/); if (y) cur.y = +y[1];
  }
  const arr = [...frames.values()].sort((a, b) => a.i - b.i);
  const dur = arr.length ? arr[arr.length - 1].t : 0;
  const fps = arr.length > 1 ? (arr.length - 1) / (arr[arr.length - 1].t - arr[0].t) : 30;
  return { frames: arr, dur, fps };
}
function cuts(p, thresh = 0.28) { return p.frames.filter(f => (f.scene || 0) > thresh).map(f => +f.t.toFixed(3)); }
function perSecond(p, key) { const out = []; for (let s = 0; s < Math.ceil(p.dur); s++) { const fs_ = p.frames.filter(f => f.t >= s && f.t < s + 1); out.push(fs_.length ? fs_.reduce((a, f) => a + (f[key] || 0), 0) / fs_.length : 0); } return out; }
function pearson(a, b) { const n = Math.min(a.length, b.length); if (n < 3) return 0; const ma = a.slice(0, n).reduce((x, y) => x + y, 0) / n, mb = b.slice(0, n).reduce((x, y) => x + y, 0) / n; let sab = 0, saa = 0, sbb = 0; for (let i = 0; i < n; i++) { const da = a[i] - ma, db = b[i] - mb; sab += da * db; saa += da * da; sbb += db * db; } return saa && sbb ? sab / Math.sqrt(saa * sbb) : 0; }
function mad(a, b) { const n = Math.min(a.length, b.length); let s = 0; for (let i = 0; i < n; i++) s += Math.abs(a[i] - b[i]); return n ? s / n : 0; }

console.error("# probing ours…"); const A = probe(ours);
console.error("# probing reference…"); const B = probe(ref);
const tol = tolFrames / B.fps;
const cutsA = cuts(A), cutsB = cuts(B);
const matched = cutsB.filter(t => cutsA.some(u => Math.abs(u - t) <= tol));
const structure = { referenceCuts: cutsB.length, ourCuts: cutsA.length, matchedWithinTol: matched.length, tolSeconds: +tol.toFixed(3), missing: cutsB.filter(t => !matched.includes(t)), extra: cutsA.filter(u => !cutsB.some(t => Math.abs(u - t) <= tol)) };
const lumA = perSecond(A, "y"), lumB = perSecond(B, "y");
const motA = perSecond(A, "scene"), motB = perSecond(B, "scene");
const light = { correlation: +pearson(lumA, lumB).toFixed(3), meanAbsDelta: +mad(lumA, lumB).toFixed(1), ours: lumA.map(v => +v.toFixed(0)), reference: lumB.map(v => +v.toFixed(0)) };
const motion = { correlation: +pearson(motA, motB).toFixed(3) };

// type boxes on chosen frames, via a small Python helper (Pillow + numpy)
const PY = `
import sys, json
from PIL import Image
import numpy as np
def boxes(path, light):
    a = np.array(Image.open(path).convert("L")); mask = (a > 90) if light else (a < 110)
    m = mask[::2, ::2]; h, w = m.shape; lab = np.zeros((h, w), dtype=np.int32); n = 0; out = []
    ys, xs = np.nonzero(m); todo = set(zip(ys.tolist(), xs.tolist()))
    while todo:
        y, x = todo.pop(); n += 1; st = [(y, x)]; miny = maxy = y; minx = maxx = x; c = 0
        while st:
            cy, cx = st.pop()
            if lab[cy, cx]: continue
            lab[cy, cx] = n; c += 1; miny = min(miny, cy); maxy = max(maxy, cy); minx = min(minx, cx); maxx = max(maxx, cx)
            for ny, nx in ((cy-1, cx), (cy+1, cx), (cy, cx-1), (cy, cx+1)):
                if 0 <= ny < h and 0 <= nx < w and m[ny, nx] and not lab[ny, nx]:
                    todo.discard((ny, nx)); st.append((ny, nx))
        if c >= 6: out.append([minx*2, miny*2, maxx*2+1, maxy*2+1])
    out.sort(key=lambda b: (b[1], b[0])); lines = []
    for b in out:
        for L in lines:
            if not (b[3] < L[1]-4 or b[1] > L[3]+4) and b[0] <= L[2]+40 and b[2] >= L[0]-40:
                L[0]=min(L[0],b[0]); L[1]=min(L[1],b[1]); L[2]=max(L[2],b[2]); L[3]=max(L[3],b[3]); break
        else: lines.append(list(b))
    return [L for L in lines if L[2]-L[0] > 20 and L[3]-L[1] > 8]
ours, ref = sys.argv[1], sys.argv[2]
bg = float(np.median(np.array(Image.open(ref).convert("L")))); light = bg < 80
print(json.dumps({"ours": boxes(ours, light), "reference": boxes(ref, light), "lightText": light}))
`;
const typeResults = [];
for (const t of typeTimes) {
  const fa = path.join(os.tmpdir(), `score-ours-${t}.png`), fb = path.join(os.tmpdir(), `score-ref-${t}.png`);
  spawnSync(FFMPEG, ["-loglevel", "error", "-y", "-ss", String(t), "-i", ours, "-frames:v", "1", fa]);
  spawnSync(FFMPEG, ["-loglevel", "error", "-y", "-ss", String(t), "-i", ref, "-frames:v", "1", fb]);
  const r = spawnSync("python3", ["-c", PY, fa, fb], { encoding: "utf8" });
  if (r.status !== 0) { typeResults.push({ t, error: r.stderr.slice(-300) }); continue; }
  const j = JSON.parse(r.stdout);
  // greedy match each reference box to the nearest of ours by centre
  const pairs = j.reference.map(rb => {
    const rc = [(rb[0] + rb[2]) / 2, (rb[1] + rb[3]) / 2];
    let best = null, bd = 1e9;
    for (const ob of j.ours) { const oc = [(ob[0] + ob[2]) / 2, (ob[1] + ob[3]) / 2]; const d = Math.hypot(oc[0] - rc[0], oc[1] - rc[1]); if (d < bd) { bd = d; best = ob; } }
    return best ? { ref: rb, ours: best, centreDeltaPx: +bd.toFixed(1), widthRatio: +((best[2] - best[0]) / (rb[2] - rb[0])).toFixed(3), heightRatio: +((best[3] - best[1]) / (rb[3] - rb[1])).toFixed(3) } : { ref: rb, ours: null };
  });
  typeResults.push({ t, referenceBoxes: j.reference.length, ourBoxes: j.ours.length, pairs });
}

const report = { ours, reference: ref, durations: { ours: +A.dur.toFixed(2), reference: +B.dur.toFixed(2) }, structure, light, motion, type: typeResults };
const out = opt("--json", null); if (out) fs.writeFileSync(out, JSON.stringify(report, null, 2));
console.log(`duration  ours ${report.durations.ours}s  ref ${report.durations.reference}s`);
console.log(`cuts      ref ${structure.referenceCuts}  ours ${structure.ourCuts}  matched within ${tolFrames} frames: ${structure.matchedWithinTol}` + (structure.missing.length ? `  missing at ${structure.missing.join(", ")}` : ""));
console.log(`light     correlation ${light.correlation}  mean |delta| ${light.meanAbsDelta} (0-255)`);
console.log(`motion    correlation ${motion.correlation}`);
for (const tr of typeResults) console.log(`type @${tr.t}s  ref boxes ${tr.referenceBoxes ?? "?"}  ours ${tr.ourBoxes ?? "?"}  ` + (tr.pairs ? tr.pairs.map(p => p.ours ? `Δ${p.centreDeltaPx}px w×${p.widthRatio} h×${p.heightRatio}` : "unmatched").join(" | ") : tr.error));
