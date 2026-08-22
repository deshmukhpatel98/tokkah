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
  // Native macOS app releases. The bucket holds only build artifacts; the
  // page, installer and signed manifest are ordinary static assets.
  MACREL?: R2Bucket;
  ROOM: DurableObjectNamespace;
  HEALTH: DurableObjectNamespace;
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
  // Interpreter (TRANSLATE-SPEC.md). Keys live here so the browser never sees
  // them; with neither key /xlate answers 503 and the client shows nothing.
  // GEMINI_API_KEY present → Gemini 3.5 Live Translate is the default vendor
  // (one speech-to-speech session replaces the STT→MT→TTS chain). The legacy
  // ElevenLabs pipeline stays reachable via ?xlvendor=el for A/Bs.
  // Live-laboratory channel (POST /api/room/:code/lab). UNSET = the endpoint
  // answers 503 and no call can be reached from outside. Setting it is the
  // deliberate act that opens the door, so a fresh deploy is closed by default.
  LAB_KEY?: string;
  GEMINI_API_KEY?: string;
  // Interpreter daily budget per room, in seconds (see xlateMeter). Unset =
  // 7200; explicit '0' disables metering.
  XLATE_DAY_SECONDS?: string;
  LOG_ADMIN_TOKEN?: string;
  ELEVENLABS_API_KEY?: string;
  // MT backend. Absent → passthrough (captions/TTS in the source language),
  // which keeps the whole pipeline measurable before the key exists.
  ANTHROPIC_API_KEY?: string;
}

// §7.1: server-side master switch. Off → cap is constant 2 and the DO is
// byte-identical to today, including the pre-open 409 at two occupants,
// hold-socket semantics, ghost eviction, role slot reuse, and opaque relay.
const THREE_ENABLED = false;

const ROLES = ['a', 'b', 'c'] as const;

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });

// Numeric or short-string metrics only. An event whose payload isn't one of these
// is dropped rather than stored — see the header comment.
const MAX_EVENTS_PER_BATCH = 2000;
const MAX_STRING_LEN = 512;
// How long a departure is held before the peer is told. Long enough for a tab
// to notice its socket died, re-open one (TCP + TLS + WS upgrade, ~3 round
// trips — 1.2 s at a 400 ms RTT) and send `join`; short enough that a genuine
// exit is not stale on screen. See `teardown`.
const LEAVE_GRACE_MS = 5000;
// Kilometres between occupants past which relaying is expected to beat going
// direct. From the eight-region model in LATENCY-150.md, relay wins on every
// route measured — including Singapore at ~4,300 km from Delhi (76.3 ms relayed
// vs 80.8 ms direct) — so the crossover is somewhere below that, and 2500 is a
// deliberately conservative first cut for a signal that is only being REPORTED.
// The number to move once phase 1 has real data behind it.
const RELAY_KM = 2500;
// Keys kept per object. Was 64, which silently truncated the audio lane's own
// snapshot: `pcm.snapshot()` spreads the transport counters first and appends
// the playout half after them, so every field past the 64th was dropped on
// ingest — `started`, `playedFrames`, `concealedMs`, `heldMs`, `depthMs`,
// `targetFrames`, `outputLatencyMs`, `driftPpm`, `ageP50`, and `mouthToEarMs`,
// which is the single number the entire latency campaign exists to move.
//
// Nothing failed. The page had every field (that is why the harness prints
// mouth-to-ear and why the stall detector works); only the UPLOADED copy was
// short, so live-call diagnosis was blind to the whole playout side and had to
// infer concealment from `stall-hold` events. Found 2026-08-14 while chasing
// "connection paused — reconnecting" on a real Delhi <-> Netherlands call.
//
// The cap still exists — this is an unauthenticated POST endpoint and an
// unbounded object is an abuse surface — but it is now above any real payload,
// and truncation is RECORDED rather than silent (see `_truncKeys` below).
const MAX_KEYS_PER_OBJECT = 192;
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
    const entries = Object.entries(value as Record<string, unknown>);
    let n = 0;
    for (const [k, v] of entries) {
      if (n++ >= MAX_KEYS_PER_OBJECT) break;
      out[k.slice(0, 64)] = sanitize(v, depth + 1);
    }
    // Say so, in the row itself. A cap that drops fields without a trace reads
    // downstream as "the client never sent them", which is how the audio lane's
    // playout half stayed missing from every query for a whole campaign.
    if (entries.length > MAX_KEYS_PER_OBJECT) out._truncKeys = entries.length - MAX_KEYS_PER_OBJECT;
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
  // The lossless lane's FRAME SHAPE, relayed so the two ends can agree on it.
  // pcmCaps says whether a peer wants the lane; nothing said what shape its
  // frames are, so a shape change would have been mis-parsed silently at both
  // ends with no field to detect it. Parallel to pcmCaps in every respect,
  // including teardown. Additive: peers that never send it read as undefined,
  // which the client treats as "before this existed" rather than a mismatch.
  private pcmFrameCaps = new Map<WebSocket, number>();
  private sids = new Map<WebSocket, string>();
  // Approximate client coordinates from `request.cf`, used only to compute how
  // far apart the two occupants are. City-level and often absent — never stored,
  // never logged, never sent to the other peer. What LEAVES this map is one
  // number (kilometres) and one boolean, because the only question being asked
  // is "is this a long path?", and that is not a location.
  private geo = new Map<WebSocket, { lat: number; lon: number }>();
  // What occupants said back to a lab frame. Bounded and drained on read — a
  // buffer nobody empties is a memory leak with a nice name.
  private labReplies: unknown[] = [];
  // Wire version per socket — the admission gate of §3.4. v=1 (default, old
  // clients) anywhere in the room caps it at 2; v≥2 everywhere + THREE_ENABLED
  // lifts it to 3. Parallel to laneCaps/pcmCaps, torn down in the same places.
  private vers = new Map<WebSocket, number>();
  private held = new Set<WebSocket>();
  private heldTimers = new Map<WebSocket, ReturnType<typeof setTimeout>>();
  // A departure that has not been announced yet, keyed by the tab's session id.
  // See LEAVE_GRACE_MS and `teardown` — a signaling socket that dies and comes
  // straight back is a blip, not a departure, and the peer should never learn
  // about it.
  private pendingLeaves = new Map<string, ReturnType<typeof setTimeout>>();
  private roomCode = '';
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
  // #62 GHOST EVICTION BY SILENCE. Every current client pings this socket every
  // 25 s (the keepalive above the relay listener). A socket whose transport died
  // WITHOUT a close frame — VPN path change, NAT rebind, sleep — keeps
  // readyState OPEN here indefinitely, occupies a slot, and turns every rejoin
  // into `full`: measured live 2026-08-19, one browser held "connecting…"
  // through 5 room-full rejections while the room showed a single live peer.
  // Stamped on every inbound message; swept ONLY when a join would otherwise be
  // refused, so a legacy client that never pings can lose its slot only to a
  // person who is actually at the door, never to a timer.
  private lastSeen = new Map<WebSocket, number>();
  private postTimes: number[] = [];
  // Interpreter sessions, keyed by signaling role. Parallel to `peers` like the
  // cap maps: the translation socket is a sibling of the call, never a part of it.
  private xl = new Map<string, {
    sock: WebSocket; lang: string; up: WebSocket | null; ttsBusy: Promise<void>; seg: number;
    // Gemini-vendor extras (absent on ElevenLabs sessions). `target` is the
    // language the upstream session was OPENED with — the peer's listening
    // language — so a peer arriving with a different lang can retire it.
    vendor?: string; target?: string;
  }>();

  constructor(private state: DurableObjectState, private env: Env) {
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
    if (url.pathname.endsWith('/warm')) return this.warm();
    if (url.pathname.endsWith('/xlate')) return this.xlate(request);
    if (url.pathname.endsWith('/lab') && request.method === 'POST') return this.lab(request);
    if (url.pathname.endsWith('/rv')) return this.rendezvous(url);
    return this.signal(request);
  }

  /**
   * RENDEZVOUS for the native app: two Macs swap the public UDP addresses they
   * each learned from STUN, then both start sending, which punches the holes.
   *
   * A pure address exchange and nothing else. No media, no keys, no session — the
   * only thing that cannot be discovered without help is what the other side's
   * NAT called it, and this answers exactly that. Deliberately unauthenticated
   * like the web app's room codes: knowing a room code has always been the
   * credential here, and an address is not a secret worth more than the media it
   * carries (which is the next thing to encrypt, and is not encrypted yet).
   *
   * Held in memory with a short lease rather than in storage. An address is only
   * true while the NAT binding behind it is alive, so persisting one would mean
   * handing out mappings that expired hours ago — worse than handing out nothing,
   * because the caller would spend its whole punch budget on a dead address.
   */
  private rvPeers = new Map<string, { addr: string; local?: string; at: number }>();

  private rendezvous(url: URL): Response {
    const me = url.searchParams.get('me') ?? '';
    const addr = url.searchParams.get('addr') ?? '';
    const now = Date.now();
    // 90 s: long enough to survive a slow start on the far side, short enough
    // that a stale mapping is never offered as a live one.
    for (const [k, v] of this.rvPeers) if (now - v.at > 90_000) this.rvPeers.delete(k);
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(me)) return json({ error: 'bad me' }, 400);
    const local = url.searchParams.get('local') ?? '';
    const addrOk = (a: string) => /^\d{1,3}(\.\d{1,3}){3}:\d{1,5}$/.test(a);
    if (addr) {
      if (!addrOk(addr)) return json({ error: 'bad addr' }, 400);
      if (local && !addrOk(local)) return json({ error: 'bad local' }, 400);
      // The LAN address travels too. Two machines behind one NAT should talk over
      // the LAN: it is a shorter path, and reaching your own public address from
      // inside requires NAT hairpinning that many routers refuse outright. The
      // client compares public IPs and picks; this only carries both.
      this.rvPeers.set(me, { addr, local: local || undefined, at: now });
    }
    const others = [...this.rvPeers.entries()]
      .filter(([k]) => k !== me)
      .map(([k, v]) => ({ id: k, addr: v.addr, local: v.local, ageMs: now - v.at }));
    return json({ me, peers: others });
  }

  /**
   * THE LIVE LABORATORY CHANNEL — reach into a call that is already running.
   *
   * The instrument this project has been missing. Every measurement so far has
   * been "start a call, measure, tear it down, change one thing, start another
   * call" — which means every comparison carries the difference between two
   * networks, two CPU states and two ICE negotiations, and today that noise
   * invalidated three consecutive runs outright. A knob pushed into a call that
   * is ALREADY UP compares the path against itself, seconds apart. That is a
   * different class of evidence, and it is the only way to A/B a route between
   * two continents without the route changing underneath the experiment.
   *
   * Authorisation is the whole risk. This endpoint mutates a live call between
   * two real people, so:
   *   · it is DISABLED unless LAB_KEY is configured — an unset secret is a
   *     closed door, never an open one;
   *   · the key is compared at full length (a room code is not a credential,
   *     the same reasoning as tokenOk above);
   *   · it can only ever RELAY. It sets nothing itself and knows nothing about
   *     what the fields mean, so the blast radius is exactly what a client
   *     chooses to honour, and the client honours nothing outside a fixed list.
   */
  private async lab(request: Request): Promise<Response> {
    const key = this.env.LAB_KEY;
    if (!key) return json({ error: 'lab channel not configured' }, 503);
    const given = request.headers.get('x-lab-key') ?? '';
    if (given.length !== key.length || given !== key) return json({ error: 'forbidden' }, 403);
    let body: Record<string, unknown>;
    try { body = (await request.json()) as Record<string, unknown>; } catch { return json({ error: 'bad json' }, 400); }
    // `drain` is answered by the room itself rather than relayed: it collects
    // what the occupants said back. Replies return THIS way, over the same
    // key-gated channel, rather than through the telemetry log — reading that
    // would have meant rotating LOG_ADMIN_TOKEN to a value I know, and rotating
    // a live secret to read a debug field is a bad trade.
    if (body.op === 'drain') {
      const out = this.labReplies;
      this.labReplies = [];
      return json({ replies: out, peers: [...this.peers.values()] });
    }
    // `type` is ours to stamp; a caller cannot forge another message kind and
    // ride this endpoint into the signaling chain.
    const frame = JSON.stringify({ ...body, type: 'lab' });
    let sent = 0;
    const only = typeof body.only === 'string' ? body.only : null;
    for (const [ws, role] of this.peers) {
      if (only && role !== only) continue;
      try { ws.send(frame); sent++; } catch { /* closing socket */ }
    }
    return json({ sent, peers: [...this.peers.values()] });
  }

  // The room code is user-chosen and can be a single character, so it is not a
  // read credential. The token is. Plain === on a 122-bit UUID: a timing side
  // channel over a network hop is not a practical oracle at this entropy.
  private tokenOk(url: URL): boolean {
    const t = url.searchParams.get('token');
    // LOG_ADMIN_TOKEN (wrangler secret): operator read across rooms, for
    // debugging live complaints without asking the caller for their token.
    if (t !== null && this.env.LOG_ADMIN_TOKEN && t === this.env.LOG_ADMIN_TOKEN) return true;
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
      // ROTATE rather than refuse. "Refuse rather than evict" was right for a
      // one-call room and wrong for a standing one: this room crossed the cap
      // at 22:06 on 2026-08-19 and every event after — joins, negotiations,
      // rescues — was silently 507'd for two hours while the operator debugged
      // against a log that looked merely quiet (blind-instruments class). The
      // original worry ("rolling silently makes the data look complete") is
      // answered head-on: each rotation writes a `log-rotated` marker row
      // stating exactly how many rows were dropped, so a reader can see the
      // cut. Oldest 20% goes — the tail is where the live questions are.
      const cut = Math.floor(MAX_ROWS_PER_ROOM * 0.2);
      this.sql.exec(
        'DELETE FROM events WHERE id IN (SELECT id FROM events ORDER BY id LIMIT ?)', cut,
      );
      this.sql.exec(
        'INSERT INTO events (session, role, t, wall, kind, data) VALUES (?, ?, ?, ?, ?, ?)',
        'room', 'op', 0, Date.now(), 'log-rotated', JSON.stringify({ dropped: cut, capRows: MAX_ROWS_PER_ROOM }),
      );
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

  // ── Prewarm: pay the cold start before the human clicks ───────────────────
  // The lobby calls this while the preview is still on screen (app.js
  // prewarmRoom). Its only job is to EXIST: reaching the DO at all runs the
  // constructor, its blockConcurrencyWhile storage reads (epoch + log token)
  // and the schema exec, which is the ~0.8 s the first joiner used to pay.
  //
  // It used to be a tokenless GET /summary — which warmed the DO perfectly and
  // then answered 403, putting a failed request in every visitor's console on
  // every single load, forever. That is not free. Standing noise is precisely
  // what the next real error hides behind, and this one was also inflating the
  // testbed's own "console error(s)" / "failed request(s)" pass signal, i.e.
  // corrupting the instrument used to decide whether a build is good. 204 warms
  // exactly the same and says nothing.
  private warm(): Response {
    // COUNT(*) rather than SELECT 1 so the events table's pages are faulted in
    // too — the same storage touch /summary was doing, minus the answer.
    this.sql.exec('SELECT COUNT(*) FROM events');
    // 200 with a body, NOT 204. Measured: a 204 here still showed up as
    // `failed …/warm — net::ERR_ABORTED` in Playwright's requestfailed, i.e.
    // it swapped a red console line for a red harness line and fixed nothing.
    // Chromium reports the abort when a response body is never drained, and an
    // empty body is the easiest one to leave hanging. A small real body that
    // the caller reads to completion (see prewarmRoom in app.js) closes the
    // stream cleanly and nothing anywhere logs it.
    return json({ warm: true });
  }

  // ── Signaling ─────────────────────────────────────────────────────────────

  // §3.4: effective room cap. With the flag off, constant 2 — the entire
  // feature is inert. With it on, every occupant AND the arriving socket
  // must be v≥2 for the cap to lift to 3; a single v1 anywhere drops it
  // back so a third socket is never admitted alongside a client that cannot
  // address messages.
  private cap(vArriving: number): number {
    if (!THREE_ENABLED) return 2;
    if (vArriving < 2) return 2;
    for (const v of this.vers.values()) {
      if (v < 2) return 2;
    }
    return 3;
  }

  /**
   * Remember roughly where a socket connected from, for one purpose: deciding
   * whether the two occupants are far enough apart that relaying beats going
   * direct. Cloudflare's `cf.latitude/longitude` are city-level and frequently
   * absent, which is fine — absent means "no opinion", and no opinion means
   * today's behaviour.
   */
  private noteGeo(server: WebSocket, request: Request): void {
    const lat = Number((request.cf as Record<string, unknown> | undefined)?.latitude);
    const lon = Number((request.cf as Record<string, unknown> | undefined)?.longitude);
    if (Number.isFinite(lat) && Number.isFinite(lon)) this.geo.set(server, { lat, lon });
  }

  /**
   * How far apart the two occupants are, in kilometres, or null when either
   * side did not report a position. Great-circle: the relevant question is
   * whether the media has an ocean to cross, and a few percent of error in the
   * answer cannot change that.
   *
   * WHY THE ROOM ANSWERS THIS AND NOT THE CLIENT: the choice between relay and
   * direct has to be made BEFORE the peer connection is built, and at that
   * moment neither client knows anything about the other's location. The room
   * is the only party that has seen both. It also keeps the policy in one place
   * — tunable without shipping a client.
   *
   * The stakes, from LATENCY-150.md: Cloudflare's backbone runs 1.20-1.29x the
   * speed of light in fibre while the public internet from India runs 2.14x, so
   * on a long path the relay is the SHORT way. Modelled over eight regions,
   * relaying wins on all eight — direct P2P clears 150 ms on four of them,
   * relaying on all eight (N. California 171.2 ms direct vs 128.0 ms relayed).
   * ICE cannot discover this on its own: RFC 8445 ranks host and srflx above
   * relay BY TYPE, so the stack picks the slow road precisely when the fast one
   * matters most.
   */
  private kmApart(server: WebSocket): number | null {
    const mine = this.geo.get(server);
    if (!mine) return null;
    for (const [p] of this.peers) {
      if (p === server) continue;
      const theirs = this.geo.get(p);
      if (!theirs) continue;
      const R = 6371;
      const rad = (d: number) => (d * Math.PI) / 180;
      const dLat = rad(theirs.lat - mine.lat), dLon = rad(theirs.lon - mine.lon);
      const a = Math.sin(dLat / 2) ** 2
        + Math.cos(rad(mine.lat)) * Math.cos(rad(theirs.lat)) * Math.sin(dLon / 2) ** 2;
      return Math.round(2 * R * Math.asin(Math.min(1, Math.sqrt(a))));
    }
    return null;
  }

  // Shared admission gate: sweep dead sockets, evict a ghost with the same
  // session id, and report whether the room is already full. Both the upgrade
  // path and the hold-join path call this so the logic is in one place.
  private evictAndCheckFull(sid: string | null, v: number): boolean {
    for (const [p] of this.peers) {
      if (p.readyState !== WebSocket.READY_STATE_OPEN) this.peers.delete(p);
    }
    if (sid) {
      for (const [p] of this.peers) {
        if (this.sids.get(p) === sid) {
          try { p.close(1000, 'replaced by same tab'); } catch { /* already dead */ }
          this.peers.delete(p);
          this.laneCaps.delete(p);
          this.pcmCaps.delete(p);
          this.pcmFrameCaps.delete(p);
          this.sids.delete(p);
          this.geo.delete(p);
          this.vers.delete(p);
        }
      }
    }
    if (this.peers.size < this.cap(v)) return false;
    // Full — before refusing, evict occupants that have been silent past two
    // keepalive intervals plus margin. READY_STATE_OPEN is a claim about this
    // end; silence is evidence about the other. 60 s of it with a live person
    // waiting outside decides the slot.
    const GHOST_MS = 60_000;
    const cut = Date.now() - GHOST_MS;
    for (const [p] of this.peers) {
      const seen = this.lastSeen.get(p) ?? 0;
      if (seen < cut) {
        try { p.close(1000, 'evicted: silent past keepalive'); } catch { /* dead */ }
        this.peers.delete(p);
        this.laneCaps.delete(p);
        this.pcmCaps.delete(p);
        this.pcmFrameCaps.delete(p);
        this.sids.delete(p);
        this.geo.delete(p);
        this.vers.delete(p);
        this.lastSeen.delete(p);
      }
    }
    return this.peers.size >= this.cap(v);
  }

  // The admission logic: role assignment, cap registration, relay listener,
  // teardown wiring, welcome message, and peer-joined broadcast. Extracted so
  // the upgrade path and the hold-join path share it.
  private admit(server: WebSocket, opts: { lane: number; pcm: number; pcmFrame?: number; sid: string | null; v: number; full: () => void }): void {
    if (this.peers.size >= this.cap(opts.v)) { opts.full(); return; }

    // This tab is back inside the grace window — cancel its unsent departure so
    // the peer never learns it was gone. See `teardown` for why that matters.
    // Deliberately BEFORE the role assignment below, because a cancelled leave
    // and a fresh arrival must not race for the same slot.
    if (opts.sid) {
      const pend = this.pendingLeaves.get(opts.sid);
      if (pend !== undefined) {
        clearTimeout(pend);
        this.pendingLeaves.delete(opts.sid);
      }
    }

    // Take the FREE slot, not the next ordinal. `size === 0 ? 'a' : 'b'` looks
    // equivalent and is not: when the offerer reloads or reconnects, the
    // answerer is still holding 'b', the room is down to one occupant, and the
    // returning peer was handed 'b' as well. Since only 'a' ever calls offer(),
    // two 'b's mean nobody offers and both sides sit on "connecting…" until
    // someone gives up — reproduced 100% of the time by one reload. Slot-based
    // assignment makes exactly one offerer an invariant of the room instead of
    // an accident of arrival order. With the pair-ordering law of §3.1, free-
    // slot reuse is still what makes "exactly one offerer per pair" a property
    // of the room rather than an accident of arrival order.
    const taken = new Set(this.peers.values());
    const role = ROLES.find((r) => !taken.has(r)) ?? 'a';
    this.peers.set(server, role);
    this.lastSeen.set(server, Date.now());

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
    const { lane, pcm, pcmFrame, sid, v } = opts;
    this.laneCaps.set(server, lane);
    this.pcmCaps.set(server, pcm);
    if (pcmFrame != null) this.pcmFrameCaps.set(server, pcmFrame);
    if (sid) this.sids.set(server, sid);
    this.vers.set(server, v);
    const peerCap = (m: Map<WebSocket, number>) => {
      for (const [p] of this.peers) if (p !== server) return m.get(p) ?? 0;
      return null; // nobody else here yet; `peer-joined` carries it when they arrive
    };
    // ── #75 "UNKNOWN" AND "ZERO" ARE NOT THE SAME ANSWER ────────────────────
    // peerCap's `?? 0` is right for laneCaps and pcmCaps, where 0 is a real
    // value meaning "does not want the lane". It is WRONG for pcmFrameCaps,
    // where 0 is not a frame length any client can have: it can only mean the
    // occupant has not declared one. The client's guard is written for exactly
    // that distinction —
    //
    //     if (peerFrameMs != null && peerFrameMs !== FRAME_SHAPE.ms) fallback
    //
    // with the comment "absent means before this existed and is left to the
    // checks below". But absent could never reach it, because this server turned
    // absent into 0, and 0 is present-and-different. So a peer whose cap entry
    // was momentarily missing — a same-sid rejoin deletes it, and a welcome built
    // in that window reads the gap — tore the LOSSLESS AUDIO LANE down and put the
    // call on Opus. Silently: `pcm-fallback {why:'peer-frame-shape', quiet:true}`.
    //
    // Measured 2026-08-20: 3 of 8 rig calls against production hit it, one of them
    // losing the lane on BOTH ends (`pcm-frame-mismatch {ours:8, theirs:0}`).
    // Nothing else in the run said the call had been downgraded.
    const peerFrameCap = () => {
      for (const [p] of this.peers) if (p !== server) return this.pcmFrameCaps.get(p) ?? null;
      return null;
    };

    // §3.2 / §4: relay listener. When THREE_ENABLED, inbound messages are
    // inspected: a JSON object with a string `to` field naming a valid role is
    // forwarded to that one socket (addressed send); anything else — parse
    // failure, missing/invalid `to`, binary — is broadcast to every other peer
    // (the fan-out generalisation of today's relay). In both cases `from` is
    // server-stamped with this socket's role so a client cannot impersonate
    // another occupant's signaling. When the flag is off, relay stays exactly
    // as it was: opaque forward to every other socket, no JSON inspection.
    server.addEventListener('message', (e: MessageEvent) => {
      this.lastSeen.set(server, Date.now()); // #62: liveness for ghost eviction
      // KEEPALIVE, and it TERMINATES HERE. After the offer/answer/ICE exchange
      // the signaling socket goes completely silent for the rest of the call,
      // and an idle TCP connection through a VPN or a corporate proxy gets
      // reaped — measured as 37 `recover {why:"ws-close"}` events across the
      // captured Delhi calls on 2026-08-14, each one previously ending the
      // peer's call outright. Holding the departure announcement (see teardown)
      // makes the drop survivable; this is the half that stops it happening.
      //
      // Answered here rather than relayed: the peer has no use for it, and a
      // ping that reached the far end would be a second thing to get wrong.
      // Placed above the THREE branch so it works on every path, and matched
      // before any parse the relay does so it can never be broadcast.
      // LAB REPLY, and it TERMINATES HERE TOO. An occupant answering a lab
      // frame is talking to the operator, not to the other person in the call;
      // relaying it would put a new message type on a peer's signaling chain
      // for no reason, which is the exact mistake the keepalive below avoids.
      // Bounded at 64 so a client that chatters cannot grow the room.
      // 64 KB, not 8: a `deep:1` snapshot reply is the whole stats object and the
      // 8 KB guard silently ATE it — the operator saw `replies: []` from two live
      // peers, indistinguishable from clients that never answered.
      if (typeof e.data === 'string' && e.data.length < 65536 && e.data.includes('"lab-reply"')) {
        try {
          const m = JSON.parse(e.data) as Record<string, unknown>;
          if (m.type === 'lab-reply') {
            this.labReplies.push({ ...m, role: this.peers.get(server) ?? null, wall: Date.now() });
            if (this.labReplies.length > 64) this.labReplies.splice(0, this.labReplies.length - 64);
            return;
          }
        } catch { /* not JSON → fall through to the relay */ }
      }
      if (typeof e.data === 'string' && e.data.length < 64 && e.data.includes('"ping"')) {
        try {
          const m = JSON.parse(e.data) as Record<string, unknown>;
          if (m.type === 'ping') {
            try { server.send(JSON.stringify({ type: 'pong', t: m.t ?? null })); } catch { /* closing */ }
            return;
          }
        } catch { /* not our ping — fall through to the relay unchanged */ }
      }
      if (THREE_ENABLED && typeof e.data === 'string') {
        let msg: Record<string, unknown> | null = null;
        try { msg = JSON.parse(e.data) as Record<string, unknown>; } catch { /* unparseable → broadcast */ }
        if (msg !== null && typeof msg === 'object') {
          msg.from = role;
          const stamped = JSON.stringify(msg);
          if (typeof msg.to === 'string' && ROLES.includes(msg.to as typeof ROLES[number])) {
            // Addressed send: forward to the single socket holding that role.
            // If the target slot is empty, silently drop.
            for (const [p, r] of this.peers) {
              if (r === msg.to && p.readyState === WebSocket.READY_STATE_OPEN) {
                try { p.send(stamped); } catch { /* reaped on close */ }
              }
            }
            return;
          }
          // Parseable but no valid `to` → broadcast with the `from` stamp.
          for (const [p] of this.peers) {
            if (p !== server && p.readyState === WebSocket.READY_STATE_OPEN) {
              try { p.send(stamped); } catch { /* reaped on close */ }
            }
          }
          return;
        }
      }
      // Flag off, binary data, or unparseable string → opaque broadcast,
      // byte-identical to today's relay.
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
      // Idempotent: an abrupt drop fires BOTH 'close' and 'error' on the same
      // socket, so this runs twice. The first pass deletes `server` from
      // `peers`; without this guard the second pass read `gone = undefined`
      // and broadcast `peer-left` with NO `peer` field — which a three-person
      // client reads as the room-wide clear-all (§3.3's `!m.peer` branch),
      // emptying the survivors' peer table and nulling mediaPeer while their
      // call was still live. Found by call3.mjs assertion 7 on staging: after
      // one peer's abrupt exit, both survivors went to peers ∅ / media null.
      if (!this.peers.has(server)) return;
      const gone = this.peers.get(server);
      const sid = this.sids.get(server); // BEFORE the delete below
      this.peers.delete(server);
      this.laneCaps.delete(server);
      this.pcmCaps.delete(server);
      this.pcmFrameCaps.delete(server);
      this.sids.delete(server);
      this.vers.delete(server);
      this.geo.delete(server);
      this.lastSeen.delete(server);
      const announce = () => {
        for (const [p] of this.peers) {
          try {
            // §4.5: `peer` is additive — old clients ignore it; new clients use
            // it to tear down only the departed pair.
            p.send(JSON.stringify({ type: 'peer-left', peer: gone }));
          } catch {
            /* ignore */
          }
        }
      };
      // THE SLOT FREES NOW; ONLY THE ANNOUNCEMENT WAITS. `peers` is already
      // updated above, so capacity, role reuse and relay are unchanged — this
      // delays one message and nothing else.
      //
      // Why: a signaling socket that dies and comes straight back is a blip, and
      // announcing it costs the OTHER side its entire call. `peer-left` puts the
      // peer on "they left", empties its screen back to the lobby and stops the
      // clock; the returning tab then arrives as `peer-joined` and both ends
      // renegotiate from nothing. Measured across the captured Delhi calls on
      // 2026-08-14: `recover {why:"ws-close"}` fired 37 times. That is 37 calls
      // visibly ended by a control channel hiccup while the media connection
      // underneath was still alive and carrying audio and video.
      //
      // `sid` lives in sessionStorage, so it survives the reload the recovery
      // performs — the returning tab is recognisable, and `admit` cancels this
      // timer before it fires. The peer then sees only `peer-joined`, which it
      // already handles in place via resetForNextPeer (no reload on that side).
      //
      // The cost is bounded and one-directional: a GENUINE departure is
      // announced LEAVE_GRACE_MS late. Trading a few seconds of staleness on a
      // real exit against not ending live calls on a blip is the right side of
      // that deal, given how often the blip actually happens.
      if (!sid) { announce(); return; }
      // Already back — a new socket for this tab was admitted before this close
      // event even ran (evictAndCheckFull closes the ghost, and close is async,
      // so this ordering is normal rather than exceptional). Nothing to say.
      for (const [p] of this.peers) if (this.sids.get(p) === sid) return;
      const prev = this.pendingLeaves.get(sid);
      if (prev !== undefined) clearTimeout(prev);
      this.pendingLeaves.set(
        sid,
        setTimeout(() => { this.pendingLeaves.delete(sid); announce(); }, LEAVE_GRACE_MS),
      );
    };
    server.addEventListener('close', teardown);
    server.addEventListener('error', teardown);

    // Build the peers array for the welcome message — every other occupant's
    // role and transport caps. Additive: old clients ignore it.
    const peersArr: Array<{ role: string; lane: number; pcm: number }> = [];
    for (const [p, r] of this.peers) {
      if (p !== server) {
        peersArr.push({ role: r, lane: this.laneCaps.get(p) ?? 0, pcm: this.pcmCaps.get(p) ?? 0 });
      }
    }

    server.send(
      JSON.stringify({
        type: 'welcome',
        role,
        peerPresent: this.peers.size >= 2,
        // PHASE 1: REPORTED, NOT ACTED ON. How far apart the two occupants are,
        // and whether that is far enough for relaying to beat going direct.
        // The client logs both and only changes its ICE policy behind
        // `?icepolicy=1`, so this ships as a measurement first — a wrong
        // distance that merely appears in telemetry costs nothing, while a
        // wrong distance that forces `iceTransportPolicy: 'relay'` costs a call.
        // Null whenever either side reported no position, which is common and
        // simply means "no opinion".
        kmApart: this.kmApart(server),
        preferRelay: (this.kmApart(server) ?? 0) >= RELAY_KM,
        peerLane: peerCap(this.laneCaps),
        peerPcm: peerCap(this.pcmCaps),
        peerPcmFrame: peerFrameCap(),
        // Additive fields — old clients ignore them.
        cap: this.cap(v),
        peers: peersArr,
        session_epoch_us: this.epochUs,
        // Occupants are the authorized readers of this room's log. Additive;
        // older clients ignore it and simply get 403 on GET /log or /summary
        // until they update. Their POSTs are unaffected.
        logToken: this.logToken,
      }),
    );
    // §4.6: on every admission, tell every other occupant about the arriver.
    // The incumbent learns the arriver's transport here — its own `welcome`
    // went out to an empty room and carried peerLane: null.
    for (const [p] of this.peers) {
      if (p !== server) {
        try {
          // The distance rides here too, and it has to. The incumbent's own
          // `welcome` went out to an EMPTY room, so its `kmApart` was null —
          // there was nobody to be far from yet. The incumbent is also role 'a',
          // the only side that ever offers, so for phase 2 it is precisely the
          // half that must know the answer before it builds a peer connection.
          // Computed from `p`, not from `server`: each side is told how far away
          // the OTHER one is, which for two occupants is the same number but
          // stays correct if a third ever arrives.
          const km = this.kmApart(p);
          p.send(JSON.stringify({
            type: 'peer-joined', peer: role, peerLane: lane, peerPcm: pcm,
            peerPcmFrame: pcmFrame,
            kmApart: km, preferRelay: (km ?? 0) >= RELAY_KM,
          }));
        } catch {
          /* ignore */
        }
      }
    }
  }

  private signal(request: Request): Response {
    if (request.headers.get('upgrade') !== 'websocket') return json({ error: 'expected websocket' }, 426);

    const q = new URL(request.url).searchParams;
    const hold = q.get('hold') === '1';

    // Persist the room code so hold-join admission can stamp the registry
    // (the route knows the code; the DO learns it from the URL it receives).
    // The route rewrites the DO request to https://do/ws — the pathname does
    // not carry the room code. The route appends it as ?code= instead (see
    // the ws route), because hold-join admission stamps the rooms registry
    // from inside the DO and must know which room it is.
    const codePart = q.get('code');
    if (codePart) this.roomCode = codePart;

    if (hold) {
      // Hold-mode upgrade: accept the socket but do NOT admit. The lobby
      // pre-dials the room WS before the click; the socket waits in `held`
      // until the client sends {type:'join'}, at which point admission runs.
      // A lurker never occupies a slot, never relays, and cannot inject.
      const pair = new WebSocketPair();
      const [client, server] = [pair[0], pair[1]];
      server.accept();
      this.noteGeo(server, request);
      this.held.add(server);

      // 120 s idle timeout: a lobby tab that never clicks must not keep a
      // socket open forever.
      const timer = setTimeout(() => {
        if (this.held.has(server)) {
          this.held.delete(server);
          this.heldTimers.delete(server);
          try { server.close(1000, 'hold timeout'); } catch { /* gone */ }
        }
      }, 120_000);
      this.heldTimers.set(server, timer);

      let joined = false;
      server.addEventListener('message', (e: MessageEvent) => {
        // Once admitted, the hold listener is a no-op — the relay listener
        // installed by admit() handles all post-admission traffic.
        if (joined) return;
        let m: Record<string, unknown>;
        try { m = JSON.parse(e.data as string); } catch { return; }
        if (m.type !== 'join') return; // held sockets ignore non-join messages
        if (!this.held.has(server)) return;
        this.held.delete(server);
        const ht = this.heldTimers.get(server);
        if (ht !== undefined) { clearTimeout(ht); this.heldTimers.delete(server); }
        joined = true;

        const lane = Number(m.lane) || 0;
        const pcm = Number(m.pcm) || 0;
        // undefined, not 0, when absent: a peer from before this field existed must
        // read as "no opinion", and 0 is a real (wrong) frame size.
        const pcmFrame = m.pcmFrame == null ? undefined : Number(m.pcmFrame) || undefined;
        const sid = m.sid ? String(m.sid) : null;
        const hv = Number(m.v) || 1;

        if (this.evictAndCheckFull(sid, hv)) {
          server.send(JSON.stringify({ type: 'full' }));
          server.close(1000, 'room full');
          return;
        }
        this.admit(server, {
          lane, pcm, pcmFrame, sid, v: hv,
          full: () => {
            server.send(JSON.stringify({ type: 'full' }));
            server.close(1000, 'room full');
          },
        });
        // Stamp the rooms registry — a hold-join is a real call start.
        if (this.roomCode) {
          this.env.HEALTH.get(this.env.HEALTH.idFromName('global'))
            .fetch(new Request('https://do/room-seen', { method: 'POST', body: this.roomCode }))
            .then(() => {}, () => {});
        }
      });

      const holdTeardown = () => {
        this.held.delete(server);
        const ht = this.heldTimers.get(server);
        if (ht !== undefined) { clearTimeout(ht); this.heldTimers.delete(server); }
      };
      server.addEventListener('close', holdTeardown);
      server.addEventListener('error', holdTeardown);

      return new Response(null, { status: 101, webSocket: client });
    }

    // Normal (non-hold) upgrade: evict + full-check inline before creating
    // the pair, exactly as before — the 409 must remain an HTTP response,
    // not an open-then-close.
    const upSid = q.get('sid') || null;
    const upV = Number(q.get('v')) || 1;
    if (this.evictAndCheckFull(upSid, upV)) return new Response('room full', { status: 409 });

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();
    this.noteGeo(server, request);

    this.admit(server, {
      lane: Number(q.get('lane')) || 0,
      pcm: Number(q.get('pcm')) || 0,
      pcmFrame: Number(q.get('pcmframe')) || undefined,
      sid: upSid,
      v: upV,
      full: () => { /* unreachable: checked above */ },
    });

    return new Response(null, { status: 101, webSocket: client });
  }

  // ── Interpreter (TRANSLATE-SPEC.md) ───────────────────────────────────────
  // One WS per speaking side: browser streams 16 kHz s16le mic audio up; we run
  // Scribe v2 Realtime → MT → Flash v2.5 TTS and deliver captions (JSON) and
  // translated 48 kHz s16le audio (binary) to the PEER's socket. Law 0: nothing
  // here touches signaling or Lane A — if this socket dies the call is unchanged.
  //
  // No transcript is STORED anywhere (the header's no-content rule): text lives
  // only in flight between the vendors and the two occupants of the call.
  private async xlate(request: Request): Promise<Response> {
    if (request.headers.get('upgrade') !== 'websocket') return json({ error: 'expected websocket' }, 426);
    const q = new URL(request.url).searchParams;
    const role = q.get('role') === 'b' ? 'b' : 'a';
    // The 🌐 button sends navigator.language, which is region-tagged (es-ES,
    // en-US, hi-IN). Gemini's targetLanguageCode accepts setup but then closes
    // 1007 "invalid argument" on ANY region subtag (probed 2026-08-06), which
    // crash-looped the whole session. Primary subtag is the wire format here.
    const lang = (q.get('lang') || 'en').split('-')[0].toLowerCase().slice(0, 8);
    // Vendor: Gemini Live Translate is the default whenever its key exists;
    // `?xlvendor=el` on the page (forwarded here as vendor=el) forces the
    // legacy ElevenLabs pipeline so quality/latency stays A/B-able.
    const vendor = q.get('vendor') === 'el' ? 'el'
      : q.get('vendor') === 'gemini' ? 'gemini'
      : this.env.GEMINI_API_KEY ? 'gemini' : 'el';
    if (vendor === 'gemini') {
      const gk = this.env.GEMINI_API_KEY;
      if (!gk) return json({ error: 'translation not configured' }, 503);
      const limited = await this.xlateMeter();
      if (limited) return limited;
      return this.xlateGemini(role, lang, gk);
    }
    const key = this.env.ELEVENLABS_API_KEY;
    if (!key) return json({ error: 'translation not configured' }, 503);
    const limitedEl = await this.xlateMeter();
    if (limitedEl) return limitedEl;

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();
    // Binary frames arrive as Blob by default here (measured: every uplink
    // chunk decoded to 0 bytes and Scribe heard pure silence). Ask for
    // ArrayBuffer explicitly.
    try { (server as unknown as { binaryType: string }).binaryType = 'arraybuffer'; } catch { /* older runtime */ }
    try { this.xl.get(role)?.sock.close(); this.xl.get(role)?.up?.close(); } catch { /* replaced */ }
    const st = { sock: server, lang, up: null as WebSocket | null, ttsBusy: Promise.resolve(), seg: 0 };
    this.xl.set(role, st);
    const peer = () => this.xl.get(role === 'a' ? 'b' : 'a') ?? null;
    const say = (s: WebSocket | undefined | null, m: unknown) => { try { s?.send(JSON.stringify(m)); } catch { /* dead */ } };

    let lastCommitAt = 0; // Date.now() at the client's quiet-flush — msStt anchor
    let upSent = 0;       // audio chunks actually forwarded upstream
    let upConnecting = false;
    let lastUpTry = 0;
    const upOpen = () => st.up !== null && st.up.readyState === WebSocket.READY_STATE_OPEN;
    const upTypes: Record<string, number> = {};

    const onUpMessage = (e: MessageEvent) => {
      let m: Record<string, unknown>;
      try { m = JSON.parse(e.data as string); } catch { return; }
      const mt = String(m.message_type ?? '');
      upTypes[mt] = (upTypes[mt] ?? 0) + 1;
      if (mt === 'partial_transcript' && m.text) {
        // Live source-language caption on the far side while the phrase is
        // still being spoken — the "they're saying something" feedback.
        say(peer()?.sock, { type: 'cap', fin: 0, lang, txt: String(m.text) });
      } else if (mt === 'committed_transcript_with_timestamps' && String(m.text ?? '').trim()) {
        // With include_language_detection=true every commit arrives TWICE —
        // this variant (carrying language_code) and a bare committed_transcript.
        // Handle only this one or every phrase is translated and spoken twice.
        const msStt = lastCommitAt ? Date.now() - lastCommitAt : null;
        void this.deliver(role, String(m.text), msStt, String(m.language_code ?? ''));
      } else if (mt === 'session_started') {
        say(server, { type: 'xl-ready', lang });
      } else if (/error|invalid/.test(mt)) {
        say(server, { type: 'xl-err', where: 'scribe', e: JSON.stringify(m).slice(0, 300) });
      }
    };

    // Scribe idles out a silent listener and closes (measured: code 1000 after
    // ~15 s of no speech). That must never be terminal — the session is
    // re-opened lazily by the next audio chunk, so a person who listens for
    // ten minutes and then speaks still gets transcribed.
    const connectScribe = async (): Promise<boolean> => {
      if (upConnecting || Date.now() - lastUpTry < 2000) return false;
      upConnecting = true;
      lastUpTry = Date.now();
      try {
        const r = await fetch(
          // commit_strategy=vad: Scribe segments at phrase ends itself. Manual
          // commits are OFF — at conversational pause cadence they trip the
          // vendor's `commit_throttled` and it hard-closes the session
          // (measured 2026-08-05; 4 s spacing survived, ~1.5 s did not).
          // vad_silence_threshold_secs=0.5: commit half a second into a pause —
          // the phrase boundary in conversational speech (defaults never fired
          // on 900 ms inter-sentence pauses, measured 2026-08-05).
          // No language_code: the speaker's language is DETECTED per segment
          // (the button asks nothing, TRANSLATE-SPEC.md P0'). `lang` on this
          // socket is the LISTENING language — what this side wants to hear.
          `https://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime&audio_format=pcm_16000&commit_strategy=vad&vad_silence_threshold_secs=0.5&min_silence_duration_ms=400&include_language_detection=true`,
          { headers: { Upgrade: 'websocket', 'xi-api-key': key } },
        );
        const up = r.webSocket;
        if (!up) throw new Error(`scribe upgrade ${r.status}`);
        up.accept();
        up.addEventListener('message', onUpMessage);
        up.addEventListener('close', (e: CloseEvent) =>
          say(server, { type: 'xl-err', where: 'scribe-closed', code: e.code, reason: String(e.reason).slice(0, 200), upSent }));
        up.addEventListener('error', () => say(server, { type: 'xl-err', where: 'scribe-socket-error', upSent }));
        st.up = up;
        return true;
      } catch (e) {
        say(server, { type: 'xl-err', where: 'scribe-connect', e: String(e) });
        return false;
      } finally {
        upConnecting = false;
      }
    };
    await connectScribe();

    // 64 KiB-safe base64 for audio chunks (browser sends 100 ms = 3,200 B).
    const b64 = (u8: Uint8Array) => {
      let s = '';
      for (let i = 0; i < u8.length; i += 8192) s += String.fromCharCode(...u8.subarray(i, i + 8192));
      return btoa(s);
    };
    server.addEventListener('message', (e: MessageEvent) => {
      if (typeof e.data === 'string') {
        // The client's onset VAD saying "phrase over". With commit_strategy=vad
        // this is a TIMING ANCHOR only (msStt = end-of-speech → transcript);
        // sending manual commits at this cadence killed the session (above).
        let mm: Record<string, unknown>; try { mm = JSON.parse(e.data); } catch { return; }
        if (mm.type === 'flush') lastCommitAt = Date.now();
        return;
      }
      if (!upOpen()) { void connectScribe(); return; } // chunk dropped; next ones flow
      {
        upSent++;
        const u8 = new Uint8Array(e.data as ArrayBuffer);
        const enc = b64(u8);
        if (upSent % 50 === 0) {
          // Instrument the instrument: decode our own base64 back and measure
          // the audio energy Scribe is actually being handed.
          const back = atob(enc);
          let s2 = 0;
          for (let i = 0; i + 1 < back.length; i += 2) {
            let v = back.charCodeAt(i) | (back.charCodeAt(i + 1) << 8);
            if (v > 32767) v -= 65536;
            s2 += v * v;
          }
          const rms = Math.round(Math.sqrt(s2 / (back.length / 2)));
          say(server, { type: 'xl-stat', upSent, upTypes, chunkBytes: u8.byteLength, rms });
        }
        st.up!.send(JSON.stringify({
          message_type: 'input_audio_chunk',
          audio_base_64: enc,
          commit: false,
          sample_rate: 16000,
        }));
      }
    });

    const teardown = () => {
      try { st.up?.close(); } catch { /* gone */ }
      if (this.xl.get(role) === st) this.xl.delete(role);
    };
    server.addEventListener('close', teardown);
    server.addEventListener('error', teardown);
    return new Response(null, { status: 101, webSocket: client });
  }

  // ── Interpreter, Gemini vendor ─────────────────────────────────────────────
  // One Gemini 3.5 Live Translate session per speaking side replaces the whole
  // Scribe→MT→TTS chain: 16 kHz PCM up, translated 24 kHz PCM + transcripts
  // down, continuously (no turn boundaries — measured: the model streams
  // translation ~a phrase behind the speaker; quiet→first-audio 164 ms on the
  // 2026-08-06 probe vs ~730 ms T_tail for the legacy chain). The session's
  // target language is the PEER's listening language, so it can only be opened
  // once a peer with a known lang exists; until then uplink chunks queue
  // (bounded) exactly like the Scribe-connecting race. Law 0 unchanged: this
  // socket is a sibling of the call, killing it changes nothing else.
  //
  // Same-language pair: echoTargetLanguage=false makes the model stay silent
  // and the transcripts still flow — captions only, no TTS parroting, same
  // behaviour the EL path implemented by hand.
  // ── Interpreter metering ────────────────────────────────────────────────
  // The interpreter is the one lane that costs real vendor money per minute,
  // and the embed (data-translate) puts it one script tag away from any
  // website — so a room's daily budget must exist before that ships. The
  // meter charges a 600 s GRAIN at session START against XLATE_DAY_SECONDS
  // (default 7200 s/room/UTC-day): coarse on purpose — sessions are long-
  // lived with lazy reconnect, and wall-second accounting would need close
  // hooks inside both vendor state machines for a precision the risk model
  // does not need. Over budget: the socket is ACCEPTED, told why in a shape
  // xlate.js renders as a caption, and closed — a refused upgrade is silent
  // on the client (measured for the no-key 503), and a silent limit is a
  // support ticket.
  private async xlateMeter(): Promise<Response | null> {
    const capSec = Number(this.env.XLATE_DAY_SECONDS ?? 7200);
    if (!Number.isFinite(capSec) || capSec <= 0) return null; // 0/invalid = unmetered
    const day = new Date().toISOString().slice(0, 10);
    const k = `xl_sec_${day}`;
    const used = (await this.state.storage.get<number>(k)) ?? 0;
    if (used >= capSec) {
      const pair = new WebSocketPair();
      const [client, server] = [pair[0], pair[1]];
      server.accept();
      try {
        server.send(JSON.stringify({
          type: 'limit',
          txt: 'translation limit reached for today — resets at midnight UTC',
          usedSec: used, capSec,
        }));
      } catch { /* client gone */ }
      server.close(1000, 'xlate daily cap');
      return new Response(null, { status: 101, webSocket: client });
    }
    await this.state.storage.put(k, used + 600);
    // Yesterday's counters are dead weight in this room's storage forever if
    // nothing sweeps them; one prefix-list per session start is cheap.
    const old = await this.state.storage.list<number>({ prefix: 'xl_sec_' });
    for (const kk of old.keys()) if (kk !== k) await this.state.storage.delete(kk);
    return null;
  }

  private xlateGemini(role: string, lang: string, key: string): Response {
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();
    try { (server as unknown as { binaryType: string }).binaryType = 'arraybuffer'; } catch { /* older runtime */ }
    try { this.xl.get(role)?.sock.close(); this.xl.get(role)?.up?.close(); } catch { /* replaced */ }
    const st = { sock: server, lang, up: null as WebSocket | null, ttsBusy: Promise.resolve(), seg: 0, vendor: 'gemini', target: '' };
    this.xl.set(role, st);
    const peer = () => this.xl.get(role === 'a' ? 'b' : 'a') ?? null;
    const say = (s: WebSocket | undefined | null, m: unknown) => { try { s?.send(JSON.stringify(m)); } catch { /* dead */ } };

    // The peer's session translates INTO our language. If it was opened before
    // we declared ours (or we changed), it is speaking the wrong language —
    // retire it; its next uplink chunk reopens it against the right target.
    const p0 = peer();
    if (p0?.vendor === 'gemini' && p0.target && p0.target !== lang) {
      try { p0.up?.close(); } catch { /* gone */ }
      p0.up = null;
    }

    let ready = false;            // setupComplete seen on the current upstream
    let handle = '';              // sessionResumption handle — survives the 15-min session cap
    let queue: ArrayBuffer[] = []; // uplink audio while (re)connecting, bounded
    let inTxt = '', outTxt = '';  // caption accumulators (continuous stream has no vendor segmentation)
    let outBytes = 0;             // translated bytes in the open caption segment
    let carry = 0;                // last 24 kHz sample, for the ×2 upsampler's continuity
    let pend: Uint8Array | null = null; // odd trailing byte of an audio blob
    let lastCommitAt = 0;         // client flush anchor (msTts = flush → first audio)
    let awaitingAudio = false;
    let lastAudioAt = 0;
    let upSent = 0, upConnecting = false, lastUpTry = 0;
    let capTimer: ReturnType<typeof setTimeout> | null = null;
    // Refusal containment (measured on prod 2026-08-06: the preview model can
    // emit "I'm just a language model and can't help with that", speak it,
    // and then go PERMANENTLY quiet — no error, no close, translation dead
    // for the rest of the call). When the output transcript matches, the
    // caption is suppressed, remaining audio of that turn is muted, the
    // resumption handle is dropped (resuming would resume the poisoned
    // state), and the session is recycled.
    const REFUSAL_RE = /(just|only) (a|an) (language model|AI( language)? model|LLM)|can'?t help with that|cannot help with that|unable to help with that/i;
    let suppressAudio = false;
    // Deaf-session watchdog: the failure above arrives as SILENCE, so the
    // detector must be "we are speaking and the vendor says nothing", never
    // "no traffic" (a quiet listener is normal — see the Scribe idle rule).
    let lastVoicedUpAt = 0;
    let lastDownAt = 0;
    const upOpen = () => st.up !== null && st.up.readyState === WebSocket.READY_STATE_OPEN;

    const b64 = (u8: Uint8Array) => {
      let s = '';
      for (let i = 0; i < u8.length; i += 8192) s += String.fromCharCode(...u8.subarray(i, i + 8192));
      return btoa(s);
    };
    const unb64 = (s: string) => {
      const b = atob(s);
      const u = new Uint8Array(b.length);
      for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i);
      return u;
    };

    // The play worklet speaks 48 kHz s16le; Gemini emits 24 kHz. Linear ×2 with
    // the previous sample carried across chunks — half-sample latency, no seams.
    const up2x = (u8raw: Uint8Array): Uint8Array => {
      let u8 = u8raw;
      if (pend) { const j = new Uint8Array(pend.length + u8.length); j.set(pend); j.set(u8, pend.length); u8 = j; pend = null; }
      const even = u8.length & ~1;
      if (even < u8.length) pend = u8.slice(even);
      const n = even >> 1;
      const i16 = new Int16Array(n);
      for (let i = 0; i < n; i++) { let v = u8[2 * i] | (u8[2 * i + 1] << 8); if (v > 32767) v -= 65536; i16[i] = v; }
      const out = new Int16Array(n * 2);
      let prev = carry;
      for (let i = 0; i < n; i++) { const s = i16[i]; out[2 * i] = (prev + s) >> 1; out[2 * i + 1] = s; prev = s; }
      carry = prev;
      return new Uint8Array(out.buffer);
    };

    // Continuous transcripts are segmented HERE: a caption goes final when the
    // stream pauses (no new text/audio for 1.2 s), sooner after a client flush.
    const finalize = () => {
      capTimer = null;
      const src = inTxt.trim(), out = outTxt.trim();
      inTxt = ''; outTxt = '';
      if (!src && !out) return;
      const seg = st.seg++;
      say(server, { type: 'cap', fin: 1, who: 'me', seg, lang: '', txt: src || out, tr: out });
      say(peer()?.sock, { type: 'cap', fin: 1, who: 'peer', seg, lang: st.target, txt: out || src, src, msStt: null, msMt: null, mtMode: 'gemini' });
      if (outBytes) { say(peer()?.sock, { type: 'tts', seg, state: 'end', bytes: outBytes, ms: 0 }); outBytes = 0; }
    };
    const kick = (ms: number) => { if (capTimer) clearTimeout(capTimer); capTimer = setTimeout(finalize, ms); };

    const onAudio = (u8: Uint8Array) => {
      const now = Date.now();
      // A burst boundary (>600 ms of downlink silence) is this vendor's "tts
      // start" — the rig's segment counter and the msTts stamp hang off it.
      if (now - lastAudioAt > 600) {
        say(peer()?.sock, {
          type: 'tts', seg: st.seg, state: 'start', msStt: null, msMt: null,
          msTts: awaitingAudio && lastCommitAt ? now - lastCommitAt : null,
        });
        awaitingAudio = false;
      }
      lastAudioAt = now;
      const out = up2x(u8);
      if (!out.length) return;
      outBytes += out.byteLength;
      try { peer()?.sock.send(out); } catch { /* dead */ }
    };

    // Recycle the vendor session: fresh state, reconnect on the next chunk
    // (or now, if audio is mid-flight). `fresh` drops the resumption handle.
    const recycle = (why: string, fresh: boolean) => {
      say(server, { type: 'xl-err', where: `gemini-recycle-${why}` });
      if (fresh) handle = '';
      lastUpTry = 0; // the recycle IS the backoff decision — reconnect now
      const dead = st.up;
      st.up = null;
      ready = false;
      try { dead?.close(); } catch { /* gone */ }
      void connect();
    };

    const onUp = (e: MessageEvent) => {
      const s = typeof e.data === 'string' ? e.data : new TextDecoder().decode(e.data as ArrayBuffer);
      let m: Record<string, unknown>;
      try { m = JSON.parse(s); } catch { return; }
      lastDownAt = Date.now();
      if (m.setupComplete) {
        ready = true;
        suppressAudio = false; // a fresh session speaks again
        lastDownAt = Date.now();
        say(server, { type: 'xl-ready', lang });
        for (const c of queue.splice(0)) sendChunk(c);
        return;
      }
      const sru = m.sessionResumptionUpdate as { newHandle?: string; resumable?: boolean } | undefined;
      if (sru?.newHandle && sru.resumable) { handle = sru.newHandle; return; }
      if (m.goAway) { say(server, { type: 'xl-err', where: 'gemini-goaway' }); return; } // close event drives the reconnect
      if (m.error) { say(server, { type: 'xl-err', where: 'gemini', e: JSON.stringify(m.error).slice(0, 300) }); return; }
      const sc = m.serverContent as {
        inputTranscription?: { text?: string }; outputTranscription?: { text?: string };
        modelTurn?: { parts?: Array<{ inlineData?: { data?: string } }> };
        turnComplete?: boolean; generationComplete?: boolean;
      } | undefined;
      if (!sc) return;
      if (sc.inputTranscription?.text) {
        inTxt += sc.inputTranscription.text;
        // Live source-language caption on the far side while the phrase is
        // still being spoken — same contract as the EL path's partials.
        say(peer()?.sock, { type: 'cap', fin: 0, lang: '', txt: inTxt.slice(-160) });
        kick(1200);
      }
      if (sc.outputTranscription?.text) {
        outTxt += sc.outputTranscription.text;
        if (REFUSAL_RE.test(outTxt)) {
          // Not a translation — swallow the caption, mute the rest of this
          // turn's audio, and start over on a clean session.
          outTxt = ''; inTxt = '';
          suppressAudio = true;
          recycle('refusal', true);
          return;
        }
        kick(1200);
      }
      // Deliberately no kick() on audio: the model streams audio near-
      // continuously during speech (measured: chunks every ~250 ms for the
      // whole utterance), so an audio-refreshed timer would never fire and no
      // caption would ever go final. Captions segment on TRANSCRIPT pauses.
      for (const p of sc.modelTurn?.parts ?? []) {
        if (p?.inlineData?.data && !suppressAudio) onAudio(unb64(String(p.inlineData.data)));
      }
      // A monologue with no pauses still needs readable captions: roll them.
      if (inTxt.length + outTxt.length > 320) finalize();
      if (sc.turnComplete || sc.generationComplete) kick(300);
    };

    const connect = async (): Promise<boolean> => {
      const target = (peer()?.lang || '').slice(0, 16);
      if (!target) return false; // nobody listening yet — chunks stay queued
      if (upConnecting || Date.now() - lastUpTry < 2000) return false;
      upConnecting = true;
      lastUpTry = Date.now();
      try {
        const r = await fetch(
          `https://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${key}`,
          { headers: { Upgrade: 'websocket' } },
        );
        const up = r.webSocket;
        if (!up) throw new Error(`gemini upgrade ${r.status}`);
        up.accept();
        try { (up as unknown as { binaryType: string }).binaryType = 'arraybuffer'; } catch { /* older runtime */ }
        ready = false;
        st.target = target;
        up.send(JSON.stringify({
          setup: {
            model: 'models/gemini-3.5-live-translate-preview',
            generationConfig: {
              responseModalities: ['AUDIO'],
              translationConfig: { targetLanguageCode: target, echoTargetLanguage: false },
            },
            inputAudioTranscription: {},
            outputAudioTranscription: {},
            ...(handle ? { sessionResumption: { handle } } : {}),
          },
        }));
        up.addEventListener('message', onUp);
        up.addEventListener('close', (e: CloseEvent) => {
          if (st.up === up) { st.up = null; ready = false; }
          say(server, { type: 'xl-err', where: 'gemini-closed', code: e.code, reason: String(e.reason).slice(0, 200), upSent });
        });
        up.addEventListener('error', () => say(server, { type: 'xl-err', where: 'gemini-socket-error', upSent }));
        st.up = up;
        return true;
      } catch (e) {
        say(server, { type: 'xl-err', where: 'gemini-connect', e: String(e) });
        return false;
      } finally {
        upConnecting = false;
      }
    };
    void connect();

    const sendChunk = (buf: ArrayBuffer) => {
      const u8 = new Uint8Array(buf);
      upSent++;
      // Cheap per-chunk energy (16k mults/s): it feeds the deaf-session
      // watchdog, and every 50th chunk it doubles as the xl-stat probe.
      let s2 = 0;
      const i16 = new Int16Array(buf);
      for (let i = 0; i < i16.length; i++) s2 += i16[i] * i16[i];
      const rms = Math.round(Math.sqrt(s2 / (i16.length || 1)));
      const now = Date.now();
      if (rms > 300) lastVoicedUpAt = now;
      if (upSent % 50 === 0) say(server, { type: 'xl-stat', upSent, chunkBytes: u8.byteLength, rms });
      st.up!.send(JSON.stringify({ realtimeInput: { audio: { data: b64(u8), mimeType: 'audio/pcm;rate=16000' } } }));
      // Deaf-session watchdog: we are audibly speaking, the session is open,
      // and the vendor has said NOTHING (no transcript, no audio, not even a
      // resumption handle — those arrive every ~2 s normally) for 15 s. The
      // refusal wedge presents exactly like this; a quiet LISTENER does not
      // (no voiced uplink) and neither does normal translation (audio down).
      if (lastVoicedUpAt === now && lastDownAt && now - lastDownAt > 15_000 && now - lastVoicedUpAt < 1_000) {
        recycle('deaf', true);
      }
    };

    server.addEventListener('message', (e: MessageEvent) => {
      if (typeof e.data === 'string') {
        let mm: Record<string, unknown>;
        try { mm = JSON.parse(e.data); } catch { return; }
        if (mm.type === 'flush') { lastCommitAt = Date.now(); awaitingAudio = true; kick(700); }
        return;
      }
      if (!upOpen() || !ready) {
        queue.push(e.data as ArrayBuffer);
        if (queue.length > 20) queue.shift(); // ~2 s cap; losing older audio beats unbounded growth
        void connect();
        return;
      }
      sendChunk(e.data as ArrayBuffer);
    });

    const teardown = () => {
      if (capTimer) { clearTimeout(capTimer); capTimer = null; }
      try { st.up?.close(); } catch { /* gone */ }
      if (this.xl.get(role) === st) this.xl.delete(role);
    };
    server.addEventListener('close', teardown);
    server.addEventListener('error', teardown);
    return new Response(null, { status: 101, webSocket: client });
  }

  // committed source text (+ detected language) → translate → caption both
  // sides → speak to the peer, in the peer's LISTENING language.
  private async deliver(role: string, srcTxt: string, msStt: number | null, detected: string): Promise<void> {
    const me = this.xl.get(role);
    const peer = this.xl.get(role === 'a' ? 'b' : 'a');
    if (!me) return;
    const say = (s: WebSocket | undefined, m: unknown) => { try { s?.send(JSON.stringify(m)); } catch { /* dead */ } };
    const base = (s: string) => s.split('-')[0].toLowerCase();
    const src = detected || me.lang; // detection is per segment — mixed-language speakers just work
    const dst = peer?.lang ?? me.lang;
    const same = base(src) === base(dst);
    const t0 = Date.now();
    let out = srcTxt;
    let mtMode = 'same';
    if (!same) {
      try { [out, mtMode] = await this.translate(srcTxt, src, dst); }
      catch (e) { say(me.sock, { type: 'xl-err', where: 'mt', e: String(e) }); }
    }
    const msMt = Date.now() - t0;
    const seg = me.seg++;
    say(me.sock, { type: 'cap', fin: 1, who: 'me', seg, lang: src, txt: srcTxt, tr: out });
    say(peer?.sock, { type: 'cap', fin: 1, who: 'peer', seg, lang: dst, srcLang: src, txt: out, src: srcTxt, msStt, msMt, mtMode });
    // Same language on both ears → captions only. No TTS parroting people to
    // each other in a language they share.
    if (!peer || same) return;
    // Serialize TTS per speaker so segments never interleave in the peer's ear.
    me.ttsBusy = me.ttsBusy.then(() => this.speak(me, peer, out, seg, msStt, msMt)).catch(() => { /* reported inside */ });
  }

  private async translate(text: string, src: string, dst: string): Promise<[string, string]> {
    const k = this.env.ANTHROPIC_API_KEY;
    if (!k) return [text, 'passthrough']; // measurable pipeline, no MT key yet
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': k, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 500,
        system: `You are a simultaneous interpreter on a live call. Translate the utterance from ${src} to ${dst}. Preserve tone and register. Output ONLY the translation — no quotes, no notes.`,
        messages: [{ role: 'user', content: text }],
      }),
    });
    if (!r.ok) throw new Error(`mt ${r.status}`);
    const j = (await r.json()) as { content?: Array<{ text?: string }> };
    const out = j.content?.[0]?.text?.trim();
    if (!out) throw new Error('mt empty');
    return [out, 'claude'];
  }

  // Flash v2.5 HTTP stream (measured p50 176 ms to first byte from a cold
  // request — beat the WS arm in the 2026-08-05 probe). 48 kHz s16le chunks are
  // forwarded to the peer as they arrive; the client worklet does the pacing.
  private async speak(
    me: { lang: string; sock: WebSocket }, peer: { lang: string; sock: WebSocket },
    text: string, seg: number, msStt: number | null, msMt: number,
  ): Promise<void> {
    const say = (s: WebSocket, m: unknown) => { try { s.send(JSON.stringify(m)); } catch { /* dead */ } };
    const VOICE = '21m00Tcm4TlvDq8ikWAM'; // stock P1 voice; per-speaker clone is P2
    const t0 = Date.now();
    try {
      const r = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${VOICE}/stream?output_format=pcm_48000`, {
        method: 'POST',
        headers: { 'xi-api-key': this.env.ELEVENLABS_API_KEY as string, 'content-type': 'application/json' },
        body: JSON.stringify({ text, model_id: 'eleven_flash_v2_5', voice_settings: { stability: 0.5, similarity_boost: 0.8 } }),
      });
      if (!r.ok || !r.body) throw new Error(`tts ${r.status}`);
      let first = true, bytes = 0;
      const reader = r.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        if (first) { say(peer.sock, { type: 'tts', seg, state: 'start', msStt, msMt, msTts: Date.now() - t0 }); first = false; }
        bytes += value.byteLength;
        try { peer.sock.send(value); } catch { await reader.cancel(); return; }
      }
      say(peer.sock, { type: 'tts', seg, state: 'end', bytes, ms: Date.now() - t0 });
    } catch (e) {
      say(me.sock, { type: 'xl-err', where: 'tts', e: String(e) });
      say(peer.sock, { type: 'tts', seg, state: 'fail' }); // captions remain — degrade, never stall
    }
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

// ── Call-health beacon (task #49) ─────────────────────────────────────────────
// One singleton DO accumulating anonymous per-call outcomes: did it connect,
// how fast, how long it ran, how much audio was concealed. The point is the
// number we have never had — the real-world connect success rate.
//
// What is deliberately NOT here: room codes, IPs, user agents, timestamps finer
// than the server's insert time, or anything about WHO called. `cf-connecting-ip`
// is used at the edge for rate capping and never forwarded to the DO. Ingest is
// strict-allowlist like the room log: a beat with any unrecognised field, value
// type, or enum member is dropped whole, so a careless client edit cannot start
// leaking richer data through this pipe.
const HB_WINDOW_MS = 60 * 60_000;
const HB_MAX_PER_HOUR = 30; // a legit client sends ≤2 per call
const hbPosts = new Map<string, number[]>();
const HB_MAX_BODY = 2048;
const HB_MAX_ROWS = 50_000;
const HB_EVT = new Set(['connect', 'end', 'fail']);
const HB_ENGINE = new Set(['chromium', 'webkit', 'gecko', 'other']);
const HB_NET = new Set(['slow-2g', '2g', '3g', '4g']);
const HB_REASON = new Set(['leave', 'pagehide', 'error', 'recover']);
// field → validator; a beat may carry only fields its evt allows (see below)
const HB_FIELDS: Record<string, (v: unknown) => boolean> = {
  v: (v) => v === 1,
  evt: (v) => typeof v === 'string' && HB_EVT.has(v),
  engine: (v) => typeof v === 'string' && HB_ENGINE.has(v),
  net: (v) => v === null || (typeof v === 'string' && HB_NET.has(v)),
  ttcMs: (v) => v === null || (typeof v === 'number' && v >= 0 && v < 600_000),
  waitMs: (v) => v === null || (typeof v === 'number' && v >= 0 && v < 600_000),
  durS: (v) => typeof v === 'number' && v >= 0 && v < 86_400,
  concealPct: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 100),
  tape: (v) => v === 0 || v === 1,
  reason: (v) => typeof v === 'string' && HB_REASON.has(v),
  // Presence-goal aggregates. Bounds are generous sanity caps, not targets:
  // a Bluetooth sink alone reads ~300 ms of mouth→ear.
  mouthToEarMs: (v) => v === null || (typeof v === 'number' && v >= 0 && v < 10_000),
  glassToGlassMs: (v) => v === null || (typeof v === 'number' && v >= 0 && v < 10_000),
  humanGapMs: (v) => v === null || (typeof v === 'number' && v > -10_000 && v < 60_000),
  // Echo observability (directive 2026-08-11): did echo exist, did the
  // canceller help. All accumulated client-side from numbers the audio
  // thread already computes — zero added latency by construction.
  echoCorrMax: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 1),
  aecGateOpenPct: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 100),
  aecGateFlips: (v) => v === null || (typeof v === 'number' && v >= 0 && v < 100_000),
  aecErleMaxDb: (v) => v === null || (typeof v === 'number' && v > -100 && v < 100),
  aecDtPct: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 100),
  // Device/environment class (directive 2026-08-11) — coarse buckets only.
  cores: (v) => v === null || (typeof v === 'number' && v >= 1 && v <= 256),
  mem: (v) => v === null || (typeof v === 'number' && v >= 0.25 && v <= 64),
  dlMbps: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 10_000),
  rttEstMs: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 10_000),
  camW: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 16_000),
  camH: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 16_000),
  camFps: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 480),
  dpr: (v) => v === null || (typeof v === 'number' && v >= 0.5 && v <= 8),
  // Device ladder tier the call ran at (aperture parallax gates on 'strong').
  tier: (v) => v === null || (typeof v === 'string' && ['strong', 'weak', 'weaker'].includes(v)),
  // Aperture-parallax panel (directive 2026-08-11: measure it, don't guess):
  // which tracker actually ran, how much of the call it held a face, and the
  // realized detector cadence. Client-side accumulation only — zero latency.
  apTracker: (v) => v === null || v === 0 || v === 1 || v === 2 || v === 3, // 0 none, 1 mediapipe, 2 facedetector, 3 blazeface (low-end tier)
  apTrackedPct: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 100),
  apHz: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 120),
  // Per-lane route divergence (latency arc, 2026-08-13): max structural skew
  // between the fastest and slowest of the six lanes, and whether the opt-in
  // ring correction was applied. Prevalence here is the input that decides
  // whether skew-aware striping gets built.
  laneSkewMaxMs: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 10_000),
  deskewApplied: (v) => v === null || v === 0 || v === 1,
  // Skew-aware striping (opt-in ?pcmskewstripe=1): fast-lane count at call end
  // and demotion count over the call. Null on every call that never opted in.
  stripeNFast: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 16),
  stripeDemotions: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 100_000),
  // The path a REAL call took (directive #7, 2026-08-14). Every latency number
  // this project owns came from one laptop against a simulated network; these
  // three are the same questions asked of the wild. iceRttMs is the network's
  // own round trip on the pair that actually carried the call, which is also
  // the honest distance measure — under 10 ms same-city, ~250 ms across the
  // planet. Deliberately NO geography field: RTT answers "how far away" without
  // locating anybody, which keeps the beacon's aggregates-only law intact.
  icePath: (v) => v === null || (typeof v === 'string' && /^(host|srflx|prflx|relay)\/(host|srflx|prflx|relay)$/.test(v)),
  iceProto: (v) => v === null || (typeof v === 'string' && ['udp', 'tcp'].includes(v)),
  iceRttMs: (v) => v === null || (typeof v === 'number' && v >= 0 && v <= 10_000),
};
const HB_ALLOWED: Record<string, Set<string>> = {
  connect: new Set(['v', 'evt', 'engine', 'net', 'ttcMs',
    'cores', 'mem', 'dlMbps', 'rttEstMs', 'camW', 'camH', 'camFps', 'dpr', 'tier']),
  // mouthToEarMs / glassToGlassMs / humanGapMs: the presence-goal numbers
  // (how far away did the person feel), aggregates with nothing identifying.
  end: new Set(['v', 'evt', 'engine', 'net', 'durS', 'concealPct', 'tape', 'reason',
    'mouthToEarMs', 'glassToGlassMs', 'humanGapMs',
    'echoCorrMax', 'aecGateOpenPct', 'aecGateFlips', 'aecErleMaxDb', 'aecDtPct',
    'apTracker', 'apTrackedPct', 'apHz', 'laneSkewMaxMs', 'deskewApplied',
    'stripeNFast', 'stripeDemotions', 'icePath', 'iceProto', 'iceRttMs']),
  fail: new Set(['v', 'evt', 'engine', 'net', 'waitMs', 'reason']),
};

// The regions a probe may be pinned to. Shared by /api/probe and the Health
// DO's /hop route so a two-leg measurement cannot validate its legs differently.
const PROBE_REGIONS = new Set(['wnam', 'enam', 'sam', 'weur', 'eeur', 'apac', 'oc', 'afr', 'me']);

export class Health implements DurableObject {
  private sql: SqlStorage;
  constructor(private state: DurableObjectState, private env: Env) {
    this.sql = state.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS beats (
        id INTEGER PRIMARY KEY,
        wall REAL NOT NULL,
        evt TEXT NOT NULL,
        engine TEXT,
        net TEXT,
        ttc_ms REAL,
        wait_ms REAL,
        dur_s REAL,
        conceal_pct REAL,
        tape INTEGER,
        reason TEXT
      );
    `);
    // Presence-goal columns, added 2026-08-11. CREATE IF NOT EXISTS cannot
    // alter an existing table, so each column is its own idempotent ALTER —
    // "duplicate column name" on a DO that already ran this is the expected
    // no-op, not an error.
    for (const col of ['mouth_to_ear_ms REAL', 'glass_to_glass_ms REAL', 'human_gap_ms REAL',
      'echo_corr_max REAL', 'aec_gate_open_pct REAL', 'aec_gate_flips REAL', 'aec_erle_max_db REAL',
      'cores REAL', 'mem REAL', 'dl_mbps REAL', 'rtt_est_ms REAL', 'cam_w REAL', 'cam_h REAL',
      'cam_fps REAL', 'dpr REAL', 'aec_dt_pct REAL',
      'tier TEXT', 'ap_tracker REAL', 'ap_tracked_pct REAL', 'ap_hz REAL',
      'lane_skew_max_ms REAL', 'deskew_applied REAL',
      'stripe_n_fast REAL', 'stripe_demotions REAL',
      'ice_path TEXT', 'ice_proto TEXT', 'ice_rtt_ms REAL']) {
      try { this.sql.exec(`ALTER TABLE beats ADD COLUMN ${col}`); } catch { /* already there */ }
    }
    // Operator room registry. The health BEATS stay anonymous by design (no
    // room codes, ever) — this table is a separate, operator-only concern:
    // WHICH room was live WHEN, so a "yesterday's call was bad" report can be
    // turned into that room's own log without asking the user for the link.
    // Reading it requires LOG_ADMIN_TOKEN, the same credential that already
    // reads any room's full telemetry, so it widens nothing.
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS rooms (
        code TEXT PRIMARY KEY,
        first_wall REAL NOT NULL,
        last_wall REAL NOT NULL,
        joins INTEGER NOT NULL
      );
    `);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    // Region probe (150 ms goal). Answers nothing about health — it exists so
    // an edge colo can time a round trip to a DO pinned on another continent,
    // which is the only way to measure what Cloudflare's BACKBONE costs between
    // two points on earth. Deliberately the cheapest possible handler: any work
    // here would be measured as if it were network.
    if (url.pathname === '/ping') return json({ t: Date.now() });
    // Times the hop from THIS Durable Object to one pinned in another region --
    // a leg measured from inside the network rather than from the edge.
    //
    // Why this exists: Delhi->Sydney (10,428 km) costs 186 ms while
    // Delhi->US-West (~12,400 km) costs 303 ms. Only 19% further, 63% more
    // latency, same backbone, same origin -- so the US-West path is not paying
    // for distance, it is paying for routing. If Delhi->Singapore (81 ms) plus
    // Singapore->US-West beats 303 ms, then deliberately steering media through
    // an intermediate hop is worth more than anything left inside the app.
    // That question cannot be answered from the edge; it needs a DO to time its
    // own onward leg.
    if (url.pathname === '/hop') {
      const to = url.searchParams.get('to') ?? '';
      if (!PROBE_REGIONS.has(to)) return json({ error: 'bad to', allowed: [...PROBE_REGIONS] }, 400);
      const n = Math.max(1, Math.min(10, Number(url.searchParams.get('n')) || 5));
      // `alt` is the CALIBRATION arm, and nothing else here can be read without
      // it. It targets a SECOND DO pinned to the same region, so the hop covers
      // dispatch overhead and ~zero distance. Every other leg is inflated by
      // that same constant, and a ratio against the speed of light is
      // meaningless until it is subtracted -- the edge-side `region=none` arm
      // cannot do this job, because it reported 109 ms, MORE than the 81 ms
      // Singapore hop, which means that DO was never placed nearby at all.
      // A distinct name, not a self-fetch: a DO fetching itself while inside
      // its own request handler deadlocks.
      const name = url.searchParams.get('alt') ? `probe-${to}-alt` : `probe-${to}`;
      const peer = this.env.HEALTH.get(
        this.env.HEALTH.idFromName(name),
        { locationHint: to } as DurableObjectNamespaceGetDurableObjectOptions,
      );
      const samples: number[] = [];
      for (let i = 0; i < n; i++) {
        const t0 = Date.now();
        // MINIMUM, not mean: one sample measures the path plus whatever queueing
        // sat in front of it; the floor is the path. Same reasoning as the
        // transport's decaying-min RTT estimators.
        try { await peer.fetch('https://do/ping'); samples.push(Date.now() - t0); } catch { /* never take the DO down for a probe */ }
      }
      if (!samples.length) return json({ error: 'no samples', to }, 502);
      samples.sort((a, b) => a - b);
      return json({ to, minMs: samples[0], medMs: samples[Math.floor(samples.length / 2)],
                    maxMs: samples[samples.length - 1], n: samples.length });
    }
    if (url.pathname === '/ingest' && request.method === 'POST') {
      let beat: Record<string, unknown>;
      try { beat = (await request.json()) as Record<string, unknown>; } catch { return json({ error: 'bad json' }, 400); }
      if (beat === null || typeof beat !== 'object' || Array.isArray(beat)) return json({ error: 'bad shape' }, 400);
      const evt = beat.evt;
      if (typeof evt !== 'string' || !HB_ALLOWED[evt]) return json({ error: 'bad evt' }, 400);
      const allowed = HB_ALLOWED[evt];
      for (const [k, v] of Object.entries(beat)) {
        if (!allowed.has(k) || !HB_FIELDS[k]?.(v)) return json({ error: 'rejected', field: k }, 400);
      }
      this.sql.exec(
        `INSERT INTO beats (wall, evt, engine, net, ttc_ms, wait_ms, dur_s, conceal_pct, tape, reason,
                            mouth_to_ear_ms, glass_to_glass_ms, human_gap_ms,
                            echo_corr_max, aec_gate_open_pct, aec_gate_flips, aec_erle_max_db,
                            cores, mem, dl_mbps, rtt_est_ms, cam_w, cam_h, cam_fps, dpr, aec_dt_pct,
                            tier, ap_tracker, ap_tracked_pct, ap_hz,
                            lane_skew_max_ms, deskew_applied, stripe_n_fast, stripe_demotions,
                            ice_path, ice_proto, ice_rtt_ms)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        Date.now(), evt, beat.engine ?? null, beat.net ?? null,
        beat.ttcMs ?? null, beat.waitMs ?? null, beat.durS ?? null,
        beat.concealPct ?? null, beat.tape ?? null, beat.reason ?? null,
        (beat.mouthToEarMs as number | null) ?? null, (beat.glassToGlassMs as number | null) ?? null,
        (beat.humanGapMs as number | null) ?? null,
        (beat.echoCorrMax as number | null) ?? null, (beat.aecGateOpenPct as number | null) ?? null,
        (beat.aecGateFlips as number | null) ?? null, (beat.aecErleMaxDb as number | null) ?? null,
        (beat.cores as number | null) ?? null, (beat.mem as number | null) ?? null,
        (beat.dlMbps as number | null) ?? null, (beat.rttEstMs as number | null) ?? null,
        (beat.camW as number | null) ?? null, (beat.camH as number | null) ?? null,
        (beat.camFps as number | null) ?? null, (beat.dpr as number | null) ?? null,
        (beat.aecDtPct as number | null) ?? null,
        (beat.tier as string | null) ?? null, (beat.apTracker as number | null) ?? null,
        (beat.apTrackedPct as number | null) ?? null, (beat.apHz as number | null) ?? null,
        (beat.laneSkewMaxMs as number | null) ?? null, (beat.deskewApplied as number | null) ?? null,
        (beat.stripeNFast as number | null) ?? null, (beat.stripeDemotions as number | null) ?? null,
        (beat.icePath as string | null) ?? null, (beat.iceProto as string | null) ?? null,
        (beat.iceRttMs as number | null) ?? null,
      );
      this.sql.exec(`DELETE FROM beats WHERE id <= (SELECT MAX(id) FROM beats) - ${HB_MAX_ROWS}`);
      return json({ ok: true });
    }
    if (url.pathname === '/room-seen' && request.method === 'POST') {
      const code = String((await request.text()) ?? '').slice(0, 32);
      if (!/^[a-z]{3}-[a-z]{4}-[a-z]{3}$|^[a-z0-9-]{1,32}$/.test(code)) return json({ error: 'bad code' }, 400);
      const wall = Date.now();
      this.sql.exec(
        `INSERT INTO rooms (code, first_wall, last_wall, joins) VALUES (?, ?, ?, 1)
         ON CONFLICT(code) DO UPDATE SET last_wall = ?, joins = joins + 1`,
        code, wall, wall, wall,
      );
      // Bounded: keep the 200 most recently active rooms.
      this.sql.exec(`DELETE FROM rooms WHERE code NOT IN (SELECT code FROM rooms ORDER BY last_wall DESC LIMIT 200)`);
      return json({ ok: true });
    }
    if (url.pathname === '/rooms' && request.method === 'GET') {
      const t = url.searchParams.get('token');
      if (!this.env.LOG_ADMIN_TOKEN || t !== this.env.LOG_ADMIN_TOKEN) return json({ error: 'admin token required' }, 403);
      const rows = this.sql.exec(
        `SELECT code, first_wall, last_wall, joins FROM rooms ORDER BY last_wall DESC LIMIT 100`,
      ).toArray() as Array<{ code: string; first_wall: number; last_wall: number; joins: number }>;
      return json(rows.map((r) => ({
        code: r.code,
        first: new Date(r.first_wall).toISOString(),
        last: new Date(r.last_wall).toISOString(),
        joins: r.joins,
      })));
    }
    // Operator-only raw tail of the beats table: the debugging loop "user
    // reports X on their machine → read what their machine actually sent"
    // needs rows, not aggregates. Same token that reads any room log.
    if (url.pathname === '/recent' && request.method === 'GET') {
      const t = url.searchParams.get('token');
      if (!this.env.LOG_ADMIN_TOKEN || t !== this.env.LOG_ADMIN_TOKEN) return json({ error: 'admin token required' }, 403);
      const n = Math.max(1, Math.min(50, Number(url.searchParams.get('n')) || 20));
      const rows = this.sql.exec(`SELECT * FROM beats ORDER BY id DESC LIMIT ?`, n)
        .toArray() as Array<Record<string, unknown>>;
      return json(rows.map((r) => ({ ...r, wall: new Date(r.wall as number).toISOString() })));
    }
    if (url.pathname === '/summary' && request.method === 'GET') {
      const days = Math.max(1, Math.min(90, Number(url.searchParams.get('days')) || 7));
      const since = Date.now() - days * 86_400_000;
      const rows = this.sql.exec(
        `SELECT evt, engine, net, ttc_ms, dur_s, conceal_pct, reason,
                mouth_to_ear_ms, glass_to_glass_ms, human_gap_ms,
                echo_corr_max, aec_gate_open_pct, aec_gate_flips, aec_erle_max_db,
                cores, mem, dl_mbps, rtt_est_ms, cam_w, cam_h, cam_fps, dpr, aec_dt_pct
           FROM beats WHERE wall >= ? ORDER BY id DESC LIMIT 20000`,
        since,
      ).toArray() as Array<Record<string, unknown>>;
      const by = (f: (r: Record<string, unknown>) => unknown) => {
        const m: Record<string, number> = {};
        for (const r of rows) { const k = String(f(r) ?? '-'); m[k] = (m[k] ?? 0) + 1; }
        return m;
      };
      const nums = (evt: string, field: string) =>
        rows.filter((r) => r.evt === evt && typeof r[field] === 'number').map((r) => r[field] as number).sort((a, b) => a - b);
      const pct = (a: number[], p: number) => (a.length ? +a[Math.min(a.length - 1, Math.floor((p / 100) * a.length))].toFixed(1) : null);
      const stats = (a: number[]) => ({ n: a.length, p50: pct(a, 50), p90: pct(a, 90), max: a.length ? +a[a.length - 1].toFixed(1) : null });
      const connects = rows.filter((r) => r.evt === 'connect').length;
      const fails = rows.filter((r) => r.evt === 'fail').length;
      return json({
        days, beats: rows.length,
        byEvt: by((r) => r.evt), byEngine: by((r) => r.engine), byNet: by((r) => r.net),
        connectRatePct: connects + fails ? +((100 * connects) / (connects + fails)).toFixed(1) : null,
        ttcMs: stats(nums('connect', 'ttc_ms')),
        durS: stats(nums('end', 'dur_s')),
        concealPct: stats(nums('end', 'conceal_pct')),
        // The presence-goal numbers, fleet-wide: how far away did the person
        // feel — sound, vision, conversation.
        mouthToEarMs: stats(nums('end', 'mouth_to_ear_ms')),
        glassToGlassMs: stats(nums('end', 'glass_to_glass_ms')),
        humanGapMs: stats(nums('end', 'human_gap_ms')),
        // Echo, fleet-wide: how often it exists and whether cancellation helps.
        echoCorrMax: stats(nums('end', 'echo_corr_max')),
        aecGateOpenPct: stats(nums('end', 'aec_gate_open_pct')),
        aecGateFlips: stats(nums('end', 'aec_gate_flips')),
        aecErleMaxDb: stats(nums('end', 'aec_erle_max_db')),
        aecDtPct: stats(nums('end', 'aec_dt_pct')),
        // Device/environment class: what hardware and networks real calls run
        // on. byCores/byCam are population buckets; the rest percentiles.
        byCores: by((r) => (r.evt === 'connect' ? r.cores : null)),
        byCam: by((r) => (r.evt === 'connect' && r.cam_h ? `${r.cam_h}p` : null)),
        dlMbps: stats(nums('connect', 'dl_mbps')),
        rttEstMs: stats(nums('connect', 'rtt_est_ms')),
        mem: stats(nums('connect', 'mem')),
        failReasons: rows.filter((r) => r.evt === 'fail').reduce((m: Record<string, number>, r) => {
          const k = String(r.reason ?? '-'); m[k] = (m[k] ?? 0) + 1; return m;
        }, {}),
        // ── #75 THE SAME NUMBERS, SPLIT BY ENGINE ────────────────────────────
        // `byEngine` above counts beats per engine, which answers "who is using
        // this" and nothing else. The question that actually needed answering on
        // 2026-08-20 was "is Chromium worse than WebKit in the field", and it took
        // hand-analysis of /recent to get at — twenty rows, because that endpoint
        // caps there. The answer was stark enough to justify a permanent view:
        // ONE live call, both ends, same second, same path — the Chromium end
        // reported glassToGlass 9428.6 ms and the WebKit end 343.2 ms.
        //
        // Engine-specific defects are a real category here (WebKit has no
        // MediaStreamTrackProcessor and no fixed-QP encoding; Chromium's data
        // channel accepts megabytes of send buffer where WebKit applies its own
        // backpressure), so a fleet view that cannot separate them cannot tell a
        // regression in one engine from a change in traffic mix. Percentiles only,
        // same shape as the fleet-wide ones directly above, so the two are
        // read side by side without a second request.
        byEngineStats: [...new Set(rows.map((r) => String(r.engine ?? '-')))].sort()
          .reduce((m: Record<string, unknown>, eng) => {
            const e = rows.filter((r) => String(r.engine ?? '-') === eng);
            const en = (evt: string, field: string) =>
              e.filter((r) => r.evt === evt && typeof r[field] === 'number')
                .map((r) => r[field] as number).sort((a, b) => a - b);
            const c = e.filter((r) => r.evt === 'connect').length;
            const f = e.filter((r) => r.evt === 'fail').length;
            m[eng] = {
              beats: e.length, ends: e.filter((r) => r.evt === 'end').length,
              connectRatePct: c + f ? +((100 * c) / (c + f)).toFixed(1) : null,
              ttcMs: stats(en('connect', 'ttc_ms')),
              glassToGlassMs: stats(en('end', 'glass_to_glass_ms')),
              mouthToEarMs: stats(en('end', 'mouth_to_ear_ms')),
              concealPct: stats(en('end', 'conceal_pct')),
            };
            return m;
          }, {}),
      });
    }
    return json({ error: 'not found' }, 404);
  }
}

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
  // 'wasm-unsafe-eval' admits WebAssembly.compile for the self-hosted
  // MediaPipe face tracker (aperture parallax) — wasm only, no eval(); the
  // binary itself still has to come from 'self'.
  //
  // KNOWN, ACCEPTED CONSOLE ERROR: Cloudflare's Bot Management "JavaScript
  // Detections" appends an inline <script> to this HTML at the edge, AFTER the
  // worker returns (it sets window.__CF$cv$params and loads
  // /cdn-cgi/challenge-platform/scripts/jsd/main.js). This policy has no
  // 'unsafe-inline' and no nonce, so our own CSP blocks Cloudflare's own
  // script, and every visitor's console logs one violation per load. Every
  // escape route was measured and is worse than the noise:
  //
  //   'unsafe-inline'  — defeats script-src for the whole app to accommodate a
  //                      feature we do not use. Never.
  //   a 'sha256-…' hash — impossible, not merely ugly: the injected text embeds
  //                      per-request tokens (r:'…', t:'…'), so the digest is
  //                      different on every response. Nothing to pin.
  //   a nonce          — requires authoring the tag; the edge appends this one
  //                      downstream of us, so there is no nonce to attach.
  //   Cache-Control:
  //     no-transform   — DOES remove the injection (measured, gone), but the
  //                      edge counts compression as a transform too: gzip
  //                      disappears and the page goes 13,423 -> 41,776 wire
  //                      bytes, 3.1x, for every visitor. 28 kB a load to
  //                      silence a script the CSP already blocks is the wrong
  //                      trade.
  //
  // The fix is at the zone, not here: Security → Bots → JavaScript Detections
  // → off. It is safe to turn off because nothing consumes the signal — audited
  // 2026-08-20 across all three custom rulesets on the zone (Tokkah Abuse
  // Shield, API Burst Shield, managed default) and NOT ONE rule references
  // cf.bot_management.*, cf.client.bot, or verified_bot; the Abuse Shield gates
  // on user-agent and path. So JS Detections is running purely to produce a
  // score no rule reads, and paying for it in standing console noise.
  //
  // Until that toggle is flipped, the violation is expected. It is enumerated
  // as known-benign in testbed/call.mjs so it cannot quietly inflate the
  // per-run "console error(s)" pass signal — the point of keeping the console
  // clean is that the NEXT error is visible, and a tolerated error that is not
  // named is indistinguishable from a new one.
  "script-src 'self' 'wasm-unsafe-eval'",
  "style-src 'unsafe-inline'",
  "img-src 'self' data:", // data: is the inline SVG favicon
  `connect-src 'self' wss://${host} ws://${host}`,
  "media-src 'self' blob:",
  "worker-src 'self' blob:", // lane 2's RTCRtpScriptTransform worker (tape.js)
  "font-src 'self'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'self'",
  // The one-line embed (embed.js) IS the product's distribution model, and it
  // frames this page from arbitrary third-party origins — 'none' here made
  // the README's headline integration a blank rectangle on every site that
  // tried it (found live 2026-08-11; it can never have worked). '*' is the
  // honest setting, not a concession: a param-gated variant would be theater
  // (any framer can add the param), and the real clickjacking defense is the
  // browser's own permission UX — camera/mic prompts inside a frame are
  // attributed to the EMBEDDING origin, which the user sees and judges.
  'frame-ancestors *',
].join('; ');

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
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

    // Call-health beacon. POST is the client's beat; GET /summary is aggregate
    // numbers only (no per-call rows are ever served). The per-IP cap bounds a
    // hostile flooder; the DO's allowlist bounds a careless client.
    if (url.pathname === '/api/health' && request.method === 'POST') {
      const ip = request.headers.get('cf-connecting-ip') ?? 'local';
      const now = Date.now();
      const hits = (hbPosts.get(ip) ?? []).filter((t) => now - t < HB_WINDOW_MS);
      if (hits.length >= HB_MAX_PER_HOUR) { hbPosts.set(ip, hits); return json({ error: 'rate' }, 429); }
      hits.push(now);
      hbPosts.set(ip, hits);
      const body = await request.text();
      if (body.length > HB_MAX_BODY) return json({ error: 'too big' }, 413);
      return env.HEALTH.get(env.HEALTH.idFromName('global')).fetch(
        new Request('https://do/ingest', { method: 'POST', body }),
      );
    }
    if (url.pathname === '/api/health/summary' && request.method === 'GET') {
      return env.HEALTH.get(env.HEALTH.idFromName('global')).fetch(
        new Request(`https://do/summary${url.search}`),
      );
    }
    // ── Region probe: what does the planet actually cost? (150 ms goal) ───────
    // The whole 150 ms budget turns on one unknown: how much worse than the
    // speed of light a real path is. Fibre carries light at c/1.468, so
    // Delhi->San Jose is 85 ms one way at 1.25x routing and 102 ms at 1.5x --
    // a 17 ms spread that dwarfs anything worth winning inside the encoder,
    // and nothing in this project has ever measured which one we get.
    //
    // A DO pinned with locationHint lands on the named continent, so an edge
    // colo can time a round trip to it. Measured HERE, at the edge, rather than
    // from the laptop: this number is then the BACKBONE cost between two points
    // on earth, with the client's own access link excluded instead of baked in.
    // `colo` names the edge that did the timing, so the distance is knowable.
    if (url.pathname === '/api/probe' && request.method === 'GET') {
      const region = url.searchParams.get('region') ?? '';
      const REGIONS = PROBE_REGIONS;
      // `via` measures the SECOND leg of a deliberately steered route: this
      // worker asks the DO in `via` to time its own hop to `region`. Pair it
      // with a plain probe of `via` (leg one) and a plain probe of `region`
      // (the direct path) and the three numbers answer the only question that
      // matters here -- whether Delhi->Singapore->US-West beats Delhi->US-West.
      const via = url.searchParams.get('via');
      if (via) {
        if (!REGIONS.has(via)) return json({ error: 'bad via', allowed: [...REGIONS] }, 400);
        if (!REGIONS.has(region)) return json({ error: 'bad region', allowed: [...REGIONS] }, 400);
        const n = Math.max(1, Math.min(10, Number(url.searchParams.get('n')) || 5));
        const hub = env.HEALTH.get(
          env.HEALTH.idFromName(`probe-${via}`),
          { locationHint: via } as DurableObjectNamespaceGetDurableObjectOptions,
        );
        const t0 = Date.now();
        const alt = url.searchParams.get('alt') ? '&alt=1' : '';
        const res = await hub.fetch(`https://do/hop?to=${region}&n=${n}${alt}`);
        const leg2 = await res.json().catch(() => null);
        return json({
          mode: 'via', via, region, colo: (request.cf?.colo as string | undefined) ?? null,
          // Leg one measured the same way the direct probe is, so the two are
          // comparable; this call's own round trip is reported alongside it as
          // a sanity check rather than as the leg.
          edgeToViaMs: Date.now() - t0, leg2,
        });
      }
      // 'none' is the CALIBRATION arm and the most important one here. Without
      // a hint the DO is created near whichever edge first asked for it, so the
      // round trip is ~all dispatch overhead and ~no distance. Every other
      // region's number is inflated by that same constant, and a ratio against
      // the speed of light means nothing until it is subtracted. Measure the
      // instrument before trusting the readings.
      if (region !== 'none' && !REGIONS.has(region)) {
        return json({ error: 'bad region', allowed: [...REGIONS, 'none'] }, 400);
      }
      const stub = region === 'none'
        ? env.HEALTH.get(env.HEALTH.idFromName('probe-local'))
        : env.HEALTH.get(
          env.HEALTH.idFromName(`probe-${region}`),
          { locationHint: region } as DurableObjectNamespaceGetDurableObjectOptions,
        );
      // Several round trips, report the MINIMUM. A single sample measures the
      // path plus whatever queueing happened to be in front of it; the floor is
      // the path. Same reasoning as the transport's decaying-min estimators.
      const n = Math.max(1, Math.min(10, Number(url.searchParams.get('n')) || 5));
      const samples: number[] = [];
      for (let i = 0; i < n; i++) {
        const t0 = Date.now();
        try {
          await stub.fetch('https://do/ping');
          samples.push(Date.now() - t0);
        } catch { /* a probe must never take the worker down */ }
      }
      if (samples.length === 0) return json({ error: 'no samples', region }, 502);
      samples.sort((a, b) => a - b);
      return json({
        region,
        colo: (request.cf?.colo as string | undefined) ?? null,
        minMs: samples[0],
        medMs: samples[Math.floor(samples.length / 2)],
        maxMs: samples[samples.length - 1],
        n: samples.length,
      });
    }
    // Operator-only: which rooms were live, when. Gated inside the DO on
    // LOG_ADMIN_TOKEN — the credential that already reads any room's log.
    if (url.pathname === '/api/health/rooms' && request.method === 'GET') {
      return env.HEALTH.get(env.HEALTH.idFromName('global')).fetch(
        new Request(`https://do/rooms${url.search}`),
      );
    }
    if (url.pathname === '/api/health/recent' && request.method === 'GET') {
      return env.HEALTH.get(env.HEALTH.idFromName('global')).fetch(
        new Request(`https://do/recent${url.search}`),
      );
    }

    // /api/room/:code/ws | /api/room/:code/log | /api/room/:code/summary | …/warm
    const m = url.pathname.match(/^\/api\/room\/([^/]+)\/(ws|log|summary|xlate|lab|warm|rv)$/);
    if (m) {
      const code = decodeURIComponent(m[1]);
      if (!ROOM_RE.test(code)) return json({ error: 'bad room code' }, 400);
      // Every join stamps the operator registry with code + time, so "the call
      // yesterday was bad" can be answered from /api/health/rooms without
      // asking anyone for the link. Fire-and-forget: the registry must never
      // cost the join anything, so its failure is swallowed whole.
      if (m[2] === 'ws' && request.headers.get('upgrade') === 'websocket' && url.searchParams.get('hold') !== '1') {
        ctx.waitUntil(
          env.HEALTH.get(env.HEALTH.idFromName('global'))
            .fetch(new Request('https://do/room-seen', { method: 'POST', body: code }))
            .then(() => {}, () => {}),
        );
      }
      // The DO's request URL is rewritten to https://do/<verb>, so the room
      // code must ride along explicitly — hold-join admission stamps the
      // rooms registry from inside the DO and needs to know which room it is.
      const doUrl = new URL(`https://do/${m[2]}${url.search}`);
      doUrl.searchParams.set('code', code);
      return env.ROOM.get(env.ROOM.idFromName(code)).fetch(new Request(doUrl.toString(), request));
    }

    if (url.pathname.startsWith('/api/')) return json({ error: 'not found' }, 404);

    // ── Native macOS releases ────────────────────────────────────────────────
    //
    // Only the tarball comes from R2. Everything a human reads -- the page, the
    // installer, the signed manifest -- is a static asset under public/macos, so
    // it is reviewable in the repo and cannot be changed without a deploy.
    //
    // No auth: the binary is meant to be downloadable by anyone with the link,
    // and the thing that makes an install safe is the Ed25519 signature the
    // client verifies, not obscurity about the URL.
    const rel = url.pathname.match(/^\/macos\/dl\/([A-Za-z0-9._-]{1,64})$/);
    if (rel) {
      if (!env.MACREL) return json({ error: 'releases not configured' }, 503);
      const obj = await env.MACREL.get(rel[1]);
      if (!obj) return json({ error: 'no such release' }, 404);
      const h = new Headers();
      obj.writeHttpMetadata(h);
      h.set('etag', obj.httpEtag);
      // Immutable: a release filename carries its version, so the bytes behind a
      // given URL never change and a year of caching is honest.
      h.set('cache-control', 'public, max-age=31536000, immutable');
      h.set('content-type', 'application/gzip');
      return new Response(obj.body, { headers: h });
    }
    // Short invite links: room.tokkah.com/etm-bkmb-iev (Meet-shaped, minted by
    // the client). The path IS the room; the asset behind it is the app shell.
    // Tightly scoped to the minted format so real assets (/app.js, /embed.js)
    // can never be shadowed by a room name.
    let assetReq = request;
    if (/^\/[a-z]{3}-[a-z]{4}-[a-z]{3}$/.test(url.pathname)) {
      const rewritten = new URL(url);
      rewritten.pathname = '/';
      assetReq = new Request(rewritten.toString(), request);
    }
    const asset = await env.ASSETS.fetch(assetReq);
    // Hardening headers on everything; CSP on the HTML (previously none — the
    // only headers were COOP/COEP, and only under ?pcmaudio=1). The response is
    // now always re-wrapped, so the old "flag-off is byte-identical" invariant
    // applies to the body only, not the headers.
    const res = new Response(asset.body, asset);
    res.headers.set('X-Content-Type-Options', 'nosniff');
    res.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
    // #74 A dedicated worker's SCRIPT response must itself carry COEP on a
    // cross-origin-isolated page, or Chromium refuses the spawn with
    // ERR_BLOCKED_BY_RESPONSE. core/tickworker.js was being blocked, so every
    // clock silently rode the plain-timer insurance fallback -- throttled to
    // 1 Hz in background tabs, the exact defect 17.66 existed to fix (the
    // failover made it invisible: tickLate500 was the only witness). COEP +
    // CORP on every asset is harmless: everything here is same-origin.
    res.headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
    res.headers.set('Cross-Origin-Resource-Policy', 'same-origin');
    if (asset.headers.get('content-type')?.includes('text/html')) {
      res.headers.set('Content-Security-Policy', csp(new URL(request.url).host));
      // No X-Frame-Options: it cannot express "any ancestor" (its ALLOW-FROM
      // died with IE) and DENY here silently vetoed the embed in pre-CSP2
      // browsers exactly as frame-ancestors 'none' did everywhere else.
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
      // documented opt-out from edge HTML rewriting, and it does stop the
      // injected third-party scripts (Web Analytics beacon + bot-management JS
      // detection) — measured, both gone. But the edge counts compression as a
      // transform too: gzip disappeared and the page went 13,423 -> 41,776 wire
      // bytes, 3.1x, for every visitor. Spending 28 kB a load to suppress a
      // script the CSP already blocks is the wrong trade. Turn the features off
      // at the zone instead. Status 2026-08-20: the Web Analytics beacon is
      // gone from the served HTML, JS Detections is still injecting — see the
      // KNOWN, ACCEPTED CONSOLE ERROR note on script-src in csp() above for
      // why no CSP-side fix exists and which toggle actually ends it.
    }
    return res;
  },
};
