#!/usr/bin/env node
/**
 * suite.mjs — the routine pass: every live rig, one verdict table.
 *
 * Sequential on purpose: these rigs share prod, the host CPU, and (one of
 * them) the Android emulator — parallel runs would measure each other.
 *
 * Rigs and what each one guards:
 *   lab-verify   desktop<->desktop call + live-lab controls (read/steer/ship)
 *   emucall      real Android Chrome (emulator) <-> desktop, lossless lane
 *                both ways via codec negotiation      [needs emu-boot.sh]
 *   camsensor    camera controllers vs REAL recorded sensor traces (pre-check
 *                lane only — real-sensor law lives in phone-test.sh)
 *   camdeath     hard camera death mid-call: peer keeps audio, video returns
 *   elasticring  bursty-path audio: ceiling stretches AND depth follows
 *   bytepace     pinned-QP flood: resolution actuator holds budget at 30 fps
 *
 *   node testbed/suite.mjs [--skip=emucall,...]
 */
import { spawn } from 'node:child_process';

const here = decodeURIComponent(new URL('.', import.meta.url).pathname);
const skip = new Set((process.argv.find((a) => a.startsWith('--skip='))?.slice(7) ?? '').split(',').filter(Boolean));

const RIGS = [
  { name: 'lab-verify', file: 'lab-verify.mjs', timeoutS: 300 },
  { name: 'emucall', file: 'emucall.mjs', timeoutS: 420, pre: ['emu-boot.sh'] },
  { name: 'camsensor', file: 'camsensor.mjs', timeoutS: 420 },
  { name: 'camdeath', file: 'camdeath.mjs', timeoutS: 420 },
  { name: 'elasticring', file: 'elasticring.mjs', timeoutS: 600 },
  { name: 'bytepace', file: 'bytepace.mjs', timeoutS: 420 },
];

const run = (cmd, args, timeoutS) => new Promise((resolve) => {
  const t0 = Date.now();
  const p = spawn(cmd, args, { cwd: here, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  const cap = (d) => { out += d; if (out.length > 400000) out = out.slice(-200000); };
  p.stdout.on('data', cap);
  p.stderr.on('data', cap);
  const killer = setTimeout(() => { p.kill('SIGKILL'); }, timeoutS * 1000);
  p.on('close', (code) => {
    clearTimeout(killer);
    resolve({ code, out, secs: Math.round((Date.now() - t0) / 1000) });
  });
});

const rows = [];
for (const rig of RIGS) {
  if (skip.has(rig.name)) { rows.push({ name: rig.name, verdict: 'SKIP', secs: 0 }); continue; }
  process.stdout.write(`━━ ${rig.name} ` + '━'.repeat(Math.max(1, 60 - rig.name.length)) + '\n');
  for (const pre of rig.pre ?? []) {
    const r = await run('bash', [pre], 420);
    if (r.code !== 0) {
      console.log(r.out.split('\n').slice(-5).join('\n'));
      rows.push({ name: rig.name, verdict: 'BLOCKED', secs: r.secs, why: `${pre} exit ${r.code}` });
    }
  }
  if (rows.at(-1)?.name === rig.name) continue; // pre failed
  const r = await run('node', [rig.file], rig.timeoutS);
  // Trust each rig's own verdict line over its exit code; a crash without a
  // verdict is a FAIL of the harness kind and says so.
  const verdictLine = r.out.split('\n').reverse().find((l) => l.startsWith('VERDICT:'))
    ?? (r.out.includes('\nPASS') && r.code === 0 ? 'VERDICT: PASS' : null);
  const verdict = verdictLine ? verdictLine.replace('VERDICT: ', '') : `CRASH(exit ${r.code})`;
  console.log(r.out.split('\n').filter((l) => /^(PASS|FAIL|VERDICT)/.test(l)).join('\n'));
  rows.push({ name: rig.name, verdict, secs: r.secs });
}

console.log('\n══════ SUITE ══════');
let bad = 0;
for (const r of rows) {
  const ok = r.verdict === 'PASS' || r.verdict === 'SKIP';
  if (!ok) bad++;
  console.log(`  ${r.name.padEnd(12)} ${String(r.verdict).padEnd(10)} ${r.secs}s${r.why ? `  (${r.why})` : ''}`);
}
console.log(bad === 0 ? '\nSUITE: PASS' : `\nSUITE: FAIL (${bad} rig${bad > 1 ? 's' : ''})`);
process.exit(bad ? 1 : 0);
