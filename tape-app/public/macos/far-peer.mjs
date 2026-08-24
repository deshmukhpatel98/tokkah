#!/usr/bin/env node
// Far end of a native Tokkah call, in ~200 lines of Node.
//
// Speaks just enough of the UDP protocol to be a peer: STUN, room rendezvous,
// time-sync replies. No camera, no CoreAudio, no second Mac. A Cloudflare
// container in another region runs this and this laptop's `tk` talks to it.
//
// RTT is measured on the Mac side (t4-t1 on its own clock). This process only
// echoes the probe with t2=t3, so the peer-turnaround term is zero and the
// Mac's number IS the round trip.
//
// CommonJS: the container saves this as join.js and runs `node join.js`.

const dgram = require('node:dgram');
const { randomBytes } = require('node:crypto');
const os = require('node:os');

const ROOM = process.env.ROOM || process.argv[2];
const BASE = process.env.BASE || 'https://room.tokkah.com';
const ME = process.env.ME || `far-${process.pid}`;
const REPORT = process.env.REPORT_URL || '';
if (!ROOM) {
  console.error('usage: ROOM=<code> node far-peer.mjs');
  process.exit(2);
}

const TMAGIC = 0x544b0005;
const HMAGIC = 0x544b0006;
const MAGIC  = 0x544b0001;

const sock = dgram.createSocket('udp4');
let mapped = null;          // {ip, port} from STUN
let localPort = 0;
let probes = 0, replies = 0, bytesIn = 0;
const froms = new Map();    // "ip:port" -> count

function u32le(buf, o) { return buf.readUInt32LE(o); }
function putU32le(buf, o, v) { buf.writeUInt32LE(v >>> 0, o); }
function putU64le(buf, o, v) { buf.writeBigUInt64LE(BigInt(v), o); }

async function post(o) {
  console.log(JSON.stringify({ t: Date.now(), ...o }));
  if (!REPORT) return;
  try {
    await fetch(REPORT, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(o),
    });
  } catch (e) {
    console.log('report-fail', String(e).slice(0, 80));
  }
}

function stunRequest() {
  const b = Buffer.alloc(20);
  b[1] = 0x01;                          // Binding Request
  b.writeUInt32BE(0x2112a442, 4);
  randomBytes(12).copy(b, 8);
  return b;
}

function parseStunMapped(msg) {
  if (msg.length < 20 || msg[0] !== 0x01 || msg[1] !== 0x01) return null;
  const cookie = 0x2112a442;
  let i = 20;
  const end = Math.min(msg.length, 20 + msg.readUInt16BE(2));
  while (i + 4 <= end) {
    const type = msg.readUInt16BE(i);
    const len = msg.readUInt16BE(i + 2);
    const v = i + 4;
    if ((type === 0x0020 || type === 0x0001) && len >= 8 && v + len <= msg.length && msg[v + 1] === 0x01) {
      const xor = type === 0x0020;
      let p = msg.readUInt16BE(v + 2);
      if (xor) p ^= (cookie >>> 16);
      const o = Buffer.alloc(4);
      for (let k = 0; k < 4; k++) {
        o[k] = xor ? (msg[v + 4 + k] ^ ((cookie >>> (8 * (3 - k))) & 0xff)) : msg[v + 4 + k];
      }
      return { ip: `${o[0]}.${o[1]}.${o[2]}.${o[3]}`, port: p };
    }
    i = v + len + ((4 - (len % 4)) % 4);
  }
  return null;
}

async function stun() {
  const req = stunRequest();
  const txid = Buffer.from(req.subarray(8, 20));
  return new Promise((resolve) => {
    const t = setTimeout(() => resolve(null), 1200);
    const onMsg = (msg) => {
      if (msg.length < 20) return;
      if (!msg.subarray(8, 20).equals(txid)) return;
      const m = parseStunMapped(msg);
      if (m) { clearTimeout(t); sock.off('message', onMsg); resolve(m); }
    };
    sock.on('message', onMsg);
    sock.send(req, 3478, 'stun.cloudflare.com');
  });
}

function localIPv4() {
  const ifs = os.networkInterfaces();
  let fallback = null;
  for (const [name, addrs] of Object.entries(ifs)) {
    for (const a of addrs || []) {
      const fam = a.family === 'IPv4' || a.family === 4;
      if (!fam || a.internal) continue;
      if (name.startsWith('en') || name.startsWith('eth') || name.startsWith('wlan')) return a.address;
      if (!fallback) fallback = a.address;
    }
  }
  return fallback;
}

async function rv() {
  const addr = mapped ? `${mapped.ip}:${mapped.port}` : '';
  const loc = localIPv4();
  const local = loc && localPort ? `${loc}:${localPort}` : '';
  let u = `${BASE}/api/room/${encodeURIComponent(ROOM)}/rv?me=${encodeURIComponent(ME)}`;
  if (addr) u += `&addr=${encodeURIComponent(addr)}`;
  if (local) u += `&local=${encodeURIComponent(local)}`;
  try {
    const j = await (await fetch(u)).json();
    return j.peers || [];
  } catch { return []; }
}

function punch(peers) {
  const out = Buffer.alloc(40);
  putU32le(out, 0, TMAGIC);
  putU32le(out, 4, 0);
  putU64le(out, 8, 0n);
  putU64le(out, 16, 0n);
  putU64le(out, 24, 0n);
  putU32le(out, 32, 0);
  putU32le(out, 36, 0);
  for (const p of peers) {
    for (const a of [p.addr, p.local, p.relay]) {
      if (!a || typeof a !== 'string') continue;
      const i = a.lastIndexOf(':');
      if (i < 0) continue;
      const ip = a.slice(0, i);
      const port = Number(a.slice(i + 1));
      if (!port) continue;
      sock.send(out, port, ip);
    }
  }
}

function onPacket(msg, rinfo) {
  if (msg.length < 8) return;
  bytesIn += msg.length;
  const key = `${rinfo.address}:${rinfo.port}`;
  froms.set(key, (froms.get(key) || 0) + 1);
  const magic = u32le(msg, 0);
  if (magic === TMAGIC && msg.length >= 32) {
    probes++;
    const kind = u32le(msg, 4);
    if (kind === 0) {
      const out = Buffer.alloc(40);
      putU32le(out, 0, TMAGIC);
      putU32le(out, 4, 1);                 // reply
      msg.copy(out, 8, 8, 16);             // echo t1
      putU64le(out, 16, 0n);               // t2 = t3 = 0 → Mac RTT is t4-t1
      putU64le(out, 24, 0n);
      putU32le(out, 32, 0);
      putU32le(out, 36, 0);
      sock.send(out, rinfo.port, rinfo.address);
      replies++;
    }
    return;
  }
  if (magic === HMAGIC) {
    // Do not complete the key exchange. Plaintext probes stay accepted on the
    // Mac until a key exists; we only need the clock packets.
    return;
  }
  if (magic === MAGIC) {
    // Presence. No need to play audio; the Mac's path race is on TMAGIC.
    return;
  }
}

async function geo() {
  try {
    const t = await (await fetch('https://www.cloudflare.com/cdn-cgi/trace')).text();
    const g = {};
    for (const l of t.split('\n')) {
      const i = l.indexOf('=');
      if (i > 0 && ['colo', 'loc', 'ip'].includes(l.slice(0, i))) g[l.slice(0, i)] = l.slice(i + 1);
    }
    return g;
  } catch (e) { return { err: String(e).slice(0, 80) }; }
}

sock.on('message', onPacket);
sock.bind(0, async () => {
  localPort = sock.address().port;
  const where = await geo();
  await post({ kind: 'start', room: ROOM, me: ME, localPort, geo: where });
  mapped = await stun();
  await post({ kind: 'stun', room: ROOM, mapped, localPort, geo: where });
  setInterval(async () => {
    const peers = await rv();
    punch(peers);
    await post({
      kind: 'tick', room: ROOM, me: ME, mapped, localPort,
      probes, replies, bytesIn, froms: Object.fromEntries(froms),
      peers: peers.map((p) => ({ id: p.id, addr: p.addr, local: p.local })),
    });
  }, 500);
  await rv();
});
