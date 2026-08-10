/* sctpwall.mjs — driver for tape-app/public/sctp-probe.html.
 *
 * Investigates the §17.11 transport wall: Lane A's ~125–165 pps of 1.2 KB
 * unreliable/unordered datagrams collapses (~1.2 Mbps carried) at RTT 80 / 1%
 * loss on a path that carried ~14.5 Mbps of ~37 KB video units. This driver
 * applies the SAME --p2psim delay/loss mechanism call.mjs uses (candidate
 * rewriting onto delay proxies — same string, same netsim.mjs) and sweeps the
 * traffic shape: message size × rate × pacing × offered load.
 *
 * Nothing here touches the app. The probe page is its own loopback pc pair.
 *
 * Usage:
 *   node sctpwall.mjs --rtt=80 --loss=1 \
 *     --arm='size=1168&pps=200' --arm='size=4672&pps=50'
 *   node sctpwall.mjs --rtt=80 --loss=1 --sweep=size   # preset arm lists
 *
 * Presets: size (fixed ~1.9 Mbps offered, message size 0.6→37 KB),
 *          rate (fixed 1168 B, pps 100→800), pace (burst vs even),
 *          bundle (Lane A's exact byte stream, N=1..4 frames/message),
 *          clean (80/0 sanity), curve (loss sweep at one shape).
 * Overrides: --dur=, --warmup= apply to every arm.
 *
 * SERIAL LAW: heavy browser runs are one-per-machine. Before EVERY arm this
 * script pgreps for call.mjs|sctpwall.mjs (excluding itself) and waits until
 * the machine is quiet. Each arm is a fresh browser + fresh proxies.
 */
import { chromium } from 'playwright-core';
import { execSync } from 'node:child_process';
import { startP2PSim } from './netsim.mjs';

const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const URL_BASE = 'http://127.0.0.1:8794';

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const body = a.replace(/^--/, '');
    const i = body.indexOf('=');
    return i === -1 ? [body, true] : [body.slice(0, i), body.slice(i + 1)];
  }),
);
// --arm may repeat; Object.fromEntries keeps the last. Re-parse for repeats:
const ARMS = process.argv
  .slice(2)
  .filter((a) => a.startsWith('--arm='))
  .map((a) => a.slice('--arm='.length));

const SIM_RTT = Number(args.rtt ?? 80);
const SIM_LOSS = Number(args.loss ?? 1);
const DUR = Number(args.dur ?? 12000);
const WARM = Number(args.warmup ?? 2500);

const PRESETS = {
  // Fixed offered ~1.9 Mbps payload; only the message shape moves.
  size: [
    'size=600&pps=390',
    'size=1168&pps=200',
    'size=1300&pps=180',
    'size=4672&pps=50',
    'size=16384&pps=15',
    'size=37888&pps=7',
  ],
  // Fixed message (Lane A's), moving packet rate — the SACK-clock discriminator.
  rate: ['size=1168&pps=100', 'size=1168&pps=200', 'size=1168&pps=400', 'size=1168&pps=800'],
  // Pacing at fixed shape/rate.
  pace: [
    'size=1168&pps=200&pace=even',
    'size=1168&pps=200&pace=burst&burstn=4',
    'size=1168&pps=400&pace=even',
    'size=1168&pps=400&pace=burst&burstn=4',
  ],
  // Lane A's exact byte stream (162.5 pps = 125 data + 37.5 parity), bundled
  // N frames per message. Same bytes on the wire; only the shape changes.
  bundle: [
    'size=1168&pps=162.5',
    'size=2352&pps=81.25',
    'size=3536&pps=54.17',
    'size=4720&pps=40.63',
  ],
  clean: ['size=1168&pps=200'],
  curve: ['size=1168&pps=200'],
};
const armList = ARMS.length ? ARMS : PRESETS[args.sweep] || PRESETS.size;
// The curve preset moves loss per arm instead: handled by --losses list.
const LOSSES = args.losses ? String(args.losses).split(',').map(Number) : [SIM_LOSS];

const log = (s) => console.log(s);

// ── Serial guard (project law) ───────────────────────────────────────────────
// Heavy browser runs are one-per-machine. Our own process matches the pattern,
// so exclude our own pid — everyone else is a reason to wait.
function othersRunning() {
  let out = '';
  try {
    out = execSync('pgrep -f "call\\.mjs|sctpwall\\.mjs" || true', { encoding: 'utf8' });
  } catch {
    return [];
  }
  return out
    .split('\n')
    .map((s) => s.trim())
    .filter(Boolean)
    .map(Number)
    .filter((pid) => pid !== process.pid && Number.isFinite(pid));
}
async function waitForQuietMachine() {
  for (;;) {
    const others = othersRunning();
    if (!others.length) return;
    log(`  serial law: another run is up (pid ${others.join(',')}) — waiting 15 s`);
    await new Promise((r) => setTimeout(r, 15000));
  }
}

// ── The candidate-rewrite init script, verbatim from call.mjs ────────────────
// Same mechanism, same physics: every remote candidate is swapped for a delay
// proxy port; the peer's real address is never learned; one crossing per
// direction, so oneWayMs = RTT/2 and lossPct is applied as written.
const P2P_REWRITE = `
  const OrigPC = window.RTCPeerConnection;
  window.__rewrites = [];
  const rewrite = async (line) => {
    const f = String(line).split(' ');
    if (f.length < 7 || !/^udp$/i.test(f[2])) return null;
    const ip = f[4], port = Number(f[5]);
    if (!ip || !Number.isFinite(port) || port <= 0) return null;
    const np = await window.__simProxy(ip, port);
    if (!np) return null;
    f[5] = String(np);
    window.__rewrites.push({ from: ip + ':' + port, to: ip + ':' + np, typ: f[7] || '?' });
    return f.join(' ');
  };
  class SimPC extends OrigPC {
    async addIceCandidate(cand) {
      try {
        const line = typeof cand === 'string' ? cand : cand && cand.candidate;
        if (line) {
          const out = await rewrite(line);
          if (out) {
            const init = typeof cand === 'string'
              ? out
              : { candidate: out, sdpMid: cand.sdpMid, sdpMLineIndex: cand.sdpMLineIndex,
                  usernameFragment: cand.usernameFragment };
            return super.addIceCandidate(init);
          }
        }
      } catch (e) { window.__rewrites.push({ error: String(e).slice(0, 120) }); }
      return super.addIceCandidate(cand);
    }
    async setRemoteDescription(desc) {
      try {
        const sdp = desc && desc.sdp;
        if (sdp && /^a=candidate:/m.test(sdp)) {
          const lines = sdp.split(/\\r?\\n/);
          for (let i = 0; i < lines.length; i++) {
            if (!lines[i].startsWith('a=candidate:')) continue;
            const out = await rewrite(lines[i].slice(2));
            if (out) lines[i] = 'a=' + out;
          }
          return super.setRemoteDescription({ type: desc.type, sdp: lines.join('\\r\\n') });
        }
      } catch (e) { window.__rewrites.push({ error: 'sdp ' + String(e).slice(0, 100) }); }
      return super.setRemoteDescription(desc);
    }
  }
  window.RTCPeerConnection = SimPC;
`;

async function runArm(armQs, lossPct, idx) {
  await waitForQuietMachine();
  const sim = await startP2PSim({
    oneWayMs: SIM_RTT / 2,
    lossPct,
    seed: 1 + idx * 977,
  });
  const qs = `${armQs}&dur=${DUR}&warmup=${WARM}`;
  let browser = null;
  try {
    browser = await chromium.launch({
      executablePath: CHROME,
      headless: true,
      args: [
        '--disable-features=WebRtcHideLocalIpsWithMdns',
        `--unsafely-treat-insecure-origin-as-secure=${URL_BASE}`,
        '--allow-running-insecure-content',
        '--autoplay-policy=no-user-gesture-required',
      ],
    });
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push('pageerror: ' + String(e.message).slice(0, 200)));
    page.on('console', (m) => {
      const t = m.text();
      if (t.startsWith('[probe]')) log('    ' + t.slice(8));
      else if (m.type() === 'error') errors.push(t.slice(0, 200));
    });
    await page.exposeFunction('__simProxy', async (h, p) => sim.portFor(h, p));
    await page.addInitScript(P2P_REWRITE);
    // wrangler assets 307s /sctp-probe.html → /sctp-probe; go there directly.
    await page.goto(`${URL_BASE}/sctp-probe?${qs}`, { waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => window.__done === true, null, {
      timeout: DUR + WARM + 120000,
    });
    const res = await page.evaluate(() => window.__result);
    res.armErrors = errors.slice(0, 3);
    // Harness validity: the proxy's own books (injected drops vs accidents).
    const st = sim.stats;
    res.sim = {
      sent: st.sent, dropped: st.dropped, sendErrors: st.sendErrors,
      bwDropped: st.bwDropped, unreachable: st.unreachable,
      wireMbps: +(((st.bytes * 8) / ((DUR + WARM) / 1000)) / 1e6).toFixed(3),
      latenessP95: sim.lateness()?.p95 ?? null,
      loopLagP95: sim.loopLag()?.p95 ?? null,
    };
    return res;
  } finally {
    if (browser) await browser.close().catch(() => {});
    sim.stop();
  }
}

const fmt = (v, d = 2) => (v === null || v === undefined ? '—' : Number(v).toFixed(d));
log(`\nSCTP wall probe — RTT ${SIM_RTT} ms, loss ${LOSSES.join('/')}% , window ${DUR / 1000}s (+${WARM / 1000}s warmup)`);
log('─'.repeat(130));

const rows = [];
let idx = 0;
for (const loss of LOSSES) {
  for (const arm of armList) {
    const r = await runArm(arm, loss, idx++);
    r.loss = loss;
    rows.push(r);
    const p = r.params;
    if (r.error) {
      log(`  arm ${arm} loss ${loss}: ERROR ${r.error}`);
      continue;
    }
    log(
      `  size=${String(p.size).padStart(5)} pps=${String(p.pps).padEnd(6)} ${p.pace.padEnd(5)} pairs=${p.pairs || 1} loss=${loss}% | ` +
        `carried ${fmt(r.carriedPayloadMbps, 3)} / offered ${fmt(r.sentPayloadMbps, 3)} Mbps payload ` +
        `(wire ICE ${fmt(r.wireSentMbps, 3)}, proxy ${fmt(r.sim.wireMbps, 3)}) | lost ${fmt(r.lostPct, 2)}% gated ${r.gated} | ` +
        `age p50 ${fmt(r.ageP50, 0)} p95 ${fmt(r.ageP95, 0)} max ${fmt(r.ageMax, 0)} ms | ` +
        `ping p50 ${fmt(r.pingP50, 0)} max ${fmt(r.pingMax, 0)} ms | buf p95 ${r.bufP95 ?? '—'}`,
    );
    if (r.sim.sendErrors > 0 || (r.sim.latenessP95 ?? 0) > 20) {
      log(`    ⚠ harness: sendErrors=${r.sim.sendErrors} lateness p95=${r.sim.latenessP95} ms — treat this row with suspicion`);
    }
  }
}

log('\nsummary table (carried = payload Mbps received inside the window; wire = ICE-layer bytes):');
log('| size | pps | pace | pairs | loss% | offered | carried | wire-proxy | lost% | age p50 | age p95 | ping p50 | ping max |');
log('|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|');
for (const r of rows) {
  if (r.error) continue;
  const p = r.params;
  log(
    `| ${p.size} | ${p.pps} | ${p.pace}${p.pace === 'burst' ? '/' + p.burstn : ''} | ${p.pairs || 1} | ${r.loss} | ` +
      `${fmt(r.sentPayloadMbps, 2)} | ${fmt(r.carriedPayloadMbps, 2)} | ${fmt(r.sim.wireMbps, 2)} | ` +
      `${fmt(r.lostPct, 2)} | ${fmt(r.ageP50, 0)} | ${fmt(r.ageP95, 0)} | ${fmt(r.pingP50, 0)} | ${fmt(r.pingMax, 0)} |`,
  );
}
// Per-second series are the collapse dynamics — print them compactly.
for (const r of rows) {
  if (r.error || !r.perSecond?.length) continue;
  const p = r.params;
  log(`\nper-second carried Mbps — size=${p.size} pps=${p.pps} ${p.pace} loss=${r.loss}:`);
  log('  ' + r.perSecond.map((v) => v.toFixed(2)).join(' '));
}
