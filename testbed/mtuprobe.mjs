/**
 * How many datagrams does one datachannel message actually cost?
 *
 * The PCM audio lane sends 1176 B frames (384 samples int24 + a 24 B header) and
 * loses them at 13.4% on a link dropping 5.56% — a message split across k
 * datagrams dies if ANY piece dies, so the effective loss is 1-(1-p)^k. Every
 * candidate fix (shrink the header, shrink the frame, compress losslessly) needs
 * the same input: the largest message that still costs ONE datagram. That number
 * is set by Chrome's SCTP fragment size minus DTLS/SCTP overhead, it is not
 * documented anywhere we can cite, and guessing it is how you ship a "fix" that
 * lands 4 bytes on the wrong side of the line.
 *
 * Method: two peer connections in ONE page, wired to each other through the same
 * UDP proxy the loss tests use, then send a fixed count of messages at each size
 * and read the proxy's own packet-size histogram. A message that fits shows up as
 * one large datagram; a message that does not shows up as one large datagram plus
 * a small tail. The tail count IS the answer, and it comes from the emulator
 * rather than from anything the application believes about itself.
 *
 *   node testbed/mtuprobe.mjs
 */
import { chromium } from '/Users/deveshpatel/Downloads/video calling/testbed/node_modules/playwright-core/index.mjs';
import { startP2PSim } from './netsim.mjs';

const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
// Sweep the boundary itself, not the decades. Baseline is ~1.5 datagrams/message
// (one data packet plus SACK traffic), so fragmentation is >2.0, not >1.5.
const arg = (k, d) => {
  const m = process.argv.find((a) => a.startsWith(`--${k}=`));
  return m ? Number(m.slice(k.length + 3)) : d;
};
const list = (k, d) => {
  const m = process.argv.find((a) => a.startsWith(`--${k}=`));
  return m ? m.slice(k.length + 3).split(',').map(Number) : d;
};
const SIZES = list('sizes', [600, 800, 900, 1000, 1100, 1157, 1160, 1176]);
// 600, not 150: separating 5.6% from 10.9% loss is the whole point of the loss
// arm, and at N=150 those are 8 vs 16 expected drops with sd ~2.8 — overlapping.
// At 600 they are 34 vs 65 with sd ~5.6, which no run can confuse.
const N = arg('n', 600);
// ms between messages on the one probe association. 24 = 125/3, one stripe's
// share of the audio lane. Raise it to model a slower lane, never lower it
// without checking maxBuf.
const GAP = arg('gap', 24);

const LOSS = arg('loss', 0);
const sim = await startP2PSim({ oneWayMs: arg('rtt', 20) / 2, jitterMs: 0, lossPct: LOSS, bwMbps: 0, queueMs: 100 });

const P2P_REWRITE = `
  const OrigPC = window.RTCPeerConnection;
  const rewrite = async (line) => {
    const f = String(line).split(' ');
    if (f.length < 7 || !/^udp$/i.test(f[2])) return null;
    const ip = f[4], port = Number(f[5]);
    if (!ip || !Number.isFinite(port) || port <= 0) return null;
    const np = await window.__simProxy(ip, port);
    if (!np) return null;
    f[5] = String(np);
    return f.join(' ');
  };
  class SimPC extends OrigPC {
    async addIceCandidate(cand) {
      try {
        const line = typeof cand === 'string' ? cand : cand && cand.candidate;
        if (line) {
          const nl = await rewrite(line.replace(/^a=/, ''));
          // Spreading an RTCIceCandidate copies NOTHING — its fields sit on the
          // prototype, not as own enumerable properties — so {...cand} silently
          // drops sdpMid/sdpMLineIndex and addIceCandidate rejects every one.
          if (nl) return super.addIceCandidate({ candidate: nl, sdpMid: cand.sdpMid,
            sdpMLineIndex: cand.sdpMLineIndex, usernameFragment: cand.usernameFragment });
        }
      } catch {}
      return super.addIceCandidate(cand);
    }
  }
  window.RTCPeerConnection = SimPC;
`;

// Without this Chrome publishes host candidates as mDNS `.local` names, the
// rewrite has no numeric address to map, and the media traffic bypasses the proxy
// entirely — the probe would then read zero datagrams and call it a pass.
const ctx = await chromium.launchPersistentContext('', {
  executablePath: CHROME, headless: true,
  args: ['--disable-features=WebRtcHideLocalIpsWithMdns'],
});
const p = await ctx.newPage();
await p.exposeFunction('__simProxy', async (h, port) => sim.portFor(h, port));
await p.addInitScript(P2P_REWRITE);
await p.goto('about:blank');

const ready = await p.evaluate(async () => {
  const a = new RTCPeerConnection(), b = new RTCPeerConnection();
  a.onicecandidate = (e) => e.candidate && b.addIceCandidate(e.candidate);
  b.onicecandidate = (e) => e.candidate && a.addIceCandidate(e.candidate);
  // Same channel shape as the audio lane: unreliable and unordered, so nothing
  // retransmits and one datagram lost is one message lost.
  const dc = a.createDataChannel('probe', { ordered: false, maxRetransmits: 0 });
  const opened = new Promise((res) => { dc.onopen = res; });
  // The receiving end, so the probe can count MESSAGES that survived rather
  // than infer it from datagram counts. Datagram counting was the original
  // method and it was wrong here: on a live call the proxy's histogram mixes
  // SRTP video, STUN, SACKs and three striped associations into one bucket, so
  // "full datagrams per full message" is not attributable to any one sender.
  // Message survival at a known link loss is: 1 datagram gives p, 2 gives
  // 1-(1-p)^2, and the two are 5.6% vs 10.9% — unmissable.
  window.__got = 0;
  b.ondatachannel = (e) => {
    e.channel.binaryType = 'arraybuffer';
    e.channel.onmessage = () => { window.__got++; };
  };
  await a.setLocalDescription(await a.createOffer());
  await b.setRemoteDescription(a.localDescription);
  await b.setLocalDescription(await b.createAnswer());
  await a.setRemoteDescription(b.localDescription);
  await Promise.race([opened, new Promise((_, rej) => setTimeout(() => rej(new Error('dc never opened')), 15000))]);
  window.__dc = dc;
  return { state: a.iceConnectionState, maxMessageSize: a.sctp?.maxMessageSize ?? null };
});
console.log(`datachannel open (ice ${ready.state}), sctp.maxMessageSize ${ready.maxMessageSize}`);
console.log(`\n${N} messages per size, through the same proxy the loss tests use.`);
console.log(LOSS > 0
  ? `link loss ${LOSS}% — a 1-datagram message loses ~${LOSS}%, a 2-datagram one ~${(100 * (1 - (1 - LOSS / 100) ** 2)).toFixed(1)}%.\n`
  : 'A message that fits one datagram adds N full packets and no tail.\n');
console.log('  size   full>=1100   mid600-1100   small120-600   tiny<120   bytes/msg   datagrams/msg   msgLoss%   maxBuf');

const snap = () => { const s = sim.stats; return { ...s.sizes, bytes: s.bytes, sent: s.sent }; };
let prev = snap();
const rows = [];
for (const size of SIZES) {
  const res = await p.evaluate(async ({ size, n, gap }) => {
    const before = window.__got;
    const buf = new Uint8Array(size);
    for (let i = 0; i < size; i++) buf[i] = (i * 31 + 7) & 0xff; // incompressible-ish, not that SCTP compresses
    // The pacing IS the experiment, and it took two wrong answers to get right.
    // 1250 msg/s measured 80% loss at every size: with maxRetransmits 0 and a
    // cwnd collapsed by 5% loss, SCTP abandons the queued burst before it
    // reaches the wire. 125 msg/s — the whole lane's rate — was still wrong,
    // and bufferedAmount climbing to 1.6 MB says why: a Reno-like AIMD carries
    // MSS×1.22/√p per RTT, which at p=0.05, MSS 1200, RTT 80 is ~0.65 Mbps, and
    // 125×1.2 KB is 1.2 Mbps. One association cannot hold the lane at all —
    // which is exactly why the app stripes over three (`?pcmpairs=3`). So the
    // faithful rate is ONE association's share: 125/3 ≈ 42 msg/s, 24 ms apart.
    // Drift corrected against a deadline, because setTimeout only rounds up.
    let maxBuf = 0;
    const t0 = performance.now();
    for (let i = 0; i < n; i++) {
      const due = t0 + i * gap;
      const wait = due - performance.now();
      if (wait > 1) await new Promise((r) => setTimeout(r, wait));
      window.__dc.send(buf);
      if (window.__dc.bufferedAmount > maxBuf) maxBuf = window.__dc.bufferedAmount;
    }
    await new Promise((r) => setTimeout(r, 800));
    return { got: window.__got - before, maxBuf };
  }, { size, n: N, gap: GAP });
  const got = res.got;
  await p.waitForTimeout(400);
  const cur = snap();
  const d = {
    full: cur.full - prev.full, mid: cur.mid - prev.mid,
    small: cur.small - prev.small, tiny: cur.tiny - prev.tiny,
    bytes: cur.bytes - prev.bytes, sent: cur.sent - prev.sent,
    lossPct: 100 * (1 - got / N),
    // A non-trivial peak here means the sender queued and the loss number is
    // backpressure, not the path. Printed so it can never be read as the latter.
    maxBuf: res.maxBuf,
  };
  prev = cur;
  rows.push({ size, ...d });
  console.log(`  ${String(size).padStart(4)}   ${String(d.full).padStart(10)}   ${String(d.mid).padStart(11)}` +
    `   ${String(d.small).padStart(12)}   ${String(d.tiny).padStart(8)}   ${String((d.bytes / N).toFixed(0)).padStart(9)}` +
    `   ${(d.sent / N).toFixed(2).padStart(13)}   ${d.lossPct.toFixed(1).padStart(8)}   ${String(d.maxBuf).padStart(7)}`);
}

// The threshold is the first size whose datagrams-per-message clears 2.2. The
// baseline is ~1.5, not 1.0, because SCTP SACKs ride the same path and land in
// the count; fragmenting doubles the data packets AND the SACKs, so the step is
// 1.5 -> 3.0 and anything above 2.2 is unambiguous. Reported as a budget rather
// than a boundary, because the useful form of this number is "you have X bytes".
// With a loss arm the datagram histogram is not the evidence — message survival
// is, and it is a direct observation rather than a ratio of mixed traffic.
if (LOSS > 0) {
  const one = LOSS, two = 100 * (1 - (1 - LOSS / 100) ** 2);
  const mid = (one + two) / 2;
  const frag = rows.filter((r) => r.lossPct > mid);
  const fits = rows.filter((r) => r.lossPct <= mid);
  console.log('');
  console.log(`expected: ${one.toFixed(1)}% for one datagram, ${two.toFixed(1)}% for two; the split is ${mid.toFixed(1)}%.`);
  console.log(`  fits one datagram: ${fits.map((r) => r.size).join(', ') || '(none)'}`);
  console.log(`  fragments:         ${frag.map((r) => r.size).join(', ') || '(none)'}`);
  const biggestFit = fits.length ? Math.max(...fits.map((r) => r.size)) : null;
  console.log(biggestFit === null
    ? '=> EVERY size fragments at this loss rate — the fragment point is not a fixed byte count.'
    : `=> single-datagram budget under ${LOSS}% loss is ${biggestFit} B or less.`);
  await ctx.close();
  await sim.stop?.();
  process.exit(0);
}
const over = rows.find((r) => r.sent / N > 2.2);
const under = [...rows].reverse().find((r) => r.sent / N <= 2.2 && r.size < (rows.find((x) => x.sent / N > 2.2)?.size ?? 1e9));
console.log('');
if (over && under) {
  console.log(`one datagram up to ${under.size} B, two from ${over.size} B.`);
  console.log(`=> usable single-datagram message budget is between ${under.size} and ${over.size - 1} bytes.`);
  console.log(`   the PCM frame is 1176 B (1152 payload + 24 header): ` +
    (1176 > under.size ? `OVER by ${1176 - under.size} B — it costs two datagrams, and 1-(1-p)^2 is the loss it pays.`
                       : `within budget.`));
} else {
  console.log('no clean threshold in the swept range — widen SIZES.');
}
await ctx.close();
await sim.stop?.();
