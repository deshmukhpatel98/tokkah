// How far is each service's nearest edge, from here?
//
// The product's central latency claim is architectural: an SFU sends media
// A -> bridge -> B, so when A and B are near each other the detour is the whole
// cost, and it equals one round trip to the bridge. P2P pays ~0 for that hop.
// Right now that claim rests on ONE volunteer-run Jitsi in Munich (159.6 ms),
// which is the friendliest possible example. The giants run global edge
// networks and may be a few milliseconds away — in which case the detour is
// small and the claim is much weaker. That is the point of measuring.
//
// Method: TCP connect time to 443, which needs no account and no ICMP. The
// MINIMUM over many samples is the honest estimate — it is the one sample least
// contaminated by queueing, scheduling and retransmit.
//
// Known limit, stated up front: this is the service's *front door*, not
// necessarily the media server. It is a LOWER BOUND on the media RTT, since
// media cannot be closer than the nearest POP.
import { connect } from 'node:net';

const TARGETS = [
  ['Google Meet (front door)', 'meet.google.com', 443],
  ['Google (media edge probe)', 'stun.l.google.com', 443],
  ['Zoom', 'zoom.us', 443],
  ['Microsoft Teams', 'teams.microsoft.com', 443],
  ['Jitsi @ ffmuc (Munich)', 'meet.ffmuc.net', 443],
  ['Cloudflare (our signalling)', 'room.tokkah.com', 443],
];

const N = 12;

const once = (host, port) => new Promise((res) => {
  const t0 = process.hrtime.bigint();
  const s = connect({ host, port, timeout: 4000 });
  s.on('connect', () => { const d = Number(process.hrtime.bigint() - t0) / 1e6; s.destroy(); res(d); });
  s.on('timeout', () => { s.destroy(); res(null); });
  s.on('error', () => { s.destroy(); res(null); });
});

console.log(`\nTCP connect RTT to 443, ${N} samples each, from this machine\n`);
console.log('service                        min      p50    samples');
const out = [];
for (const [label, host, port] of TARGETS) {
  const xs = [];
  for (let i = 0; i < N; i++) {
    const d = await once(host, port);
    if (d != null) xs.push(d);
    await new Promise((r) => setTimeout(r, 120));
  }
  if (!xs.length) { console.log(`${label.padEnd(30)} unreachable`); continue; }
  xs.sort((a, b) => a - b);
  const min = xs[0], p50 = xs[Math.floor(xs.length / 2)];
  out.push([label, min]);
  console.log(`${label.padEnd(30)} ${min.toFixed(1).padStart(6)}  ${p50.toFixed(1).padStart(6)}   ${xs.length}/${N}`);
}

console.log(`
=== what this means for a SAME-CITY call ===
If two people are near each other, P2P media travels roughly directly between
them. An SFU sends it to the bridge and back, so the detour it adds is about one
full round trip to that bridge — the "min" column above.`);
for (const [label, min] of out) {
  console.log(`  ${label.padEnd(30)} adds ~${min.toFixed(0).padStart(3)} ms of detour a same-city P2P call does not pay`);
}
