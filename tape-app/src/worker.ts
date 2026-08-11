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
  HEALTH: DurableObjectNamespace;
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
  // Interpreter (TRANSLATE-SPEC.md). Keys live here so the browser never sees
  // them; with neither key /xlate answers 503 and the client shows nothing.
  // GEMINI_API_KEY present → Gemini 3.5 Live Translate is the default vendor
  // (one speech-to-speech session replaces the STT→MT→TTS chain). The legacy
  // ElevenLabs pipeline stays reachable via ?xlvendor=el for A/Bs.
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
  private sids = new Map<WebSocket, string>();
  // Wire version per socket — the admission gate of §3.4. v=1 (default, old
  // clients) anywhere in the room caps it at 2; v≥2 everywhere + THREE_ENABLED
  // lifts it to 3. Parallel to laneCaps/pcmCaps, torn down in the same places.
  private vers = new Map<WebSocket, number>();
  private held = new Set<WebSocket>();
  private heldTimers = new Map<WebSocket, ReturnType<typeof setTimeout>>();
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
    if (url.pathname.endsWith('/xlate')) return this.xlate(request);
    return this.signal(request);
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
          this.sids.delete(p);
          this.vers.delete(p);
        }
      }
    }
    return this.peers.size >= this.cap(v);
  }

  // The admission logic: role assignment, cap registration, relay listener,
  // teardown wiring, welcome message, and peer-joined broadcast. Extracted so
  // the upgrade path and the hold-join path share it.
  private admit(server: WebSocket, opts: { lane: number; pcm: number; sid: string | null; v: number; full: () => void }): void {
    if (this.peers.size >= this.cap(opts.v)) { opts.full(); return; }

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
    const { lane, pcm, sid, v } = opts;
    this.laneCaps.set(server, lane);
    this.pcmCaps.set(server, pcm);
    if (sid) this.sids.set(server, sid);
    this.vers.set(server, v);
    const peerCap = (m: Map<WebSocket, number>) => {
      for (const [p] of this.peers) if (p !== server) return m.get(p) ?? 0;
      return null; // nobody else here yet; `peer-joined` carries it when they arrive
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
      this.peers.delete(server);
      this.laneCaps.delete(server);
      this.pcmCaps.delete(server);
      this.sids.delete(server);
      this.vers.delete(server);
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
        peerLane: peerCap(this.laneCaps),
        peerPcm: peerCap(this.pcmCaps),
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
          p.send(JSON.stringify({ type: 'peer-joined', peer: role, peerLane: lane, peerPcm: pcm }));
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
        const sid = m.sid ? String(m.sid) : null;
        const hv = Number(m.v) || 1;

        if (this.evictAndCheckFull(sid, hv)) {
          server.send(JSON.stringify({ type: 'full' }));
          server.close(1000, 'room full');
          return;
        }
        this.admit(server, {
          lane, pcm, sid, v: hv,
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

    this.admit(server, {
      lane: Number(q.get('lane')) || 0,
      pcm: Number(q.get('pcm')) || 0,
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
};
const HB_ALLOWED: Record<string, Set<string>> = {
  connect: new Set(['v', 'evt', 'engine', 'net', 'ttcMs']),
  // mouthToEarMs / glassToGlassMs / humanGapMs: the presence-goal numbers
  // (how far away did the person feel), aggregates with nothing identifying.
  end: new Set(['v', 'evt', 'engine', 'net', 'durS', 'concealPct', 'tape', 'reason',
    'mouthToEarMs', 'glassToGlassMs', 'humanGapMs']),
  fail: new Set(['v', 'evt', 'engine', 'net', 'waitMs', 'reason']),
};

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
    for (const col of ['mouth_to_ear_ms REAL', 'glass_to_glass_ms REAL', 'human_gap_ms REAL']) {
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
                            mouth_to_ear_ms, glass_to_glass_ms, human_gap_ms)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        Date.now(), evt, beat.engine ?? null, beat.net ?? null,
        beat.ttcMs ?? null, beat.waitMs ?? null, beat.durS ?? null,
        beat.concealPct ?? null, beat.tape ?? null, beat.reason ?? null,
        (beat.mouthToEarMs as number | null) ?? null, (beat.glassToGlassMs as number | null) ?? null,
        (beat.humanGapMs as number | null) ?? null,
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
    if (url.pathname === '/summary' && request.method === 'GET') {
      const days = Math.max(1, Math.min(90, Number(url.searchParams.get('days')) || 7));
      const since = Date.now() - days * 86_400_000;
      const rows = this.sql.exec(
        `SELECT evt, engine, net, ttc_ms, dur_s, conceal_pct, reason,
                mouth_to_ear_ms, glass_to_glass_ms, human_gap_ms
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
        failReasons: rows.filter((r) => r.evt === 'fail').reduce((m: Record<string, number>, r) => {
          const k = String(r.reason ?? '-'); m[k] = (m[k] ?? 0) + 1; return m;
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
    // Operator-only: which rooms were live, when. Gated inside the DO on
    // LOG_ADMIN_TOKEN — the credential that already reads any room's log.
    if (url.pathname === '/api/health/rooms' && request.method === 'GET') {
      return env.HEALTH.get(env.HEALTH.idFromName('global')).fetch(
        new Request(`https://do/rooms${url.search}`),
      );
    }

    // /api/room/:code/ws | /api/room/:code/log | /api/room/:code/summary
    const m = url.pathname.match(/^\/api\/room\/([^/]+)\/(ws|log|summary|xlate)$/);
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
