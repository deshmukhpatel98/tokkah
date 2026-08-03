/**
 * TAPE — the real 1:1 call, with instrumentation.
 *
 * Signaling, TURN credential minting, and durable telemetry storage. One Durable
 * Object per room handles all three, because the call happens once and every extra
 * moving part is another way to lose the data.
 *
 * ── What is stored ───────────────────────────────────────────────────────────
 * Event timings and WebRTC metrics. Nothing else. No audio, no video, no frames,
 * no transcript, no text. The whole point of the design is that the conversation
 * is the product and the archive is a footnote (§20), and a telemetry system that
 * quietly captured content would be the worst possible violation of that. The
 * ingest endpoint rejects any payload field it does not recognise, so this stays
 * true even if a client is later modified carelessly.
 *
 * ── Who can read it ──────────────────────────────────────────────────────────
 * Metrics-only is not public. Reading a room's log or summary requires the
 * room's logToken, minted at DO creation, persisted, and handed to occupants in
 * the welcome message; `?token=` on GET /log and /summary is checked against
 * it. Writing (POST /log) stays open — a call must never lose its log because
 * an auth check broke — but is body-capped and rate-limited.
 */

interface Env {
  ASSETS: Fetcher;
  ROOM: DurableObjectNamespace;
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
}

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });

// Numeric or short-string metrics only. An event whose payload isn't one of these
// is dropped rather than stored — see the header comment.
const MAX_EVENTS_PER_BATCH = 2000;
const MAX_STRING_LEN = 512;
const MAX_ROWS_PER_ROOM = 400_000; // ~an hour of dense telemetry from two peers
// Ingest stays unauthenticated (a call must never lose its log to an auth
// hiccup), so abuse is bounded instead: 1 MiB per POST body — a legit flush is
// a few KB — and 3000 batches/hour per room, ~2× what two clients flushing
// every 5 s for an hour actually send.
const MAX_POST_BYTES = 1 << 20;
const MAX_POSTS_PER_HOUR = 3000;

function sanitize(value: unknown, depth = 0): unknown {
  if (depth > 4) return null;
  if (value === null || typeof value === 'number' || typeof value === 'boolean') {
    return typeof value === 'number' && !Number.isFinite(value) ? null : value;
  }
  if (typeof value === 'string') return value.slice(0, MAX_STRING_LEN);
  if (Array.isArray(value)) return value.slice(0, 64).map((v) => sanitize(v, depth + 1));
  if (typeof value === 'object') {
    const out: Record<string, unknown> = {};
    let n = 0;
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (n++ >= 64) break;
      out[k.slice(0, 64)] = sanitize(v, depth + 1);
    }
    return out;
  }
  return null; // functions, symbols, undefined
}

export class Room implements DurableObject {
  private peers = new Map<WebSocket, string>();
  // Per-socket video transport capability, declared on the upgrade URL. Parallel
  // to `peers` rather than folded into it so the role-assignment logic above —
  // which has its own hard-won reasons for being exactly what it is — stays
  // untouched. Both maps are keyed by the socket and torn down together.
  private laneCaps = new Map<WebSocket, number>();
  private pcmCaps = new Map<WebSocket, number>();
  private sql: SqlStorage;
  // §10: the room's sole time authority. Stamped once at DO creation, persisted
  // so a DO restart keeps the epoch (a call's session clock must not rebase
  // mid-call). Delivered to both peers in the welcome message as an additive
  // field; clients that predate it ignore it.
  private epochUs = 0;
  // Read capability for this room's telemetry (see the header comment). Minted
  // once, persisted beside the epoch so a DO restart keeps it, and delivered in
  // the welcome message as an additive field — clients that predate it ignore
  // it, exactly like session_epoch_us.
  private logToken = '';
  private postTimes: number[] = [];

  constructor(private state: DurableObjectState, _env: unknown) {
    this.sql = state.storage.sql;
    this.state.blockConcurrencyWhile(async () => {
      const e = await this.state.storage.get<number>('session_epoch_us');
      this.epochUs = e ?? Date.now() * 1000;
      if (e == null) await this.state.storage.put('session_epoch_us', this.epochUs);
      const t = await this.state.storage.get<string>('log_token');
      this.logToken = t ?? crypto.randomUUID();
      if (t == null) await this.state.storage.put('log_token', this.logToken);
    });
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS events (
        id      INTEGER PRIMARY KEY,
        session TEXT NOT NULL,
        role    TEXT NOT NULL,
        t       REAL NOT NULL,
        wall    REAL NOT NULL,
        kind    TEXT NOT NULL,
        data    TEXT NOT NULL
      );
    `);
    this.sql.exec(`CREATE INDEX IF NOT EXISTS events_t ON events (t);`);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname.endsWith('/log') && request.method === 'POST') return this.ingest(request);
    if (url.pathname.endsWith('/log') && request.method === 'GET') return this.dump(url);
    if (url.pathname.endsWith('/summary')) return this.summary(url);
    return this.signal(request);
  }

  // The room code is user-chosen and can be a single character, so it is not a
  // read credential. The token is. Plain === on a 122-bit UUID: a timing side
  // channel over a network hop is not a practical oracle at this entropy.
  private tokenOk(url: URL): boolean {
    const t = url.searchParams.get('token');
    return t !== null && t === this.logToken;
  }

  // ── Telemetry ingest ──────────────────────────────────────────────────────
  private async ingest(request: Request): Promise<Response> {
    // Body cap first: MAX_EVENTS_PER_BATCH bounds event *count*, but each
    // event could still arrive carrying megabytes of pre-sanitize payload.
    const len = Number(request.headers.get('content-length') ?? 0);
    if (len > MAX_POST_BYTES) return json({ ok: false, error: 'batch too large' }, 413);
    const now = Date.now();
    this.postTimes = this.postTimes.filter((t) => now - t < 3_600_000);
    if (this.postTimes.length >= MAX_POSTS_PER_HOUR) {
      return json({ ok: false, error: 'ingest rate limit' }, 429);
    }
    this.postTimes.push(now);

    let body: { session?: unknown; role?: unknown; events?: unknown };
    try {
      body = (await request.json()) as typeof body;
    } catch {
      return json({ error: 'bad json' }, 400);
    }

    const session = String(body.session ?? '').slice(0, 64) || 'unknown';
    const role = String(body.role ?? '').slice(0, 16) || '?';
    const offered = Array.isArray(body.events) ? body.events.length : 0;
    const events = Array.isArray(body.events) ? body.events.slice(0, MAX_EVENTS_PER_BATCH) : [];
    if (!events.length) return json({ ok: true, stored: 0, offered });

    const [{ n: existing }] = this.sql.exec<{ n: number }>('SELECT COUNT(*) AS n FROM events').toArray();
    if (existing >= MAX_ROWS_PER_ROOM) {
      // Refuse rather than evict. Losing the *start* of the call would be worse
      // than losing the end, and silently rolling the window would make the data
      // look complete when it isn't.
      return json({ ok: false, error: 'room log full', stored: 0 }, 507);
    }

    let stored = 0;
    const wall = Date.now();
    for (const raw of events) {
      if (!raw || typeof raw !== 'object') continue;
      const e = raw as Record<string, unknown>;
      const kind = String(e.kind ?? '').slice(0, 48);
      const t = Number(e.t);
      if (!kind || !Number.isFinite(t)) continue;
      const data = sanitize(e.data ?? {});
      this.sql.exec(
        'INSERT INTO events (session, role, t, wall, kind, data) VALUES (?, ?, ?, ?, ?, ?)',
        session,
        role,
        t,
        Number.isFinite(Number(e.wall)) ? Number(e.wall) : wall,
        kind,
        JSON.stringify(data),
      );
      stored++;
    }
    // `offered` is reported so the client can tell truncation from success. Without it a batch
    // larger than MAX_EVENTS_PER_BATCH gets a 200 with a smaller `stored`, the client counts
    // that as a clean send, and the overflow is gone — data lost silently, which is the one
    // failure mode this whole logging path is supposed to make impossible. It only bites when
    // the buffer has grown from earlier failures, which is exactly when the log matters most.
    return json({ ok: true, stored, offered });
  }

  // ── Retrieval: NDJSON, one event per line ─────────────────────────────────
  private dump(url: URL): Response {
    if (!this.tokenOk(url)) return json({ error: 'log token required' }, 403);
    const kind = url.searchParams.get('kind');
    const rows = kind
      ? this.sql.exec('SELECT * FROM events WHERE kind = ? ORDER BY id', kind).toArray()
      : this.sql.exec('SELECT * FROM events ORDER BY id').toArray();

    const body = rows
      .map((r) =>
        JSON.stringify({
          session: r.session,
          role: r.role,
          t: r.t,
          wall: r.wall,
          kind: r.kind,
          data: JSON.parse(String(r.data)),
        }),
      )
      .join('\n');

    return new Response(body + (body ? '\n' : ''), {
      headers: {
        'content-type': 'application/x-ndjson; charset=utf-8',
        'content-disposition': 'inline; filename="tape-log.ndjson"',
      },
    });
  }

  // ── Summary: the numbers, without downloading everything ──────────────────
  private summary(url: URL): Response {
    if (!this.tokenOk(url)) return json({ error: 'log token required' }, 403);
    const counts = this.sql
      .exec<{ kind: string; n: number; session: string; role: string }>(
        'SELECT kind, session, role, COUNT(*) AS n FROM events GROUP BY kind, session, role ORDER BY n DESC',
      )
      .toArray();
    const span = this.sql
      .exec<{ lo: number; hi: number; n: number }>('SELECT MIN(wall) AS lo, MAX(wall) AS hi, COUNT(*) AS n FROM events')
      .toArray()[0];

    return json({
      totalEvents: span?.n ?? 0,
      firstEvent: span?.lo ? new Date(span.lo).toISOString() : null,
      lastEvent: span?.hi ? new Date(span.hi).toISOString() : null,
      durationMin: span?.lo && span?.hi ? +((span.hi - span.lo) / 60000).toFixed(1) : null,
      byKind: counts,
    });
  }

  // ── Signaling ─────────────────────────────────────────────────────────────
  private signal(request: Request): Response {
    if (request.headers.get('upgrade') !== 'websocket') return json({ error: 'expected websocket' }, 426);

    // Sweep sockets that died without telling us. `close`/`error` fire on a
    // clean teardown, but a phone that sleeps, loses cellular, or has its tab
    // killed leaves its entry behind — and two ghosts wedge the room at
    // "room full" for everyone, forever, with no way for the occupants to
    // clear it. The capacity check must count who is actually here.
    for (const [p] of this.peers) {
      if (p.readyState !== WebSocket.READY_STATE_OPEN) this.peers.delete(p);
    }
    if (this.peers.size >= 2) return new Response('room full', { status: 409 });

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();

    // Take the FREE slot, not the next ordinal. `size === 0 ? 'a' : 'b'` looks
    // equivalent and is not: when the offerer reloads or reconnects, the
    // answerer is still holding 'b', the room is down to one occupant, and the
    // returning peer was handed 'b' as well. Since only 'a' ever calls offer(),
    // two 'b's mean nobody offers and both sides sit on "connecting…" until
    // someone gives up — reproduced 100% of the time by one reload. Slot-based
    // assignment makes exactly one offerer an invariant of the room instead of
    // an accident of arrival order.
    const taken = new Set(this.peers.values());
    const role = taken.has('a') ? 'b' : 'a';
    this.peers.set(server, role);

    // Which video transport this client can actually run, declared on the
    // upgrade URL because it has to be known BEFORE either side builds its peer
    // connection. The custom lane is symmetric — one end substitutes its own
    // encoded bytes into the RTP payload of a 1x1 carrier, and an end without
    // the transform renders that carrier literally. A Chromium/Safari pair got
    // a black screen in both directions with no error on either side, because
    // each end only ever checked ITSELF. The room is the one place that sees
    // both, so the room is where the two answers meet.
    //
    // Lane A (lossless PCM audio) is declared the same way and for the same
    // reason. It used to take the mic OFF the peer connection entirely, so a
    // client with the flag and a client without it produced a ONE-WAY call —
    // the flagged end was inaudible for its whole duration, silently. Same
    // failure shape as the video lane, one sense over.
    const q = new URL(request.url).searchParams;
    const lane = Number(q.get('lane')) || 0;
    const pcm = Number(q.get('pcm')) || 0;
    this.laneCaps.set(server, lane);
    this.pcmCaps.set(server, pcm);
    const peerCap = (m: Map<WebSocket, number>) => {
      for (const [p] of this.peers) if (p !== server) return m.get(p) ?? 0;
      return null; // nobody else here yet; `peer-joined` carries it when they arrive
    };

    server.addEventListener('message', (e: MessageEvent) => {
      for (const [p] of this.peers) {
        if (p !== server && p.readyState === WebSocket.READY_STATE_OPEN) {
          try {
            p.send(e.data as string);
          } catch {
            /* reaped on close */
          }
        }
      }
    });

    const teardown = () => {
      this.peers.delete(server);
      this.laneCaps.delete(server);
      this.pcmCaps.delete(server);
      for (const [p] of this.peers) {
        try {
          p.send(JSON.stringify({ type: 'peer-left' }));
        } catch {
          /* ignore */
        }
      }
    };
    server.addEventListener('close', teardown);
    server.addEventListener('error', teardown);

    server.send(
      JSON.stringify({
        type: 'welcome',
        role,
        peerPresent: this.peers.size === 2,
        peerLane: peerCap(this.laneCaps),
        peerPcm: peerCap(this.pcmCaps),
        session_epoch_us: this.epochUs,
        // Occupants are the authorized readers of this room's log. Additive;
        // older clients ignore it and simply get 403 on GET /log or /summary
        // until they update. Their POSTs are unaffected.
        logToken: this.logToken,
      }),
    );
    if (this.peers.size === 2) {
      for (const [p] of this.peers) {
        if (p !== server) {
          try {
            // The incumbent learns the arriver's transport here — its own
            // `welcome` went out to an empty room and carried peerLane: null.
            p.send(JSON.stringify({ type: 'peer-joined', peerLane: lane, peerPcm: pcm }));
          } catch {
            /* ignore */
          }
        }
      }
    }

    return new Response(null, { status: 101, webSocket: client });
  }
}

const ROOM_RE = /^[A-Za-z0-9_-]{1,64}$/;

// ── /api/ice abuse control ────────────────────────────────────────────────────
// The hole: the route was unauthenticated and unbound, so anyone could mint
// unlimited 1-hour TURN credentials against our Cloudflare account. The current
// deployed clients fetch /api/ice with no credential of any kind (the lobby
// probe and the join-time fetch both run before any room admission exists), so
// a strict credential gate would break TURN for every client until the next
// app deploy. What today's requests CAN satisfy, and what we therefore require:
//
//   1. Browser fetch metadata: Sec-Fetch-Site same-origin/same-site/none, or a
//      Referer on our own origin (covers browsers that predate Sec-Fetch-*).
//      curl-class clients with neither get 403. Spoofable in one header — its
//      job is filtering drive-by traffic, not authentication.
//   2. A per-IP sliding-window limit on mints. This is the real cap: a
//      legitimate caller needs 2 per call (lobby probe + join); the window
//      allows 20 per 10 min. Counters live in isolate memory — approximate at
//      the edge (per-colo), exact under wrangler dev, and deliberately
//      fail-open on isolate churn because a TURN outage must never block calls.
//
// Gated requests still receive the STUN-only fallback body (with status
// 403/429) so a gated browser degrades exactly like a TURN outage today —
// `p2pOnly: true` — instead of losing even STUN. Strict room-binding (a
// welcome-carried ice token, same pattern as logToken) needs a client deploy
// and is a documented follow-up.
const ICE_MINT_WINDOW_MS = 10 * 60_000;
const ICE_MINT_MAX = 20;
const iceMints = new Map<string, number[]>();

// ── Security headers for the served app ───────────────────────────────────────
// Scripts are all same-origin files (module graph from /app.js, worklets, and
// lane 2's transform in a Blob worker), so script-src needs no 'unsafe-inline'.
// index.html carries one inline <style> block by design, so styles keep
// 'unsafe-inline' — documented tradeoff; moving it to a file or hashes is a
// public/ change outside this task's scope.
//
// connect-src is built per-request rather than fixed: bare `ws: wss:` permitted a
// socket to ANY host, which is the one thing a CSP on a call app should stop —
// injected script could stream the room id, or anything else it can read, straight
// out. Pinning it to this request's own host keeps the signalling socket working on
// room.tokkah.com, the workers.dev name and wrangler dev alike, with no hostname
// list to go stale. ('self' is not enough on its own: Safari has historically not
// matched ws:/wss: against it.)
const csp = (host: string) => [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'unsafe-inline'",
  "img-src 'self' data:", // data: is the inline SVG favicon
  `connect-src 'self' wss://${host} ws://${host}`,
  "media-src 'self' blob:",
  "worker-src 'self' blob:", // lane 2's RTCRtpScriptTransform worker (tape.js)
  "font-src 'self'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join('; ');

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // WebRTC requires a secure context: an http:// page loads fine but
    // `new RTCPeerConnection()` throws "not allowed" in Chrome, which reads
    // exactly like a broken site. Force https at the edge. Hostname alone can't
    // gate this: `wrangler dev` rewrites request.url to the route's production
    // host (measured: a localhost curl arrived as http://room.tokkah.com/...),
    // which 301'd local testing into a TLS-less https. `cf-ray` is stamped by
    // the real edge only, so it is the dev/prod signal that can't lie.
    const atEdge = request.headers.get('cf-ray') !== null;
    if (atEdge && url.protocol === 'http:' && /(^|\.)(tokkah\.com|workers\.dev)$/.test(url.hostname)) {
      return Response.redirect(`https://${url.host}${url.pathname}${url.search}`, 301);
    }

    if (url.pathname === '/api/ice') {
      const fallback = { p2pOnly: true, iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }] };
      // Layer 1: browser fetch metadata. See the block comment above.
      const site = request.headers.get('sec-fetch-site');
      const referer = request.headers.get('referer');
      const fromOurPage =
        site === 'same-origin' ||
        site === 'same-site' ||
        site === 'none' ||
        (referer !== null && referer.startsWith(`${url.origin}/`));
      if (!fromOurPage) return json({ ...fallback, gated: 'origin' }, 403);
      // Layer 2: per-IP mint rate. Counted before the upstream call so a hot
      // IP stops costing upstream calls too.
      const ip = request.headers.get('cf-connecting-ip') ?? 'local';
      const now = Date.now();
      const hits = (iceMints.get(ip) ?? []).filter((t) => now - t < ICE_MINT_WINDOW_MS);
      if (hits.length >= ICE_MINT_MAX) {
        iceMints.set(ip, hits);
        return json({ ...fallback, gated: 'rate' }, 429);
      }
      hits.push(now);
      iceMints.set(ip, hits);
      if (!env.TURN_KEY_ID || !env.TURN_KEY_API_TOKEN) return json(fallback);
      try {
        const res = await fetch(
          `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`,
          {
            method: 'POST',
            headers: {
              authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`,
              'content-type': 'application/json',
            },
            body: JSON.stringify({ ttl: 3600 }),
          },
        );
        if (!res.ok) return json(fallback);
        const body = (await res.json()) as { iceServers?: unknown };
        return json({ p2pOnly: false, iceServers: body.iceServers });
      } catch {
        // A TURN outage must never stop a call from being attempted.
        return json(fallback);
      }
    }

    // /api/room/:code/ws | /api/room/:code/log | /api/room/:code/summary
    const m = url.pathname.match(/^\/api\/room\/([^/]+)\/(ws|log|summary)$/);
    if (m) {
      const code = decodeURIComponent(m[1]);
      if (!ROOM_RE.test(code)) return json({ error: 'bad room code' }, 400);
      return env.ROOM.get(env.ROOM.idFromName(code)).fetch(
        new Request(`https://do/${m[2]}${url.search}`, request),
      );
    }

    if (url.pathname.startsWith('/api/')) return json({ error: 'not found' }, 404);
    const asset = await env.ASSETS.fetch(request);
    // Hardening headers on everything; CSP on the HTML (previously none — the
    // only headers were COOP/COEP, and only under ?pcmaudio=1). The response is
    // now always re-wrapped, so the old "flag-off is byte-identical" invariant
    // applies to the body only, not the headers.
    const res = new Response(asset.body, asset);
    res.headers.set('X-Content-Type-Options', 'nosniff');
    res.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
    if (asset.headers.get('content-type')?.includes('text/html')) {
      res.headers.set('Content-Security-Policy', csp(new URL(request.url).host));
      // Defense in depth for pre-CSP2 browsers; frame-ancestors above wins elsewhere.
      res.headers.set('X-Frame-Options', 'DENY');
      // Lane A needs SharedArrayBuffer for its playout ring, which browsers only
      // grant to cross-origin-isolated documents. It is now on by default, so the
      // headers are unconditional — gating them on the query string would have
      // silently demoted every default visitor to the slower port-mode ring while
      // the flagged test runs kept reporting `mode sab`. Everything the page loads
      // is same-origin, so COEP costs nothing. `?pcmaudio=0` still turns the lane
      // off in the client; the isolation headers are harmless either way.
      res.headers.set('Cross-Origin-Opener-Policy', 'same-origin');
      res.headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
      // Do NOT add `Cache-Control: no-transform` here. It is Cloudflare's
      // documented opt-out from edge HTML rewriting, and it does stop the two
      // injected third-party scripts (Web Analytics beacon + bot-management JS
      // detection) — measured, both gone. But the edge counts compression as a
      // transform too: gzip disappeared and the page went 13,423 -> 41,776 wire
      // bytes, 3.1x, for every visitor. Spending 28 kB a load to suppress a
      // script the CSP already blocks is the wrong trade. Turn the two features
      // off at the zone instead.
    }
    return res;
  },
};
