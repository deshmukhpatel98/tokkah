// First-mile measurement: real UDP round trip from this machine to a STUN
// server, by speaking actual STUN rather than inferring from TCP or HTTP.
//
// Why this number matters to the 150 ms budget: every media path starts by
// leaving the building. Whatever Delhi -> Cloudflare-edge costs is spent before
// the backbone carries a single byte, and it is spent again on the far side.
// A DO probe cannot see it (that measures edge -> DO, deliberately excluding
// the client link) and getStats cannot see it before a call exists.
//
// STUN is the right instrument because it is what WebRTC itself uses to find a
// path: same protocol, same UDP port, same servers, so the number is the one
// the call will actually pay rather than a TCP proxy for it.
//
// Usage: node testbed/stun-rtt.mjs [host:port] [n]
import dgram from 'node:dgram';
import crypto from 'node:crypto';

const target = process.argv[2] ?? 'stun.cloudflare.com:3478';
const N = Number(process.argv[3] ?? 20);
const [host, portStr] = target.split(':');
const port = Number(portStr ?? 3478);

const MAGIC = 0x2112a442;

function bindingRequest() {
  const buf = Buffer.alloc(20);
  buf.writeUInt16BE(0x0001, 0); // Binding Request
  buf.writeUInt16BE(0, 2); // no attributes
  buf.writeUInt32BE(MAGIC, 4);
  const tid = crypto.randomBytes(12);
  tid.copy(buf, 8);
  return { buf, tid: tid.toString('hex') };
}

// XOR-MAPPED-ADDRESS (0x0020): the server's view of us. Reported because a
// srflx address proves the packet really made the round trip through a NAT
// rather than being answered by something local.
function parseMapped(msg) {
  let off = 20;
  while (off + 4 <= msg.length) {
    const type = msg.readUInt16BE(off);
    const len = msg.readUInt16BE(off + 2);
    const val = msg.subarray(off + 4, off + 4 + len);
    if (type === 0x0020 && val.length >= 8) {
      const xport = val.readUInt16BE(2) ^ (MAGIC >>> 16);
      const raw = val.readUInt32BE(4) ^ MAGIC;
      const ip = [(raw >>> 24) & 255, (raw >>> 16) & 255, (raw >>> 8) & 255, raw & 255].join('.');
      return `${ip}:${xport}`;
    }
    off += 4 + len + ((4 - (len % 4)) % 4);
  }
  return null;
}

const sock = dgram.createSocket('udp4');
const pending = new Map();
const rtts = [];
let mapped = null;

sock.on('message', (msg) => {
  if (msg.length < 20 || msg.readUInt16BE(0) !== 0x0101) return;
  const tid = msg.subarray(8, 20).toString('hex');
  const sent = pending.get(tid);
  if (sent === undefined) return;
  pending.delete(tid);
  rtts.push(Number(process.hrtime.bigint() - sent) / 1e6);
  mapped ??= parseMapped(msg);
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const one = () => new Promise((resolve) => {
  const { buf, tid } = bindingRequest();
  pending.set(tid, process.hrtime.bigint());
  sock.send(buf, port, host, (err) => resolve(err ?? null));
});

for (let i = 0; i < N; i++) {
  await one();
  await sleep(120); // spaced so one queue does not colour the next sample
}
await sleep(700); // let stragglers land

sock.close();

if (rtts.length === 0) {
  console.log(`NO RESPONSE from ${target} — UDP blocked, or the host does not speak STUN`);
  process.exit(2);
}
rtts.sort((a, b) => a - b);
const pct = (p) => rtts[Math.min(rtts.length - 1, Math.floor((p / 100) * rtts.length))];
// The MINIMUM is the path; anything above it is queueing that happened to be
// in front of this packet. Same reasoning as the transport's decaying minima.
console.log(JSON.stringify({
  target,
  sent: N,
  recv: rtts.length,
  lossPct: +(100 * (1 - rtts.length / N)).toFixed(1),
  minMs: +rtts[0].toFixed(2),
  p50Ms: +pct(50).toFixed(2),
  p95Ms: +pct(95).toFixed(2),
  maxMs: +rtts[rtts.length - 1].toFixed(2),
  srflx: mapped ? mapped.replace(/^[\d.]+/, '(ip hidden)') : null,
}));
