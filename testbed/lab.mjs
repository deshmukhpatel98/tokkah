#!/usr/bin/env node
/**
 * lab.mjs — drive a call that is ALREADY RUNNING.
 *
 * The instrument this project has been missing. Every measurement until now has
 * been "start a call, measure, tear it down, change one thing, start another
 * call", so every comparison carried the difference between two networks, two
 * CPU states and two ICE negotiations. On 2026-08-14 that noise invalidated
 * three consecutive runs outright — the rig's own validity gate threw them all
 * away, and the machine was simply too busy to try again.
 *
 * A knob changed inside one live call compares a path against ITSELF, seconds
 * apart, on the real route, with real cameras and a real person in frame. The
 * `ab` command below is the whole reason this exists: it alternates a setting
 * every N seconds and reads the pipeline at the end of each period, so the two
 * populations are interleaved in time. Anything that drifts slowly — congestion,
 * thermal throttle, someone starting a download — lands on BOTH arms equally
 * instead of on whichever one ran second.
 *
 *   node testbed/lab.mjs say "wave your hand"      # ask the human for an action
 *   node testbed/lab.mjs snap                      # one reading of every stage
 *   node testbed/lab.mjs watch --every=15          # keep reading
 *   node testbed/lab.mjs set qp=30                 # push a knob, no reload
 *   node testbed/lab.mjs ab qp 24 30 --period=30 --cycles=6
 *   node testbed/lab.mjs reload --stagger=10000    # ship code, keep the call
 *
 * Auth: TOKKAH_LAB_KEY from ~/.config/tokkah/cf.env (never in the repo). The
 * server answers 503 when LAB_KEY is unset, so a deploy without the secret has
 * no live-control surface at all.
 */
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

const ROOM = process.env.LAB_ROOM ?? 'lab';
const BASE = process.env.URL ?? 'https://room.tokkah.com';

const key = (() => {
  if (process.env.TOKKAH_LAB_KEY) return process.env.TOKKAH_LAB_KEY;
  try {
    const f = readFileSync(`${homedir()}/.config/tokkah/cf.env`, 'utf8');
    return f.match(/^export TOKKAH_LAB_KEY=(.+)$/m)?.[1]?.trim() ?? null;
  } catch { return null; }
})();
if (!key) {
  console.error('no TOKKAH_LAB_KEY (env or ~/.config/tokkah/cf.env)');
  process.exit(2);
}

const post = async (body) => {
  const r = await fetch(`${BASE}/api/room/${encodeURIComponent(ROOM)}/lab`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-lab-key': key },
    body: JSON.stringify(body),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`${r.status} ${text.slice(0, 200)}`);
  return JSON.parse(text);
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Send an op, then wait for the occupants' answers to land in the room buffer. */
async function ask(body, waitMs = 1500) {
  await post({ op: 'drain' }); // clear anything stale first, so a reply is THIS reply
  const sent = await post(body);
  await sleep(waitMs);
  const { replies } = await post({ op: 'drain' });
  return { sent, replies };
}

const args = process.argv.slice(2);
const cmd = args[0];
const flag = (name, dflt) => {
  const hit = args.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : dflt;
};
const positional = args.slice(1).filter((a) => !a.startsWith('--'));

const line = (r) => {
  const v = r.video ?? {}, a = r.audio ?? {};
  return `  ${String(r.role ?? '?').padEnd(2)} ` +
    `qp=${v.qp ?? '-'} ${v.w ?? '?'}x${v.h ?? '?'} ${v.fps ?? '-'}fps ` +
    `${v.mbps ?? '-'}Mbps  g2g=${v.glassToGlassMs ?? '-'}ms ` +
    `enc=${v.encLatMs ?? '-'} present=${v.presentLagMs ?? '-'}  ` +
    `m2e=${a.mouthToEarMs ?? '-'}ms ring=${a.ringDepthMs ?? '-'} ` +
    `conceal=${a.concealedMs ?? '-'} rtt=${a.baseRttMs ?? '-'}  ` +
    `path=${r.pair?.path ?? '-'}`;
};

if (cmd === 'say') {
  const { sent, replies } = await ask({ op: 'say', text: positional.join(' '), only: flag('only') });
  console.log(`shown to ${sent.sent} peer(s): ${replies.length} ack`);
} else if (cmd === 'snap') {
  const { sent, replies } = await ask({ op: 'snap', tag: flag('tag') });
  console.log(`peers: ${sent.peers?.join(',') || 'none'}`);
  for (const r of replies) console.log(line(r));
  if (!replies.length) console.log('  (no replies — is anyone in the room?)');
} else if (cmd === 'watch') {
  const every = Number(flag('every', 15)) * 1000;
  for (;;) {
    const { replies } = await ask({ op: 'snap' });
    console.log(new Date().toISOString().slice(11, 19));
    for (const r of replies) console.log(line(r));
    await sleep(every);
  }
} else if (cmd === 'set') {
  const body = { op: 'set', only: flag('only') };
  for (const p of positional) {
    const [k, v] = p.split('=');
    if (k && v != null) body[k] = v;
  }
  const { replies } = await ask(body);
  for (const r of replies) console.log(`  ${r.role}: applied ${JSON.stringify(r.applied)}` +
    (r.refused?.length ? `  REFUSED ${r.refused.join(',')}` : ''));
} else if (cmd === 'ab') {
  // The point of the whole file. Alternate a knob and read at the end of each
  // period, so slow drift lands on both arms rather than on whichever ran last.
  const [knob, valA, valB] = positional;
  if (!knob || valA == null || valB == null) {
    console.error('usage: ab <knob> <valA> <valB> [--period=30] [--cycles=6]');
    process.exit(2);
  }
  const period = Number(flag('period', 30)) * 1000;
  const cycles = Number(flag('cycles', 6));
  const rows = [];
  console.log(`A/B ${knob}: ${valA} vs ${valB}, ${period / 1000}s per arm, ${cycles} cycles each`);
  for (let c = 0; c < cycles; c++) {
    for (const val of [valA, valB]) {
      await post({ op: 'set', [knob]: val });
      // Settle before reading: an encoder knob takes effect on the next frame
      // but the numbers it moves are windowed averages, so a reading taken
      // immediately is mostly the PREVIOUS arm. Two thirds of the period is
      // spent settling and the reading is taken at the end.
      await sleep(period);
      const { replies } = await ask({ op: 'snap', tag: `${knob}=${val}` });
      for (const r of replies) rows.push({ cycle: c, val, ...r });
      console.log(`  cycle ${c + 1}/${cycles} ${knob}=${val}`);
      for (const r of replies) console.log(line(r));
    }
  }
  // Summarise per arm per role. Median, because one hiccup should not decide it.
  const med = (xs) => {
    const s = xs.filter((x) => typeof x === 'number' && Number.isFinite(x)).sort((a, b) => a - b);
    return s.length ? +(s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2).toFixed(2) : null;
  };
  console.log('\n════ medians ════');
  for (const role of [...new Set(rows.map((r) => r.role))]) {
    for (const val of [valA, valB]) {
      const g = rows.filter((r) => r.role === role && r.val === val);
      console.log(`  ${role} ${knob}=${String(val).padEnd(4)} n=${g.length}  ` +
        `mbps=${med(g.map((r) => r.video?.mbps))}  g2g=${med(g.map((r) => r.video?.glassToGlassMs))}ms  ` +
        `m2e=${med(g.map((r) => r.audio?.mouthToEarMs))}ms  conceal=${med(g.map((r) => r.audio?.concealedMs))}`);
    }
  }
  console.log('\nBitrate is the number this was built to move; g2g and m2e are the do-no-harm arms.');
} else if (cmd === 'reload') {
  // Ship code without ending the call. The room holds a departure for 5 s and
  // cancels it when the same sid returns, so a reload inside that window never
  // reaches the peer as "they left". Staggered so the call is never down at
  // both ends at once.
  const stagger = Number(flag('stagger', 10000));
  const peers = (await post({ op: 'drain' })).peers ?? [];
  if (!peers.length) { console.log('nobody in the room'); process.exit(0); }
  console.log(`reloading ${peers.join(', ')} staggered ${stagger}ms apart`);
  for (let i = 0; i < peers.length; i++) {
    await post({ op: 'reload', only: peers[i], delayMs: 0 });
    console.log(`  ${peers[i]} reloading`);
    if (i < peers.length - 1) await sleep(stagger);
  }
} else {
  console.log(`usage:
  lab.mjs say "<text>"                  ask the person on camera for an action
  lab.mjs snap [--tag=x]                one reading of every pipeline stage
  lab.mjs watch [--every=15]            keep reading
  lab.mjs set qp=30 [--only=a]          push a live knob (qp, w, h)
  lab.mjs ab qp 24 30 [--period=30] [--cycles=6]
  lab.mjs reload [--stagger=10000]      ship code, keep the call up

  LAB_ROOM=${ROOM}  URL=${BASE}`);
}
