// Is the PUBLIC INTERNET 1.25x the speed of light, or 2x?
//
// This is the last unknown in the 150 ms budget. Cloudflare's backbone measures
// 1.20-1.29x (see LATENCY-150.md), and if a real call routes that well then the
// goal is already met on shipped code. If ordinary internet routing between two
// consumer networks is 2x instead, Delhi->San Jose lands near 180 ms and fails.
//
// Instrument: TCP connect time to REGION-PINNED cloud endpoints. AWS regional
// hostnames resolve to that region's own address space rather than anycast, so
// the round trip really did cross the ocean — unlike a STUN or CDN probe, which
// answers from the nearest edge and measures nothing but the local ISP.
//
// TCP handshake rather than ICMP: routers deprioritise or drop ICMP, and TCP is
// what the path actually carries. The SYN->SYNACK round trip is one RTT with no
// application work behind it, which is as close to raw path cost as userland
// gets without raw sockets.
//
// Usage: node testbed/route-efficiency.mjs [samples]
import net from 'node:net';

const N = Number(process.argv[2] ?? 7);
const C_FIBER = 199_862; // km/s — c / 1.468 for standard SMF-28
const HERE = { name: 'Delhi', lat: 28.61, lon: 77.21 };

// Region endpoints with their real datacentre locations. AWS publishes where
// each region physically is; these are the coordinates of the region, not of a
// CDN edge.
const TARGETS = [
  { host: 'ec2.ap-southeast-1.amazonaws.com', port: 443, site: 'Singapore', lat: 1.35, lon: 103.82 },
  { host: 'ec2.eu-west-2.amazonaws.com', port: 443, site: 'London', lat: 51.51, lon: -0.13 },
  { host: 'ec2.ap-southeast-2.amazonaws.com', port: 443, site: 'Sydney', lat: -33.87, lon: 151.21 },
  { host: 'ec2.us-east-1.amazonaws.com', port: 443, site: 'N. Virginia', lat: 39.04, lon: -77.49 },
  { host: 'ec2.us-west-2.amazonaws.com', port: 443, site: 'Oregon', lat: 45.84, lon: -119.7 },
  { host: 'ec2.us-west-1.amazonaws.com', port: 443, site: 'N. California', lat: 37.34, lon: -121.89 },
  { host: 'ec2.sa-east-1.amazonaws.com', port: 443, site: 'Sao Paulo', lat: -23.55, lon: -46.63 },
  { host: 'ec2.ap-northeast-1.amazonaws.com', port: 443, site: 'Tokyo', lat: 35.68, lon: 139.65 },
];

const gc = (a, b) => {
  const R = 6371, r = Math.PI / 180;
  const dp = (b.lat - a.lat) * r, dl = (b.lon - a.lon) * r;
  const h = Math.sin(dp / 2) ** 2
    + Math.cos(a.lat * r) * Math.cos(b.lat * r) * Math.sin(dl / 2) ** 2;
  return R * 2 * Math.asin(Math.sqrt(h));
};

const connectOnce = (host, port) => new Promise((resolve) => {
  const t0 = process.hrtime.bigint();
  const s = new net.Socket();
  let done = false;
  const finish = (v) => { if (!done) { done = true; s.destroy(); resolve(v); } };
  s.setTimeout(5000);
  s.once('connect', () => finish(Number(process.hrtime.bigint() - t0) / 1e6));
  s.once('timeout', () => finish(null));
  s.once('error', () => finish(null));
  s.connect(port, host);
});

const rows = [];
for (const t of TARGETS) {
  const km = gc(HERE, t);
  const samples = [];
  for (let i = 0; i < N; i++) {
    const ms = await connectOnce(t.host, t.port);
    if (ms != null) samples.push(ms);
    await new Promise((r) => setTimeout(r, 150));
  }
  if (samples.length === 0) { rows.push({ site: t.site, km, min: null }); continue; }
  samples.sort((a, b) => a - b);
  // MINIMUM, not mean: the floor is the path, everything above it is queueing.
  const min = samples[0];
  const idealRtt = (2 * km * 1.25) / C_FIBER * 1000; // 1.25x = a good fibre route
  const straight = (2 * km) / C_FIBER * 1000; // no routing detour at all
  rows.push({ site: t.site, km, min, idealRtt, straight, ratio: min / straight, n: samples.length });
}

console.log(`from ${HERE.name}  (min of ${N} TCP handshakes; minimum = the path, not the queue)\n`);
console.log(`${'site'.padEnd(14)}${'km'.padStart(7)}${'straight'.padStart(10)}${'@1.25x'.padStart(9)}${'measured'.padStart(10)}${'vs light'.padStart(10)}`);
console.log('-'.repeat(60));
for (const r of rows) {
  if (r.min == null) { console.log(`${r.site.padEnd(14)}${String(Math.round(r.km)).padStart(7)}${'(no answer)'.padStart(39)}`); continue; }
  console.log(
    `${r.site.padEnd(14)}${String(Math.round(r.km)).padStart(7)}`
    + `${r.straight.toFixed(1).padStart(10)}${r.idealRtt.toFixed(1).padStart(9)}`
    + `${r.min.toFixed(1).padStart(10)}${(r.ratio.toFixed(2) + 'x').padStart(10)}`,
  );
}
const ok = rows.filter((r) => r.min != null);
if (ok.length) {
  const med = ok.map((r) => r.ratio).sort((a, b) => a - b)[Math.floor(ok.length / 2)];
  console.log(`\nMEDIAN public-internet routing: ${med.toFixed(2)}x the speed of light in fibre`);
  console.log(`Cloudflare backbone, same yardstick: 1.20-1.29x`);
  console.log(med <= 1.45
    ? 'VERDICT: public routing is efficient — P2P should make the budget.'
    : 'VERDICT: public routing is LOSSY — hypothesis #1 (relay over backbone) matters.');
}
