/**
 * CPU-seconds per call-minute, per browser process tree (task #48).
 *
 * The Mac has no unprivileged joules counter (`powermetrics` needs sudo, and
 * changing system settings is off the table), so the battery proxy is CPU time:
 * it is what heats the chip, and on a phone it is most of what drains the
 * battery during a call. GPU time is invisible to this instrument — a result
 * that moves render work between CPU and GPU must be re-checked another way
 * before it is believed (a-watchdog-that-cannot-see).
 *
 *   node energy.mjs --tag=prof-a --tag=prof-b [--sec=180] [--every=5] [--json=out.json]
 *
 * Each --tag names a substring of the ROOT browser process's command line
 * (the --user-data-dir value works). Every process whose ancestry reaches a
 * root carrying the tag is attributed to that tag — renderers, GPU helper,
 * network service, the lot. Chromium helpers carry the same user-data-dir on
 * their own command lines too, which this also matches; ancestry is the
 * fallback for helpers that don't.
 *
 * Accounting: cumulative `cputime` per PID, sampled every --every seconds.
 * A process that dies mid-run keeps its last observed reading (its work
 * happened); a PID that appears mid-run counts from its first reading, which
 * is its true start since cputime is cumulative from exec. Sampling exists
 * only to catch churn — the number is END minus START, not an integral of
 * instantaneous %CPU (a rectified-derivative style bias magnet).
 */
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const args = process.argv.slice(2);
const KNOWN = new Set(['tag', 'sec', 'every', 'json']);
for (const a of args) {
  const m = a.match(/^--([a-zA-Z0-9_]+)=/);
  if (!m || !KNOWN.has(m[1])) { console.error(`unknown flag ${a} — flags are: ${[...KNOWN].map((k) => '--' + k).join(' ')}`); process.exit(2); }
}
const TAGS = args.filter((a) => a.startsWith('--tag=')).map((a) => a.slice(6));
const argv = (k, d) => { const m = args.find((a) => a.startsWith(`--${k}=`)); return m ? m.slice(k.length + 3) : d; };
const SEC = Number(argv('sec', 180));
const EVERY = Number(argv('every', 5));
const JSON_OUT = argv('json', null);
if (!TAGS.length) { console.error('need at least one --tag='); process.exit(2); }

const cputimeToS = (t) => {
  // ps cputime: [dd-]hh:mm:ss.cc or mm:ss.cc
  const dm = t.match(/^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$/);
  if (!dm) return null;
  return (Number(dm[1] ?? 0) * 86400) + (Number(dm[2] ?? 0) * 3600) + Number(dm[3]) * 60 + Number(dm[4]);
};

const snapshot = () => {
  const out = execFileSync('ps', ['-axo', 'pid=,ppid=,cputime=,rss=,command='], { maxBuffer: 32 * 1024 * 1024 }).toString();
  const rows = [];
  for (const line of out.split('\n')) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\d+)\s+(.*)$/);
    if (m) rows.push({ pid: +m[1], ppid: +m[2], cpu: cputimeToS(m[3]), rss: +m[4], cmd: m[5] });
  }
  const byPid = new Map(rows.map((r) => [r.pid, r]));
  const tagOf = (r) => {
    // Direct match first (Chromium helpers repeat --user-data-dir), then ancestry.
    for (const t of TAGS) if (r.cmd.includes(t)) return t;
    let cur = r, hops = 0;
    while (cur && hops++ < 20) {
      for (const t of TAGS) if (cur.cmd.includes(t)) return t;
      cur = byPid.get(cur.ppid);
    }
    return null;
  };
  const seen = new Map(); // pid -> {tag, cpu, rss}
  for (const r of rows) {
    if (r.cpu === null) continue;
    const t = tagOf(r);
    if (t) seen.set(r.pid, { tag: t, cpu: r.cpu, rss: r.rss });
  }
  return seen;
};

// first[pid] = cputime at first sighting; last[pid] = latest reading.
const first = new Map(), last = new Map();
const absorb = (snap) => {
  for (const [pid, v] of snap) {
    if (!first.has(pid)) first.set(pid, v);
    last.set(pid, v);
  }
};
const t0 = Date.now();
absorb(snapshot());
const ticks = [];
while (Date.now() - t0 < SEC * 1000) {
  await new Promise((r) => setTimeout(r, EVERY * 1000));
  const snap = snapshot();
  absorb(snap);
  const perTag = {};
  for (const t of TAGS) perTag[t] = { cpuS: 0, rssMb: 0, procs: 0 };
  for (const [pid, v] of last) {
    const f = first.get(pid);
    perTag[v.tag].cpuS += v.cpu - f.cpu;
    if (snap.has(pid)) { perTag[v.tag].rssMb += v.rss / 1024; perTag[v.tag].procs++; }
  }
  const el = (Date.now() - t0) / 1000;
  ticks.push({ t: +el.toFixed(1), ...Object.fromEntries(Object.entries(perTag).map(([k, v]) => [k, +v.cpuS.toFixed(1)])) });
  console.log(`t=${el.toFixed(0).padStart(4)}s  ` + TAGS.map((t) => `${t}: ${perTag[t].cpuS.toFixed(1)} cpu-s (${perTag[t].procs} procs, ${perTag[t].rssMb.toFixed(0)} MB)`).join('   '));
}

const wallMin = (Date.now() - t0) / 60000;
console.log(`\n== ${wallMin.toFixed(2)} wall minutes ==`);
const result = { wallMin: +wallMin.toFixed(2), tags: {} };
for (const t of TAGS) {
  let cpuS = 0;
  for (const [pid, v] of last) if (v.tag === t) cpuS += v.cpu - first.get(pid).cpu;
  result.tags[t] = { cpuS: +cpuS.toFixed(1), cpuSPerMin: +(cpuS / wallMin).toFixed(1), coreFrac: +(cpuS / (wallMin * 60)).toFixed(3) };
  console.log(`${t}: ${cpuS.toFixed(1)} cpu-s total = ${(cpuS / wallMin).toFixed(1)} cpu-s/min = ${(cpuS / (wallMin * 60)).toFixed(3)} cores sustained`);
}
result.ticks = ticks;
if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(result, null, 1));
