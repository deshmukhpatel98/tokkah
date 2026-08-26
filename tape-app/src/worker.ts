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
  MAC_DASH_KEY?: string;
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
    // ── The doorbell. THESE MUST RETURN BEFORE signal() BELOW. ───────────────
    // signal() answers 426 "expected websocket" to anything without an upgrade
    // header, so a handler added after the fallthrough is inert behind a
    // perfectly plausible-looking log line. Under this DO name ("inbox:<handle>")
    // there is no call and no socket — only a mailbox.
    if (url.pathname.endsWith('/kin/register')) return this.kinRegister(request, url);
    if (url.pathname.endsWith('/kin/ring')) return this.kinRing(request, url);
    // `request.signal` travels because a held poll has to know when the client
    // it is holding for has gone away — see kinHold. Every other verb answers
    // at once and has no use for it.
    if (url.pathname.endsWith('/kin/poll')) return this.kinPoll(url, request.signal);
    if (url.pathname.endsWith('/kin/quiet')) return this.kinQuietSet(request, url);
    return this.signal(request);
  }

  // ── Mailbox state: in memory, exactly like rvPeers above ──────────────────
  //
  // Keyed by handle even though this DO is already per-handle: it keeps the pure
  // functions general enough to test, and a misrouted request lands in a key
  // nobody polls instead of in somebody else's mailbox.
  private kinBox = new Map<string, KinStored[]>();
  // One map for every in-DO window (pair:, to:, poll:, bad:, reg:). Distinct key
  // prefixes mean the budgets cannot spend each other.
  private kinHits = new Map<string, number[]>();
  // The poll credential, cached after the first read. Register is first-writer-
  // wins so this value never changes once set, which makes the cache safe and
  // takes a storage read off the 5 s poll path. Cached on HIT only — a miss must
  // stay re-readable, because a register may land later.
  // NOT cached the way kinTok was before proof-of-possession: `tok` is now
  // refreshable by the owning device, so a cached copy can go stale within the
  // isolate's life. Only the HIT is cached, and only after a write updates it —
  // see kinTokLoad.
  private kinTok: string | null = null;
  // The device key that owns this mailbox, canonical base64. Unlike `tok` this
  // one really is write-once, so caching a hit is safe forever.
  private kinKey: string | null = null;
  // The silent-mode row. THREE STATES, and the third is why this one is not
  // `KinQuiet | null`: `undefined` is "not read yet", `null` is "read, nothing
  // stored". A toggle can be turned OFF, so "falsy" and "unknown" are different
  // facts here in a way they never were for `tok` — collapsing them would make
  // every ring re-read storage after silence was lifted.
  //
  // Safe to cache both ways because this DO is the only writer of its own row:
  // kinQuietSet updates the cache in the same turn it writes.
  private kinQuiet: KinQuiet | null | undefined = undefined;
  // Rings silenced since this object woke. A count for the owner's own poll, not
  // a ledger: it resets with the isolate, and the device keeps the real list.
  private kinMuted = 0;
  // ── THE HELD POLLS ────────────────────────────────────────────────────────
  //
  // Callees parked on a GET that has not been answered yet, keyed by handle for
  // the same reason kinBox is: a misrouted request waits on a key nobody rings
  // rather than on somebody else's doorbell.
  //
  // In memory and nowhere else, deliberately. A waiter is a live connection held
  // by this isolate; persisting one would outlive the thing it describes, which
  // is the rvPeers argument verbatim. If the isolate dies the connections die
  // with it and every client re-arms — nothing to reconcile.
  // The stored function is the waiter's own `finish`, which takes WHETHER A RING
  // WOKE IT — because that boolean is what decides whether the mailbox gets
  // drained. Storing a bare `() => finish(true)` here would make eviction
  // impossible to express: every way of ending a hold would be a delivery.
  private kinWaiters = new Map<string, Set<(woke: boolean) => void>>();

  /**
   * When each handle was last HEARD FROM. Not "does it hold a socket" — this
   * project has a rule about that, learned from ghost sockets holding room
   * slots: liveness is last-heard-from, never readyState. A resident that polls
   * plainly every four seconds holds nothing between polls and is perfectly
   * alive; a held poll that a killed process left behind holds a socket and is
   * not.
   *
   * In memory only, and that is why the answer below has THREE states rather
   * than two. A Durable Object that has just woken has never heard from
   * anybody, and reporting that as "they are offline" would be a confident lie
   * told to every caller after every eviction.
   */
  private kinLastPoll = new Map<string, number>();
  // How many are held right now, across every handle this object serves (one).
  // Read by kinPollDecide as the concurrency cap; see KIN_WAIT_MAX_PARKED.
  private kinParked = 0;

  private async kinTokLoad(): Promise<string | null> {
    if (this.kinTok !== null) return this.kinTok;
    const v = await this.state.storage.get<string>('kin_tok');
    if (v) this.kinTok = v;
    return v ?? null;
  }

  private async kinKeyLoad(): Promise<string | null> {
    if (this.kinKey !== null) return this.kinKey;
    const v = await this.state.storage.get<string>('kin_key');
    if (v) this.kinKey = v;
    return v ?? null;
  }

  private async kinQuietLoad(): Promise<KinQuiet | null> {
    if (this.kinQuiet !== undefined) return this.kinQuiet;
    const v = await this.state.storage.get<KinQuiet>('kin_quiet');
    this.kinQuiet = v ?? null;
    return this.kinQuiet;
  }

  private async kinRegister(request: Request, url: URL): Promise<Response> {
    if (request.method !== 'POST') return json({ error: 'method' }, 405);
    const raw = await request.text();
    const have = await this.kinTokLoad();
    const haveKey = await this.kinKeyLoad();
    const d = await kinRegisterDecide(
      raw, url.searchParams.get('to') ?? '', have, haveKey, this.kinHits, Date.now(),
    );
    // ONE write for both rows. A separate put per key could land the credential
    // without the key that owns it, and a mailbox holding a `tok` with no `k` is
    // precisely the legacy shape kinRegisterDecide has to treat as suspect.
    const row: Record<string, string> = {};
    if (d.put !== undefined) row.kin_tok = d.put;
    if (d.putKey !== undefined) row.kin_key = d.putKey;
    if (Object.keys(row).length) {
      await this.state.storage.put(row);
      if (d.put !== undefined) this.kinTok = d.put;
      if (d.putKey !== undefined) this.kinKey = d.putKey;
    }
    return json(d.body, d.status);
  }

  private async kinRing(request: Request, url: URL): Promise<Response> {
    if (request.method !== 'POST') return json({ error: 'method' }, 405);
    const raw = await request.text();
    // The silent-mode row is loaded for EVERY ring (cached after the first, and
    // this DO is its only writer). Without it kinRingDecide defaults to
    // not-silent and the toggle is a dead control — the shape this project has
    // shipped three times.
    const quiet = await this.kinQuietLoad();
    const to = url.searchParams.get('to') ?? '';
    // A held poll in flight is proof on its own -- the client is on the other
    // end of a socket we are holding open right now -- and otherwise fall back
    // to when we last heard from it. Either is evidence; neither is a guess.
    const nowMs = Date.now();
    const held = (this.kinWaiters.get(to)?.size ?? 0) > 0;
    const last = this.kinLastPoll.get(to);
    const heardMs = held ? 0 : (last === undefined ? null : nowMs - last);
    const d = kinRingDecide(raw, to, this.kinBox, this.kinHits, nowMs, quiet, heardMs);
    // Counted here and NOWHERE IN THE RESPONSE. `d.muted` must never reach the
    // caller; only the owner's poll sees this number.
    if (d.muted) this.kinMuted++;
    // THE DOORBELL RINGS HERE, and only for a ring that will actually be handed
    // over: 200 means it is in the mailbox, and `muted` means it will be thrown
    // away at the drain. Waking a held poll for a silenced ring would end the
    // callee's wait to give them nothing, and would let a caller who keeps
    // ringing a silenced handle keep that wait ending — denial of sleep rebuilt
    // out of the silence switch. This line is also completely invisible to the
    // caller: the response was already decided above.
    if (d.status === 200 && !d.muted) this.kinWake(to);
    return json(d.body, d.status);
  }

  private async kinPoll(url: URL, signal?: AbortSignal): Promise<Response> {
    const to = url.searchParams.get('to') ?? '';
    const tok = url.searchParams.get('tok') ?? '';
    const waitMs = kinWaitMs(url.searchParams.get('wait'));
    const quiet = await this.kinQuietLoad();
    const d = kinPollDecide(
      to, tok, await this.kinTokLoad(),
      this.kinBox, this.kinHits, Date.now(), quiet, this.kinMuted,
      waitMs, this.kinParked,
    );
    // ── A POLL PROVES A CLIENT IS ALIVE, SO IT EVICTS THE ONES THAT MIGHT NOT
    //    BE ────────────────────────────────────────────────────────────────
    //
    // Only after the credential passed (status 200), or this would be an
    // unauthenticated way to make somebody's doorbell slow: anyone who knew a
    // handle could keep evicting its waiter.
    //
    // The arriving request is proof of life, so bank it before doing anything
    // else with it: this is the only fact that can later tell a caller their
    // ring went nowhere.
    if (d.status === 200) this.kinLastPoll.set(to, Date.now());
    // The request that just arrived is the only client we have PROOF is alive
    // right now. Anything still parked is a client we merely have not heard
    // from, and one of those is exactly what loses a call: a killed app's waiter
    // is woken by the next ring, drains the mailbox destructively, writes the
    // ring to a socket nobody is reading, and the listener that IS alive wakes
    // to an empty box. Measured directly — kill the app mid-hold, ring the
    // handle, and the menu-bar resident received nothing.
    //
    // `request.signal` looked like the answer and is not: it does not fire
    // through a dev proxy, and a laptop closing its lid never sends anything at
    // all. So liveness is inferred from the only evidence that cannot be faked
    // by a dead process — a request arriving. Eviction NEVER drains: an evicted
    // waiter finishes `false`, which is the 204 path.
    if (d.status === 200) this.kinEvict(to);
    if (!d.park) return json(d.body, d.status);
    // Held. Everything above — format, credential, rate — has already been
    // decided and paid for, so the wake path below must NOT re-run any of it:
    // it builds the body and nothing else. That is the whole reason
    // kinPollBody is a separate function.
    const t0 = Date.now();
    if (await this.kinHold(to, waitMs, signal)) {
      return json(kinPollBody(to, this.kinBox, Date.now(), quiet, this.kinMuted, Date.now() - t0));
    }
    // Nothing came. 204 and not an empty 200: it is the cheapest possible way
    // to say "still nothing", it cannot be confused with a ring, and — because
    // no older worker has ever produced one on this route — it is also the
    // client's proof that this server really held the line.
    return new Response(null, { status: 204 });
  }

  /**
   * Hold a poll open until somebody rings, until the client goes away, or until
   * the deadline. True ONLY if a ring woke it — and that return value is what
   * decides whether the mailbox gets drained, which makes it the most dangerous
   * boolean in this file.
   *
   * ── A DEAD CLIENT MUST NOT BE HANDED A RING ────────────────────────────────
   *
   * `open-socket-is-not-a-live-peer`, and it bit again here. The drain is
   * destructive, so a waiter belonging to a process that has already been killed
   * takes the ring, writes it to a socket nobody is reading, and it is gone —
   * the OTHER listener on the same handle then wakes to an empty mailbox and the
   * call is simply lost. Observed directly: kill the app while its poll is
   * parked, ring the handle, and the menu-bar resident received nothing.
   *
   * `signal` is what closes that. Workers aborts an in-flight request when the
   * client disconnects, so an abandoned waiter deregisters itself instead of
   * waiting to be woken. It resolves FALSE, which is the whole point: a hold
   * that ended for any reason other than a ring must not drain anything.
   *
   * THE DEADLINE IS STILL NOT OPTIONAL. Abort is a best-effort signal and a
   * client can vanish without one — a laptop whose lid closes sends nothing. The
   * timer is the only thing guaranteed to end such a request, which is why every
   * exit path goes through `finish` and why `finish` is idempotent: a waiter
   * that is woken and then also times out must not decrement kinParked twice, or
   * the concurrency cap drifts negative and stops capping anything.
   */
  private kinHold(to: string, waitMs: number, signal?: AbortSignal): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let timer: ReturnType<typeof setTimeout>;
      let done = false;
      const finish = (woke: boolean) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        signal?.removeEventListener('abort', gone);
        const set = this.kinWaiters.get(to);
        if (set) { set.delete(finish); if (!set.size) this.kinWaiters.delete(to); }
        this.kinParked--;
        resolve(woke);
      };
      const gone = () => finish(false);
      timer = setTimeout(() => finish(false), waitMs);
      let set = this.kinWaiters.get(to);
      if (!set) { set = new Set(); this.kinWaiters.set(to, set); }
      set.add(finish);
      this.kinParked++;
      // REGISTERED FIRST, then checked. `finish` decrements the parked count, so
      // an early return before the increment above leaves the cap counting down
      // past zero — a concurrency limit that stops limiting after a few
      // already-dead clients, which is worse than not having one.
      if (signal?.aborted) { finish(false); return; }
      signal?.addEventListener('abort', gone);
    });
  }

  /**
   * Somebody rang. Release ONE held poll, and specifically the newest.
   *
   * Not all of them, and the reason is the whole hazard of this design: the
   * woken poll DRAINS THE MAILBOX, so waking two hands the ring to whichever
   * resolves first and gives the other an empty box. One delivery is the
   * correct number, and the newest waiter is the client we heard from most
   * recently — the one most likely to still be there to receive it.
   *
   * A Set iterates in insertion order, so the last entry is the newest.
   */
  private kinWake(to: string): void {
    const set = this.kinWaiters.get(to);
    if (!set?.size) return;
    let newest: ((woke: boolean) => void) | undefined;
    for (const finish of set) newest = finish;
    newest?.(true);
  }

  /**
   * End every held poll for `to` WITHOUT draining anything, because a live
   * client has just been heard from and the parked ones may be ghosts. See the
   * block at the call site in kinPoll: this is what stops a killed process's
   * waiter from swallowing the next ring.
   */
  private kinEvict(to: string): void {
    const set = this.kinWaiters.get(to);
    if (!set) return;
    // Snapshotted and cleared BEFORE calling anything: each `fire` mutates this
    // same set on its way out, and iterating a collection while its members
    // remove themselves from it is how an eviction silently skips a waiter.
    this.kinWaiters.delete(to);
    // FALSE, and that is the entire point: an evicted hold ends on the 204 path
    // and takes nothing out of the mailbox. `true` here would turn the fix into
    // the bug — every eviction would swallow a ring.
    for (const finish of [...set]) finish(false);
  }

  private async kinQuietSet(request: Request, url: URL): Promise<Response> {
    if (request.method !== 'POST') return json({ error: 'method' }, 405);
    const raw = await request.text();
    const d = await kinQuietDecide(
      raw, url.searchParams.get('to') ?? '', await this.kinKeyLoad(), this.kinHits, Date.now(),
    );
    if (d.putQuiet !== undefined) {
      await this.state.storage.put('kin_quiet', d.putQuiet);
      // The cache MUST be refreshed here, or the next ring in this isolate reads
      // the value from before the toggle and rings a phone that was just
      // silenced — a durable write that looks like it worked and did nothing.
      this.kinQuiet = d.putQuiet;
    }
    return json(d.body, d.status);
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
  private rvPeers = new Map<string, { addr: string; local?: string; relay?: string; at: number }>();

  private rendezvous(url: URL): Response {
    const me = url.searchParams.get('me') ?? '';
    const addr = url.searchParams.get('addr') ?? '';
    const now = Date.now();
    // 90 s: long enough to survive a slow start on the far side, short enough
    // that a stale mapping is never offered as a live one.
    for (const [k, v] of this.rvPeers) if (now - v.at > 90_000) this.rvPeers.delete(k);
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(me)) return json({ error: 'bad me' }, 400);
    const local = url.searchParams.get('local') ?? '';
    const relay = url.searchParams.get('relay') ?? '';
    const addrOk = (a: string) => /^\d{1,3}(\.\d{1,3}){3}:\d{1,5}$/.test(a);
    if (addr) {
      if (!addrOk(addr)) return json({ error: 'bad addr' }, 400);
      if (local && !addrOk(local)) return json({ error: 'bad local' }, 400);
      if (relay && !addrOk(relay)) return json({ error: 'bad relay' }, 400);
      // The LAN address travels too. Two machines behind one NAT should talk over
      // the LAN: it is a shorter path, and reaching your own public address from
      // inside requires NAT hairpinning that many routers refuse outright. The
      // client compares public IPs and picks; this only carries both.
      // `relay` is this machine's TURN-allocated address — the short path on a
      // long call, raced against STUN and LAN by measured RTT.
      this.rvPeers.set(me, { addr, local: local || undefined, relay: relay || undefined, at: now });
    }
    const others = [...this.rvPeers.entries()]
      .filter(([k]) => k !== me)
      .map(([k, v]) => ({ id: k, addr: v.addr, local: v.local, relay: v.relay, ageMs: now - v.at }));
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

// ═══════════════════════════════════════════════════════════════════════════════
// "TAP A NAME TO CALL" — THE DOORBELL  (CONTACTS.md §4/§5, build step 2)
// ═══════════════════════════════════════════════════════════════════════════════
//
// One device rings another BY HANDLE; the callee's app polls for rings. That is
// the entire server half of the contact feature, and it is deliberately the
// smallest thing that could work: no presence, no roster, no message store.
//
//   POST /api/kin/<handle>/register   {to, tok, k, t, sig}       → claim the mailbox
//   POST /api/kin/<handle>/ring       {to, from, room, t, sig, k} → ring it
//   GET  /api/kin/<handle>/poll?tok=  →                             drain it
//   POST /api/kin/<handle>/quiet      {to, k, t, sig, quiet, until} → silence it
//
// TWO SIGNATURES, TWO COMPLETELY DIFFERENT JOBS, and confusing them is the
// mistake this section is arranged to prevent:
//
//   · register.sig  IS verified here, by us, against register.k. It is the only
//     thing standing between a person and someone taking their name. See
//     kinRegisterDecide.
//   · ring.sig      is NEVER verified here. It is stored and handed back.
//
// ── THE SERVER DOES NOT VERIFY THE RING SIGNATURE. THIS IS THE DESIGN. ───────
//
//   ring.sig = Ed25519(callerDevicePriv, "ring|" + to + "|" + from + "|" + room + "|" + t)
//   ring.k   = the caller's 32-byte Ed25519 public key, base64
//
// The CALLEE verifies it: it looks `k` up in its own contact list and drops,
// silently, any ring whose key it does not already know or whose signature does
// not check out. The server holds no contact list and cannot tell whether a key
// is welcome, so it stores the bytes and hands them back.
//
// That is the whole security model, not a hole in it: a stranger who guesses a
// handle can write into a mailbox and can NEVER make a Mac ring. Do NOT
// "improve" this into server-side verification — a server that could verify a
// ring is a server that could FORGE one, which would turn a mailbox into an
// identity authority and hand whoever runs it the power to ring anybody as
// anybody. `k` arriving in the ring does not change that: an attacker is free to
// present a key of their own, and it is the callee's list, not our arithmetic,
// that says whose keys count.
//
// ── HANDLE FORMAT ────────────────────────────────────────────────────────────
//
// A handle is a NAME, not a hash: short, lowercase, human-readable, and read
// aloud without spelling it. `devesh`. It is assigned by the machine at first
// launch from the Mac's short username, silently, walking a collision ladder
// (devesh → deveshp → devesh2 → …) until a register succeeds.
//
// 2–32 chars, must START WITH A LETTER, then lowercase letters and digits. No
// hyphens or underscores for now — a separator is the one thing that cannot be
// added later without ambiguity (is `a-b` a new handle or the old `ab`?), so it
// stays out until there is a reason.
//
// THE PRICE OF READABLE NAMES, stated plainly: the namespace is now guessable.
// The 26-char hash this replaced was 130 bits and unguessable, and that
// unguessability was doing real work — it was the ONLY thing standing between a
// stranger and someone's mailbox. Readable names delete that protection, which
// is exactly why register now demands a proof-of-possession signature (see
// kinRegisterDecide). Without that signature this format would hand `devesh` to
// whoever sent the first HTTP request. Do not loosen one without the other.
//
// Note this format satisfies ROOM_RE above for free, so a handle is also a
// legal room code — which is why `room` in a ring is checked against ROOM_RE
// and nothing stricter.
export const KIN_HANDLE_RE = /^[a-z][a-z0-9]{1,31}$/;
// Must agree with KIN_HANDLE_RE, CHARACTER CLASS FOR CHARACTER CLASS. The DO
// re-validates with KIN_HANDLE_RE anyway, so if these two ever drift the DO is
// the authority and the edge is only a prefilter — but a one-character
// disagreement between them is a 404 nobody can explain, because the request
// never reaches the code that would have said why.
//
// The verb is always the LAST of four fixed segments and the capture group
// cannot contain a slash, so a handle that happens to spell a verb is
// unambiguous: /api/kin/register/ring is handle `register`, verb `ring`. No
// reserved-word list, on purpose — someone's Mac account really is called
// `poll`, and silently refusing them their own name would be a bug we could
// not see. Asserted in contacts.test.mjs (b3).
export const KIN_ROUTE_RE = /^\/api\/kin\/([a-z][a-z0-9]{1,31})\/(register|ring|poll|quiet)$/;
// tok = SHA256("tk-inbox-v1" | devicePriv), lowercase hex.
const KIN_TOK_RE = /^[a-f0-9]{64}$/;
// A ring's `sig` is the caller's Ed25519 signature over the ring, 64 bytes = 88
// chars of base64. The range tolerates url-safe/unpadded spellings without ever
// letting `sig` become a payload channel. THE SERVER NEVER VERIFIES IT — see the
// block at the top of this section; only the callee holds the caller's key.
const KIN_SIG_RE = /^[A-Za-z0-9+/=_-]{40,96}$/;
// An Ed25519 public key is 32 raw bytes: 44 chars of base64 with padding, 43
// without. Exact length, because unlike `sig` this one IS decoded and used.
const KIN_KEY_RE = /^[A-Za-z0-9+/_-]{43}=?$/;
// A registration signature is 64 raw bytes: 88 chars padded, 86 without. Exact,
// so junk is refused by a regex instead of by the curve — an attacker should not
// get to spend our CPU on 96 characters of garbage.
const KIN_REG_SIG_RE = /^[A-Za-z0-9+/_-]{86}(==)?$/;

// A ring's `t` is UNIX SECONDS, and it is the client's own clock. |now − t| > 60 s
// is refused BEFORE anything else is looked at, because without that gate a
// captured ring replays forever — the sig is a fixed string over fixed inputs,
// so replay protection has to come from the timestamp or from nowhere.
const KIN_SKEW_S = 60;
// Mailbox lease, mirroring rvPeers' 90 s (see the block above rendezvous()):
// "an address is only true while the binding is alive" applies verbatim to a
// ring. A ring is only true while the caller is still sitting there waiting, so
// a stale ring is worse than no ring — it rings a phantom and the callee
// answers nobody. Shorter than the rendezvous lease on purpose: rendezvous has
// to survive a slow start on the far side, a doorbell does not.
const KIN_LEASE_MS = 60_000;
const KIN_BOX_MAX = 8;                 // rings held per handle

// ── THE RING BUDGET, and what each number is actually buying ─────────────────
//
// The shipped numbers were 6/min per (from,to), 30/min per `to`, 240/h per IP.
// The per-pair cap was worthless: `from` is unauthenticated and free to mint, so
// 100 invented `from`s bought 600 rings/min. The only real cap was 30/min per
// `to` — a phone ringing every two seconds, forever, for free. That is not a
// doorbell, it is a denial-of-sleep budget.
//
// HONEST LIMITATION, so nobody reads more into these than they hold: keying on
// the caller's device key `k` is NOT cryptographically stronger than keying on
// `from`, because the server verifies neither and 32 random bytes are as free to
// mint as a handle. What keying on `k` does buy is alignment: `k` is the
// identity the CALLEE authorizes on, so the per-caller window now limits the
// entity that can actually make a screen light up, instead of limiting a string
// nobody checks. Both windows are kept — a flooder must mint both to get past
// either, and neither raises the other's ceiling.
//
// THE BACKSTOP IS THE PER-`to` PAIR, and it is a pair on purpose. A per-minute
// cap alone cannot bound denial of sleep: 12/min sustained is 17,280 rings a
// day. So the minute cap bounds BURSTINESS and the hour cap bounds TOTAL.
//
// The strict rule — "only people I know may ring me" — CANNOT live here. The
// server has no contact list and must never have one: it would have to be told
// who each person knows, which is the entire social graph, to enforce a rule the
// callee can enforce for free by dropping any ring whose `k` is not in its own
// list. These numbers only bound what reaches the mailbox; what reaches the
// SCREEN is the client's decision, and that is where the real gate lives.
const KIN_RING_PER_KEY = 4;            // per (k,to) per minute — the caller's DEVICE
const KIN_RING_PER_FROM = 4;           // per (from,to) per minute — the mintable name
const KIN_RING_PER_TO = 12;            // per `to` per minute (was 30), from anyone
const KIN_RING_PER_TO_HOUR = 60;       // per `to` per hour — the denial-of-sleep bound
const KIN_REG_PER_MIN = 10;            // register/refresh per handle per minute
const KIN_POLL_GAP_MS = 2000;          // ≤1 poll per 2 s per handle
const KIN_BAD_AUTH_PER_MIN = 30;       // failed polls per handle per minute

// ── THE LONG POLL, AND WHAT BOUNDS IT ────────────────────────────────────────
//
// A 5 s poll means a doorbell that takes 2.5 s on average to make a noise, and
// a phone rings in well under one second. So the callee's GET is HELD by the
// Durable Object until a ring lands, and the mean ring latency stops being half
// a poll interval and becomes one round trip. Measured through two real `tk`
// processes against a local worker, same binary both arms, n=12 each:
// median 2794 ms before, 18 ms after.
//
// ── WHY LONG POLL AND NOT THE HIBERNATABLE WEBSOCKET RINGING.md PICKS ───────
//
// RINGING.md rejects this option on cost: "a parked request cannot hibernate",
// therefore $4.15/user/month of Durable Object duration. That reasoning is
// sound and its premise is incomplete, and the correction is in the same
// document, four lines above the table it appears in:
//
//   "DO stays resident after last request >= 120 s
//    (5/10/20/30/45/60/90/120 s gaps: 119-316 ms, never cold)"
//
// A poll every 5 s therefore NEVER lets the object go cold. The deployed
// 5-second poll is already paying the whole duration bill that table charges
// only to long polling, and has been all along; the table prices that row by
// requests and this one by duration, which is why they look like different
// orders of magnitude. Compared like for like against what actually ships,
// holding the request costs the SAME duration and FEWER REQUESTS: the client's
// steady state is three 25 s holds and one plain re-read per cycle, so 4
// requests per 75 s is ~138k per user per month against 518k, both inside the
// 1M free tier. It is strictly cheaper than the thing it replaces.
//
// The hibernatable WebSocket is still the right end state and is still the only
// option that makes an IDLE user free. It needs a new DO class, a keepalive, a
// reconnect ladder and a presence state machine -- none of which this needs,
// and all of which sit on the path a live call's signalling shares. Long poll
// gets the latency now at no extra cost over today; hibernation is a COST
// project, not a latency one, and should be measured as one.
//
// ── HOW MANY HELD REQUESTS ONE PERSON CAN CAUSE, AND WHAT STOPS IT GROWING ──
//
// Four. Per handle, and a handle costs a proof-of-possession registration to
// own, so "one person" is "one registered mailbox".
//
//   · The app holds ONE at a time: it arms, waits, and re-arms only after the
//     previous one returned. Steady state is 1. When the menu-bar resident is
//     running too, it STANDS DOWN while the app is open (Identity.claimLine on
//     the Swift side), so two processes still hold one line between them.
//   · KIN_WAIT_GAP_MS caps ARMING at one per second per handle, so nothing can
//     accumulate faster than one held request per second...
//   · ...and KIN_WAIT_MAX_PARKED caps CONCURRENCY at four, which is the bound
//     that actually holds: a rate limit cannot bound a thing that lives for
//     25 s. The fifth arming does not park and does not fail -- it answers
//     immediately, exactly like today's poll.
//   · Every park has a hard deadline (KIN_WAIT_MAX_MS). A client that sleeps,
//     crashes or is unplugged costs at most one deadline, because the timer
//     fires whether or not anybody is still listening -- there is no state that
//     survives a vanished client and nothing to reap later.
//   · The per-IP edge window (KIN_EDGE_CAP.poll) bounds the rate underneath all
//     of this and is untouched.
//
const KIN_WAIT_MIN_MS = 1000;          // shorter than this is not a wait; answer now
const KIN_WAIT_MAX_MS = 30_000;        // hard deadline on any held request
const KIN_WAIT_GAP_MS = 1000;          // ≤1 arming per second per handle
const KIN_WAIT_MAX_PARKED = 4;         // held requests per handle, all clients
const KIN_RING_MAX_BODY = 1024;
const KIN_REG_MAX_BODY = 512;
// A ring carries exactly these six fields and no others. A lax mailbox would
// be an unauthenticated write channel into the callee's JSON parser — anyone
// who guesses a handle could post arbitrary shapes at a Mac. Strict allowlist,
// same reasoning as the health-beat ingest.
//
// `k` is the caller's 32-byte Ed25519 public key, and it is the field the whole
// feature turns on: the callee looks `k` up in its own contact list, verifies
// `sig` against it, and rings only if both hold. It rides in the ring because
// the callee cannot ask anyone else for it.
// ── ONE OPTIONAL FIELD, AND WHY THE SET IS NOW A FLOOR AND A CEILING ────────
//
// A ring was one-directional: the caller drops a note in the callee's mailbox and
// that is the whole conversation. So a callee who pressed `decline` had no way to
// say so, and the caller sat on "Calling Meera" until a 45 s timeout. Reported
// from a real call as "it just kept showing calling, forever".
//
// `kind: 'bye'` is that word, sent the same way and down the same pipe: a bye is
// a ring in reverse. It is OPTIONAL, so every existing client keeps sending six
// keys and keeps working, and a server that has this deployed is compatible with
// an app that does not — which matters because the app updates on its own
// schedule and the server updates now.
const KIN_RING_KEYS = new Set(['to', 'from', 'room', 'sig', 't', 'k']);
const KIN_RING_OPTIONAL = new Set(['kind']);
const KIN_KINDS = new Set(['bye']);
// The exact string a registration signature covers. Version-prefixed and
// field-separated so a signature can never be replayed into a different
// meaning: no field may contain '|' (handle and tok are checked by regex, `t` is
// a number), so the concatenation is unambiguous.
// NOT EXPORTED, and neither is KIN_QUIET_CONTEXT below. This module is the
// worker ENTRY, so every named export is an entrypoint as far as workerd is
// concerned — and a STRING export is not "a function or ExportedHandler", so
// the runtime refuses to start at all. Adding `export` to this line is a
// DEPLOY-BREAKING change that typechecks perfectly; contacts.test.mjs (k)
// caught it in miniflare. RegExps and Sets survive because they are objects, so
// the existing exported regexes prove nothing about this line. The tests read
// both context strings out of the source text instead.
const KIN_REG_CONTEXT = 'kin-reg-v1|';

// ── SILENT MODE: "if that is enabled, no one can call you" ───────────────────
//
// The user's own words. One toggle on the callee's device, and rings stop
// arriving. What follows is the server half.
//
// ── THE SERVER IS AN OPTIMISATION, NOT THE SECURITY BOUNDARY ────────────────
//
// The CLIENT enforces silent mode locally: the callee's app knows its own state
// and refuses to ring the screen regardless of what this mailbox does. That is
// deliberate and it is the load-bearing half — everything here can be bypassed
// by a mailbox that has not learned the toggle yet (a client that set it while
// offline), by an isolate that has just started, or by a deploy that drops this
// code. What the server buys is that the callee's Mac never wakes for a call it
// was never going to show. DO NOT move a security decision here on the strength
// of it, and do not remove the client-side check on the strength of this one.
//
// ── INVARIANT 1: SILENT MUST BE INDISTINGUISHABLE FROM AWAY ─────────────────
//
// A caller must not be able to tell "she has silenced her phone" from "her Mac
// is shut". Telling them is worse than silence: it converts a quiet no into a
// social fact, and it is a fact about the callee that the caller is not owed.
//
// So a ring to a silent handle returns EXACTLY what a ring to a handle nobody
// polls returns — same status, same body, same fields, same numbers, over a
// whole SEQUENCE of rings and not merely on the first one. The way that is
// achieved is the important part, because the obvious implementation breaks it:
//
//   The obvious implementation — "if silent, return early with ok:true" —
//   FABRICATES the response. `queued` then stops tracking the mailbox, so a
//   caller who rings twice reads 1,1 from a silent handle and 1,2 from an absent
//   one, and the toggle is legible from the outside after two doorbell presses.
//
// Instead a silenced ring travels the ENTIRE normal path: every validation, every
// rate window, the same kinBoxPut, the same response line. The only difference is
// one flag on the stored ring (`mute`), and poll drops flagged rings before the
// callee ever sees them. The indistinguishability is then STRUCTURAL — the two
// responses are produced by the same code — rather than a pair of literals two
// people have to keep in sync.
//
// Consequences of that choice, stated so nobody "tidies" them away:
//   · a silenced ring occupies a mailbox slot for its 60 s lease. Bounded at 8,
//     in memory, and evict-oldest means a real ring arriving after the toggle
//     goes off still lands. Cheaper than a legible toggle.
//   · silenced rings still spend the caller's rate budget. That is REQUIRED: a
//     silent handle that stopped 429ing would be legible from the outside.
//   · silence is decided at ARRIVAL. A ring that came in during silence stays
//     undelivered even if the deadline passes a second later — the doorbell was
//     silenced when it was pressed.
//
// ── NO ALLOWLIST IN v1 ──────────────────────────────────────────────────────
//
// Silent means silent. `exceptKnown` exists in the stored shape so a later
// client can carry "except people I know" without a storage migration, and it
// is ALWAYS false today: there is no wire field for it, the server has no
// contact list, and caller classification belongs on the device that holds one.
// WHEN THAT FIELD IS ADDED IT MUST JOIN THE SIGNED STRING and the context must
// become kin-quiet-v2 — a field that changes behaviour and is not signed is a
// field an attacker flips by replaying a captured signature.
const KIN_QUIET_CONTEXT = 'kin-quiet-v1|';
// Its own domain string, NOT KIN_REG_CONTEXT. A signature is a statement about
// one operation; two operations that share a prefix are one input coincidence
// away from a signature valid for the first being replayable as the second.
// Cheap to separate now, impossible to separate after clients ship.
const KIN_QUIET_KEYS = new Set(['to', 'k', 't', 'sig', 'quiet', 'until']);
const KIN_QUIET_MAX_BODY = 512;
// A human presses this a few times a day. Charged only to attempts that already
// carry the OWNING key, so a stranger cannot lock the owner out of their own
// toggle (the same split as poll's bad: window, and the same reason).
const KIN_QUIET_PER_MIN = 6;
// The outer bound on `until`, ~10 years. Its job is not policy — indefinite is
// spelled `until: 0` — it is to turn "the client sent milliseconds" into a 400
// instead of into a mute lasting 57,000 years, which is indistinguishable from
// indefinite and therefore invisible.
//
// IT IS ALSO THE GATE THAT CATCHES 1e21, and that is not a nicety. The integer
// check does NOT catch it: Number.isInteger(1e21) is TRUE, and 1e21 stringifies
// as "1e+21" — a spelling no Swift client will reproduce, so the signature would
// verify on the device and never here. On `t` the SKEW gate catches that shape
// (measured: it answers `skew`, not `bad t`). `until` has no skew gate, so this
// horizon is the only thing standing there. Removing it re-opens the class.
const KIN_QUIET_MAX_S = 315_360_000;

/**
 * The stored toggle. `until` is UNIX SECONDS and 0 means indefinite.
 *
 * EVALUATED AT READ TIME, never swept: an expired deadline just reads as
 * not-silent. A sweep would need an alarm, and an alarm that does not fire (a
 * cold object, a failed deploy) leaves someone silently unreachable — the exact
 * failure this feature must not have.
 */
export interface KinQuiet {
  quiet: boolean;       // the toggle as the owning device last set it
  until: number;        // unix seconds deadline, 0 = indefinite
  exceptKnown: boolean; // reserved; always false in v1, see the block above
  at: number;           // server receipt ms, for support questions only
}

export interface KinRing {
  to: string; from: string; room: string; t: number; sig: string; k: string;
  /// Absent on an ordinary ring. 'bye' means the sender is no longer calling —
  /// they declined, or they hung up before the other side answered.
  kind?: string;
}
export interface KinStored extends KinRing {
  at: number;      // server receipt, ms
  bornAt: number;  // min(at, t*1000) — see kinBoxPut
  // Silenced on arrival: stored so the ring response is byte-identical to a
  // live one, never delivered. Absent (not false) on a live ring, so a stored
  // ring is shaped exactly as it was before silent mode existed.
  mute?: boolean;
}
export type KinDecision = {
  status: number; body: Record<string, unknown>;
  put?: string;      // kin_tok to persist
  putKey?: string;   // kin_key to persist, canonical base64
  putQuiet?: KinQuiet; // kin_quiet to persist
  // Out-of-band, deliberately NOT in `body`: the ring was silenced. The DO
  // counts these; the caller must never be told. If this ever appears in a
  // response body, invariant 1 is broken.
  muted?: boolean;
  // Out-of-band as well: this poll asked to wait, the mailbox is empty, and the
  // Durable Object should HOLD the request rather than answer it. `body` is
  // empty on purpose when this is set — see the comment at the return site.
  park?: boolean;
};

/**
 * Is this handle silent right now? The ONLY place the toggle is interpreted.
 *
 * Read-time expiry, so the same stored row answers differently at two clocks
 * and nothing has to run in between.
 */
export function kinQuietActive(q: KinQuiet | null | undefined, now: number): boolean {
  if (!q || !q.quiet) return false;
  // `until` is seconds, `now` is ms. Multiply rather than divide: integer
  // arithmetic has one answer, and a deadline that lands half a millisecond
  // early is a toggle that lies about itself at exactly the moment someone
  // looks at it.
  if (q.until && now >= q.until * 1000) return false;
  return true;
}

/**
 * Constant-time string compare for the poll credential. Both sides are fixed
 * 64-char hex so the length check leaks nothing.
 */
export function kinTimingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/**
 * base64 → exactly `wantBytes` bytes, or null. Tolerant of the url-safe
 * alphabet and of missing padding, strict about the DECODED LENGTH — which is
 * the only check that matters, because atob is lenient in ways a regex is not.
 */
export function kinB64(s: string, wantBytes: number): Uint8Array | null {
  let t = s.replace(/-/g, '+').replace(/_/g, '/');
  while (t.length % 4 !== 0) t += '=';
  let bin: string;
  try { bin = atob(t); } catch { return null; }
  if (bin.length !== wantBytes) return null;
  const out = new Uint8Array(wantBytes);
  for (let i = 0; i < wantBytes; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** bytes → canonical standard-alphabet, padded base64. One spelling per key. */
export function kinB64Encode(u8: Uint8Array): string {
  let s = '';
  for (let i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]);
  return btoa(s);
}

export type KinVerify = (pub: Uint8Array, sig: Uint8Array, msg: Uint8Array) => Promise<boolean>;

// WHICH ALGORITHM STRING THE RUNTIME WANTS, and why there are two of them.
//
// Workers has spelled Ed25519 two ways over its life: the legacy
// "NODE-ED25519" (which also insisted on a namedCurve) and the standard
// "Ed25519". CONFIRMED BY PROBE against the workerd binary this project ships
// (miniflare, compatibility_date 2026-05-01 and 2023-01-01 both): all of
// {name:'Ed25519'}, {name:'Ed25519',namedCurve:'Ed25519'} and
// {name:'NODE-ED25519',namedCurve:'NODE-ED25519'} import a raw 32-byte key and
// verify RFC 8032 test vector 1 correctly — returning true for the real
// signature and false for the same signature with one bit flipped. So the
// probe could tell a working verifier from a rubber stamp, which is the only
// version of that check worth running.
//
// 'Ed25519' is therefore first and is what production will use. The legacy
// spelling stays as a fallback because it costs nothing on the happy path (one
// try, then cached for the isolate's life) and because a runtime that has only
// the old name would otherwise fail EVERY registration silently — a whole
// feature dead, with a 401 that blames the user's key.
const KIN_ED_ALGS = ['Ed25519', 'NODE-ED25519'];
let kinEdAlg: string | null = null;

/**
 * Verify a 64-byte Ed25519 signature over `msg` with a raw 32-byte public key.
 *
 * Returns false on ANY failure, including an unusable key — a registration that
 * cannot be proved is refused, never waved through.
 */
export async function kinVerifyEd25519(
  pub: Uint8Array, sig: Uint8Array, msg: Uint8Array,
): Promise<boolean> {
  for (const name of kinEdAlg ? [kinEdAlg] : KIN_ED_ALGS) {
    let key: CryptoKey;
    try {
      key = await crypto.subtle.importKey('raw', pub, { name, namedCurve: name }, false, ['verify']);
    } catch {
      continue;  // wrong spelling for this runtime, or a point not on the curve
    }
    // Import succeeded, so this spelling is the right one for this runtime.
    kinEdAlg = name;
    try { return await crypto.subtle.verify(name, key, sig, msg); } catch { return false; }
  }
  return false;
}

// Sliding-window counters can otherwise grow one key per distinct caller
// forever. Above this many keys, a touch sweeps every dead key out.
const KIN_HITS_MAX_KEYS = 4096;

/**
 * One sliding window, used for every limit in this feature — at the edge per
 * IP and inside the DO per handle and per pair.
 *
 * Returns true if the hit is allowed (and records it), false if the window is
 * full. THE WRITE-BACK ON THE REFUSAL PATH IS LOAD-BEARING: pruning only ever
 * happens here, so a limiter that returns without writing the filtered array
 * back never prunes the caller it just refused — and becomes a permanent ban
 * instead of a window. /api/mac/beat and /api/health both do this write-back;
 * this is the same shape, factored so it is tested once.
 */
export function kinWindow(
  map: Map<string, number[]>, key: string, now: number, windowMs: number, max: number,
): boolean {
  const hits = (map.get(key) ?? []).filter((t) => now - t < windowMs);
  if (hits.length >= max) { map.set(key, hits); return false; }
  hits.push(now);
  map.set(key, hits);
  if (map.size > KIN_HITS_MAX_KEYS) {
    for (const [k, v] of map) if (!v.length || now - v[v.length - 1] >= windowMs) map.delete(k);
  }
  return true;
}

/** Drop every ring past its lease, and forget handles left with none. */
export function kinBoxSweep(box: Map<string, KinStored[]>, now: number): void {
  for (const [k, list] of box) {
    const live = list.filter((r) => now - r.bornAt <= KIN_LEASE_MS);
    if (!live.length) box.delete(k);
    else if (live.length !== list.length) box.set(k, live);
  }
}

/**
 * Put a ring in a mailbox. Sweep-on-touch, like rendezvous().
 *
 * `bornAt` is min(receipt, client stamp): the client's `t` is used only to make
 * a ring SHORTER-lived, never longer, so a lying clock can only hurt the caller
 * who lies. Without it the skew gate (60 s) and the lease (60 s) would stack
 * into 120 s of tolerated staleness.
 *
 * Repeat rings from the same caller for the same room REPLACE each other rather
 * than accumulating — the caller re-rings while it waits, and eight copies of
 * one doorbell press is not eight calls. That is also what makes the cap
 * meaningful.
 *
 * At the cap the OLDEST goes. That direction matters: a jammer holding a leaked
 * handle can fill all eight slots, and evicting the oldest means a genuine ring
 * arriving afterwards still lands, where evicting the newest would let the
 * jammer wall the mailbox off permanently.
 */
export function kinBoxPut(
  box: Map<string, KinStored[]>, ring: KinRing, now: number, muted = false,
): { queued: number; evicted: number; replaced: boolean } {
  kinBoxSweep(box, now);
  const list = box.get(ring.to) ?? [];
  const stored: KinStored = {
    ...ring, at: now, bornAt: Math.min(now, ring.t * 1000),
    // A silenced ring is STORED, not dropped, so `queued` and `evicted` keep
    // tracking the mailbox and the response stays indistinguishable from a
    // handle nobody polls. See the silent-mode block above. Absent when live.
    ...(muted ? { mute: true } : {}),
  };
  const i = list.findIndex((r) => r.from === ring.from && r.room === ring.room);
  let evicted = 0;
  let replaced = false;
  if (i >= 0) { list[i] = stored; replaced = true; }
  else {
    list.push(stored);
    while (list.length > KIN_BOX_MAX) { list.shift(); evicted++; }
  }
  box.set(ring.to, list);
  return { queued: list.length, evicted, replaced };
}

/** Drain a mailbox. A poll takes every live ring exactly once. */
export function kinBoxTake(box: Map<string, KinStored[]>, to: string, now: number): KinStored[] {
  kinBoxSweep(box, now);
  const list = box.get(to) ?? [];
  box.delete(to);
  return list;
}

/**
 * Is there anything a poll would actually HAND OVER? Non-destructive, and that
 * is its only reason to exist: a waiting poll has to decide whether to park
 * before it is allowed to take anything, because the check that follows can
 * answer 429 and a drained-then-refused mailbox is a lost call.
 *
 * A silenced ring does NOT count. It is stored (so a caller cannot tell silence
 * from absence) and thrown away at the drain, so treating it as something to
 * deliver would end the callee's wait to hand them nothing — and a caller who
 * kept ringing a silenced handle could keep that wait ending, which is denial
 * of sleep rebuilt out of the silence switch.
 */
export function kinBoxHas(box: Map<string, KinStored[]>, to: string, now: number): boolean {
  kinBoxSweep(box, now);
  return (box.get(to) ?? []).some((r) => !r.mute);
}

/**
 * Everything a ring POST decides, with no I/O in it — the DO method around this
 * is four lines. Same seam as the diagnose layer: decisions are pure so they
 * can be tested without a Durable Object.
 *
 * `to` is the handle from the URL (the DO's own name). The body carries `to`
 * as well because the caller's signature covers it, and the two must agree — a ring
 * signed for one handle must not be filed under another.
 *
 * `quiet` is the callee's stored silent-mode row, or null. It is consulted at
 * the very LAST step, where the ring is stored, and it changes nothing a caller
 * can see — read the silent-mode block above kinQuietActive before touching the
 * ordering. It DEFAULTS TO NULL, i.e. not silent, so a caller that forgets to
 * pass it rings the doorbell rather than muting the world: the client enforces
 * silence locally, so failing open here costs an unwanted ring and failing
 * closed would cost every call.
 */
/**
 * How long after a poll a handle is still considered to be listening.
 *
 * The resident polls every 4 s when the server will not hold, and holds for
 * ~25 s when it will, so a healthy Mac can be silent for half a minute at a
 * time through no fault of its own. 90 s is generous on purpose: the cost of
 * saying "not listening" about a Mac that is fine is a caller who does not
 * bother ringing, and that is worse than the ring taking a moment.
 */
// NOT exported. worker.ts is the worker ENTRY module, so workerd reads every
// named export as an entrypoint and refuses to start on anything that is not a
// function or an ExportedHandler -- "Incorrect type for map entry
// 'KIN_LISTEN_MS'". Measured: exporting it made the whole runtime fail to boot,
// which would have been a dead deploy rather than a failed test if the workerd
// section of contacts.test.mjs did not exist. The test reads the number out of
// this line instead, so there is still exactly one place it is written.
const KIN_LISTEN_MS = 90_000;

export function kinRingDecide(
  raw: string, to: string, box: Map<string, KinStored[]>, hits: Map<string, number[]>, now: number,
  quiet: KinQuiet | null = null,
  /** ms since this handle last polled, or null if this instance has never seen it. */
  heardMs: number | null = null,
): KinDecision {
  if (!KIN_HANDLE_RE.test(to)) return { status: 400, body: { error: 'bad handle' } };
  if (raw.length > KIN_RING_MAX_BODY) return { status: 413, body: { error: 'too big' } };
  let parsed: unknown;
  try { parsed = JSON.parse(raw); } catch { return { status: 400, body: { error: 'bad json' } }; }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return { status: 400, body: { error: 'bad body' } };
  }
  const b = parsed as Record<string, unknown>;
  const keys = Object.keys(b);
  // Every required key present, and nothing outside required ∪ optional. Checked
  // as two conditions rather than one length test: with an optional field, a
  // length test alone would accept a body that swapped a required key for the
  // optional one.
  if (keys.some((k) => !KIN_RING_KEYS.has(k) && !KIN_RING_OPTIONAL.has(k))
      || [...KIN_RING_KEYS].some((k) => !keys.includes(k))) {
    return { status: 400, body: { error: 'bad fields' } };
  }
  // Closed set, not a free string. The callee acts on this word, and an unknown
  // one must be refused here rather than reach a client that will not know what
  // to do with it. `undefined` is the ordinary ring and the common case.
  if (b.kind !== undefined && (typeof b.kind !== 'string' || !KIN_KINDS.has(b.kind))) {
    return { status: 400, body: { error: 'bad kind' } };
  }
  // SKEW FIRST, before any other judgement is passed on this ring. Nothing is
  // stored or acted on until every check below passes, so the ordering costs
  // nothing — but a replay gate that sits after other work is a replay gate
  // someone eventually moves.
  const t = b.t;
  // Integer seconds, same rule and same reason as the registration's `t`: the
  // callee reconstructs the signed string from this number, so a value with more
  // than one spelling is a signature that fails on one end for no visible
  // reason. Kept symmetric with kinRegisterDecide deliberately — an asymmetry
  // between two `t` validations is a bug waiting for whoever reads only one.
  if (typeof t !== 'number' || !Number.isInteger(t)) return { status: 400, body: { error: 'bad t' } };
  const skew = Math.abs(now / 1000 - t);
  if (skew > KIN_SKEW_S) return { status: 400, body: { error: 'skew', skewS: Math.round(skew) } };
  if (typeof b.to !== 'string' || !KIN_HANDLE_RE.test(b.to)) return { status: 400, body: { error: 'bad to' } };
  if (b.to !== to) return { status: 400, body: { error: 'to mismatch' } };
  if (typeof b.from !== 'string' || !KIN_HANDLE_RE.test(b.from)) return { status: 400, body: { error: 'bad from' } };
  if (b.from === b.to) return { status: 400, body: { error: 'self' } };
  if (typeof b.room !== 'string' || !ROOM_RE.test(b.room) || b.room.length < 8) {
    return { status: 400, body: { error: 'bad room' } };
  }
  if (typeof b.sig !== 'string' || !KIN_SIG_RE.test(b.sig)) return { status: 400, body: { error: 'bad sig' } };
  // `k` is checked for SHAPE and nothing else. The server does not decode it,
  // does not verify `sig` against it, and must not start: only the callee holds
  // the contact list that says whether this key may ring this person, and a
  // server that could verify a ring is a server that could forge one.
  if (typeof b.k !== 'string' || !KIN_KEY_RE.test(b.k)) return { status: 400, body: { error: 'bad k' } };
  // ── A HANG-UP IS NOT CHARGED TO THE DOORBELL ───────────────────────────────
  //
  // Every window below exists to bound DISTURBANCE: how often a stranger can
  // make somebody's Mac ring. A `bye` disturbs nobody -- it makes no sound,
  // draws no card, and is dropped on arrival unless it matches a call the
  // client already has in flight. Charging it to the ring budget would mean
  // two things, both bad: a caller who cancels twice could not place a third
  // call, and the hourly denial-of-sleep bound would be halved for the honest
  // caller while a flooder -- who never sends a bye -- kept all sixty.
  //
  // So a bye is metered on its own sibling windows, at the same limits. It can
  // never spend a ring's allowance, and a bye flood is bounded exactly as
  // tightly as a ring flood.
  const w = b.kind === undefined ? '' : b.kind + ':';
  if (!kinWindow(hits, w + 'key:' + b.k + '>' + to, now, 60_000, KIN_RING_PER_KEY)) {
    return { status: 429, body: { error: 'rate' } };
  }
  if (!kinWindow(hits, w + 'pair:' + b.from + '>' + to, now, 60_000, KIN_RING_PER_FROM)) {
    return { status: 429, body: { error: 'rate' } };
  }
  // The two backstops, and the only caps a flooder cannot mint its way around.
  // Minute first: a burst is refused by the cheaper window, and the hour's
  // budget is not spent on a request the minute already rejected.
  if (!kinWindow(hits, w + 'to:' + to, now, 60_000, KIN_RING_PER_TO)) {
    return { status: 429, body: { error: 'rate' } };
  }
  if (!kinWindow(hits, w + 'toh:' + to, now, 3600_000, KIN_RING_PER_TO_HOUR)) {
    return { status: 429, body: { error: 'rate' } };
  }
  const ring: KinRing = { to, from: b.from, room: b.room, t, sig: b.sig, k: b.k,
                          ...(b.kind === undefined ? {} : { kind: b.kind as string }) };
  // SILENT MODE, and it is the LAST thing consulted on purpose. Every gate above
  // — validation, both per-caller windows, both per-`to` windows — has already
  // run and charged, so a silent handle behaves identically to a live one all
  // the way down to here. Moving this check any earlier (to "save the work")
  // would make a silent handle stop refusing a flooder, and a handle that never
  // says 429 is a handle whose owner has visibly turned something on.
  //
  // Expiry is evaluated HERE, at arrival, from the stored row: nothing sweeps.
  //
  // AND NOT TO A BYE. Silent mode suppresses being called; it must not suppress
  // being told a call ENDED, or the one person guaranteed to be staring at a
  // "Calling Meera…" card -- someone who set their own Mac to silent and then
  // placed a call -- is the one person who never learns it was declined. The
  // denial-of-sleep argument does not reach here either: waking a held poll to
  // hand over a bye ends one HTTP request early and shows, sounds and lights
  // nothing, and the sibling windows above bound how often it can happen.
  const muted = b.kind === undefined && kinQuietActive(quiet, now);
  const r = kinBoxPut(box, ring, now, muted);
  // ONE return, ONE body, shared by both paths. There is deliberately no
  // early return for the silent case: two return sites are two literals that
  // drift, and the first thing that drifts is `queued`.
  // ── WHETHER ANYBODY WAS ACTUALLY THERE ────────────────────────────────────
  //
  // `ok: true` used to be the whole answer, and it was returned identically
  // whether the callee's Mac was waiting or had stopped listening the previous
  // evening. On 2026-08-26 exactly that happened: a Mac's login agent had been
  // dead for twenty hours, every ring was accepted with `ok: true, queued: 1`,
  // and the caller sat watching a ringing screen with nothing on the other end.
  //
  // The server is the only party that can know this, so it is the server's job
  // to say it. Omitted rather than false when unknown -- see kinLastPoll: a
  // freshly woken instance has heard from nobody, and "offline" is not a thing
  // to guess.
  const listening = heardMs === null ? undefined : heardMs <= KIN_LISTEN_MS;
  return {
    status: 200,
    body: {
      ok: true, queued: r.queued, evicted: r.evicted, leaseMs: KIN_LEASE_MS,
      ...(listening === undefined ? {} : { listening }),
    },
    ...(muted ? { muted: true } : {}),
  };
}

/**
 * Everything a mailbox poll decides. `want` is the registered credential, or
 * null if nobody has claimed this handle.
 *
 * A wrong or missing credential gets the SAME generic 401 either way — a
 * distinguishable "not registered" would make this endpoint an oracle for which
 * handles exist, and a handle is the one thing the contact graph is built on.
 *
 * `quiet` is the stored silent-mode row and is REPORTED BACK. That is not a
 * convenience: a device that was restarted, updated, or reinstalled has no idea
 * what it last set, and a toggle that has silently desynchronised from the
 * server is how someone believes they are reachable while they are not. The poll
 * is authenticated, so this tells only the owner about their own state.
 *
 * `dropped` is how many rings have been silenced since this object woke — a
 * count, not a ledger; it resets when the isolate does, and the device keeps its
 * own missed-call list.
 *
 * `waitMs` is the LONG POLL, and it is the whole reason a ring is fast. Zero
 * means "answer now", which is what every deployed client sends and what this
 * function did unconditionally before — that path below is unchanged, down to
 * the order of its two rate checks, because an old client must keep working
 * against this server byte for byte. Non-zero means "hold the line": the
 * decision comes back with `park` set and the Durable Object does the holding,
 * because parking is I/O and nothing in this function is allowed to be.
 */
export function kinPollDecide(
  to: string, tok: string, want: string | null,
  box: Map<string, KinStored[]>, hits: Map<string, number[]>, now: number,
  quiet: KinQuiet | null = null, dropped = 0,
  waitMs = 0, parked = 0,
): KinDecision {
  if (!KIN_HANDLE_RE.test(to)) return { status: 400, body: { error: 'bad handle' } };
  if (!KIN_TOK_RE.test(tok)) return { status: 400, body: { error: 'bad tok' } };
  if (!want || !kinTimingSafeEqual(want, tok)) {
    // Failed auth is charged to its OWN window. Charging it to the handle's
    // poll budget would let anyone who knows a handle 429 the real owner off
    // their own mailbox — the owner never fails auth, so the two must not share.
    if (!kinWindow(hits, 'bad:' + to, now, 60_000, KIN_BAD_AUTH_PER_MIN)) {
      return { status: 429, body: { error: 'rate' } };
    }
    return { status: 401, body: { error: 'no' } };
  }
  if (waitMs > 0) {
    // ── THE PEEK EXISTS BECAUSE THE DRAIN IS DESTRUCTIVE ──────────────────
    //
    // A rate check placed after the drain would throw a real ring away on the
    // way to answering 429, and the caller would be told "slow down" while the
    // call it was waiting for evaporated. So a waiting poll looks WITHOUT
    // TAKING first, and only a poll that finds nothing is charged for arming.
    //
    // That ordering also buys the property the client depends on: a poll that
    // delivered a ring costs no arming budget, so the client may re-arm the
    // instant it hands the ring over. Without it the ordinary path — ring
    // lands, client comes straight back — is a 429 every single time, and the
    // second of two rings 300 ms apart waits out a backoff. It is not a
    // loophole: to earn a free re-arm you must actually have been rung, and
    // rings are capped hard elsewhere (KIN_RING_PER_TO, KIN_RING_PER_TO_HOUR).
    if (!kinBoxHas(box, to, now)) {
      // Its OWN key prefix, like every other window in this file, so arming
      // and plain polling cannot spend each other's budget.
      if (!kinWindow(hits, 'wait:' + to, now, KIN_WAIT_GAP_MS, 1)) {
        return { status: 429, body: { error: 'rate', retryMs: KIN_WAIT_GAP_MS } };
      }
      // Above the concurrency cap the request does NOT fail — it answers like
      // an ordinary poll and lets the client fall back to its own cadence. A
      // 429 here would read as "no ring" to anything that did not parse it,
      // and the failure mode of this endpoint is a missed call.
      //
      // DELIBERATELY AN EMPTY BODY. The Durable Object must replace it after
      // the wait, and a DO that forgot to honour `park` would otherwise answer
      // a perfectly well-formed "nobody is calling" — a blind instrument
      // reporting a negative, and the one failure this endpoint must never
      // have. `{}` has no `rings` key, so it is refused loudly instead.
      if (parked < KIN_WAIT_MAX_PARKED) return { status: 200, body: {}, park: true };
    }
  } else if (!kinWindow(hits, 'poll:' + to, now, KIN_POLL_GAP_MS, 1)) {
    return { status: 429, body: { error: 'rate', retryMs: KIN_POLL_GAP_MS } };
  }
  return { status: 200, body: kinPollBody(to, box, now, quiet, dropped, waitMs > 0 ? 0 : undefined) };
}

/**
 * How long this poll asked to be held, in ms, or 0 for "answer now".
 *
 * Every unusable spelling — absent, empty, `abc`, `-1`, `NaN`, or a wait so
 * short it is not a wait — comes back as 0, which is the DEPLOYED behaviour and
 * not an error. A 400 here would mean a client that guessed the parameter
 * slightly wrong stopped receiving calls entirely.
 *
 * Clamped at both ends and not merely floored: `wait=86400000` from a buggy or
 * hostile client must not become a request held for a day.
 */
export function kinWaitMs(raw: string | null): number {
  if (!raw) return 0;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < KIN_WAIT_MIN_MS) return 0;
  return Math.min(Math.floor(n), KIN_WAIT_MAX_MS);
}

/**
 * The 200 body of a poll, and the drain that fills it. Split out of
 * kinPollDecide for one reason: after a parked poll WAKES, the Durable Object
 * has to build the same answer again without re-running the auth check or
 * re-charging the rate window it already paid. Two spellings of this body would
 * be two shapes for the Swift decoder to disagree about, and the one that only
 * runs after a wake is the one nobody would notice was wrong.
 *
 * `waitedMs` is present only on a poll that ASKED to wait, and it is the
 * client's proof that this server understands waiting at all. An older worker
 * ignores the `wait` parameter silently and answers immediately with a body
 * that has no such field — which is indistinguishable from a fast answer unless
 * the server says so out loud. See Identity.pollOnce on the Swift side: the
 * absence of this field is what switches the client back to its 5 s cadence.
 */
export function kinPollBody(
  to: string, box: Map<string, KinStored[]>, now: number,
  quiet: KinQuiet | null, dropped: number, waitedMs?: number,
): Record<string, unknown> {
  // The drain is destructive either way: a silenced ring is taken out of the
  // mailbox and thrown away here, never handed to the callee. Filtering at the
  // drain rather than refusing at the door is what keeps the ring response
  // identical to an unpolled handle's — see the silent-mode block.
  const taken = kinBoxTake(box, to, now);
  const rings = taken.filter((r) => !r.mute);
  return {
    to,
    // `ageMs` mirrors rendezvous()'s: the callee decides for itself whether a
    // ring is still worth showing, and can say why when it is not.
    //
    // `k` MUST come back out. It is the caller's device key, and without it
    // the callee has nothing to verify `sig` against and nothing to match
    // against its contact list — a poll that drops `k` turns every ring into
    // an unverifiable one, which the callee then correctly refuses to show.
    // That failure looks exactly like "nobody is calling".
    // `kind` comes back out for the same reason `k` does: a field the server
    // accepts, stores, and then drops on the way to the client is a field that
    // does nothing at all. Omitted rather than nulled when absent, so an ordinary
    // ring is shaped exactly as it was before byes existed.
    rings: rings.map((r) => ({
      from: r.from, room: r.room, t: r.t, sig: r.sig, k: r.k, ageMs: now - r.bornAt,
      ...(r.kind === undefined ? {} : { kind: r.kind }),
    })),
    // ALWAYS PRESENT, even when nothing is stored, so a Swift decoder sees one
    // shape and "no row yet" cannot be mistaken for "the field was dropped".
    // `on` is the READ-TIME verdict, not the stored bit: an expired deadline
    // reports on:false while the row still says quiet:true, and the client
    // must believe `on`.
    quiet: {
      on: kinQuietActive(quiet, now),
      until: quiet?.until ?? 0,
      exceptKnown: quiet?.exceptKnown ?? false,
      dropped,
    },
    // `pollMs` is the cadence for a client that is NOT waiting, and it stays
    // 5000 for exactly that client. It is not the long poll's cadence and must
    // never be read as one.
    pollMs: 5000, leaseMs: KIN_LEASE_MS,
    ...(waitedMs === undefined ? {} : { waitedMs }),
  };
}

// The exact fields a registration carries. Five, no more: same reasoning as
// KIN_RING_KEYS, and here it also means the signed string covers every field
// that has any effect, which is what makes the signature worth anything.
const KIN_REG_KEYS = new Set(['to', 'tok', 'k', 't', 'sig']);

/**
 * Everything a register/refresh decides. `put`/`putKey` in the result are the
 * DO's instructions to persist — the only durable state this whole feature adds.
 *
 * ── PROOF OF POSSESSION, and what it replaces ───────────────────────────────
 *
 * The version this replaces was first-writer-wins with NO proof at all, and its
 * own comment admitted the server "cannot check that `tok` and `to` come from
 * the same keypair". While handles were 130-bit hashes that was survivable: you
 * had to know a handle to squat it, and you could not guess one. Handles are now
 * people's names. `devesh` is guessable by anyone who has met Devesh, so
 * without a proof the name belongs to WHOEVER SENDS THE FIRST HTTP REQUEST,
 * not to the person. Worse, under the old rule merely PROBING a free handle
 * with a random `tok` claimed it — one request was both the enumeration and the
 * theft, and the rightful owner's first launch would find their own name gone.
 *
 * So a registration now carries the device's Ed25519 public key `k` and a
 * signature `sig` over KIN_REG_CONTEXT + to + '|' + tok + '|' + t. The signature
 * covers the handle (so it cannot be lifted onto another name), the credential
 * (so it cannot be lifted onto another `tok`) and the timestamp (so it cannot be
 * replayed).
 *
 * ── THE ORDER OF THESE CHECKS IS PART OF THE DESIGN ─────────────────────────
 *
 *  1. SKEW BEFORE CRYPTO. A captured registration must expire, and it can only
 *     expire on the timestamp — nothing else in the message ages. Putting the
 *     skew gate first also means junk never buys an attacker a curve operation:
 *     signature verification is the most expensive thing this endpoint does, and
 *     it is unauthenticated, so it must be the LAST thing reached, not the first.
 *  2. VERIFY `sig` AGAINST THE PRESENTED `k`. This proves the sender holds that
 *     private key and is talking about THIS handle at THIS moment. Nothing about
 *     the mailbox's state has been revealed yet.
 *  3. FIRST-WRITER-WINS ON `handle -> k`, and a re-register is checked against
 *     the STORED key. Because both keys are canonicalised to one base64
 *     spelling before comparison, `k === haveKey` is byte equality of the key
 *     material, so accepting a re-register is the same statement as "the
 *     signature verified under the stored key". That equivalence is the whole
 *     protection and it is why the canonical form exists — comparing raw
 *     user-supplied strings would let a padding variant of the same key read as
 *     a different device, or a different device read as the same key.
 *
 * Steps 2 and 3 are in that order so the two failures stay TELLABLE APART: a
 * squatter gets 403 `taken`, a broken signer gets 401 `no`. Collapsing them
 * would make a client with a signing bug walk its whole collision ladder and
 * quietly claim `devesh7`, with nothing anywhere saying why. And 403 discloses
 * nothing that is not already public: the collision ladder only works because a
 * client can find out that `devesh` is taken.
 *
 * `tok` REMAINS REFRESHABLE, by the original device only. Step 3 gates on `k`,
 * not on `tok`, so the owner can rotate its poll credential and a stranger
 * cannot rotate anything. `tok` is still only READ access to one mailbox — it
 * can never ring anyone, because ringing needs a key the server has never seen.
 */
export async function kinRegisterDecide(
  raw: string, to: string, have: string | null, haveKey: string | null,
  hits: Map<string, number[]>, now: number,
  verify: KinVerify = kinVerifyEd25519,
): Promise<KinDecision> {
  if (!KIN_HANDLE_RE.test(to)) return { status: 400, body: { error: 'bad handle' } };
  if (raw.length > KIN_REG_MAX_BODY) return { status: 413, body: { error: 'too big' } };
  let parsed: unknown;
  try { parsed = JSON.parse(raw); } catch { return { status: 400, body: { error: 'bad json' } }; }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return { status: 400, body: { error: 'bad body' } };
  }
  const b = parsed as Record<string, unknown>;
  const keys = Object.keys(b);
  if (keys.length !== KIN_REG_KEYS.size || keys.some((k) => !KIN_REG_KEYS.has(k))) {
    return { status: 400, body: { error: 'bad fields' } };
  }
  if (typeof b.to !== 'string' || b.to !== to) return { status: 400, body: { error: 'to mismatch' } };
  if (typeof b.tok !== 'string' || !KIN_TOK_RE.test(b.tok)) return { status: 400, body: { error: 'bad tok' } };
  if (typeof b.k !== 'string' || !KIN_KEY_RE.test(b.k)) return { status: 400, body: { error: 'bad k' } };
  // (1) SKEW, before any crypto. See the note above — this ordering is load
  // bearing and a signature check moved above it would be a silent regression.
  //
  // INTEGER, not merely finite. `t` is STRINGIFIED into the signed message, so
  // its spelling is part of the contract: JS renders 1e21 as "1e+21" and
  // 1800000000.5 with a decimal point, and a Swift client formatting either
  // differently would produce a signature that verifies perfectly on the device
  // and fails here, forever, with a 401 that blames the key. Integers have one
  // spelling in every language, so requiring one removes the whole class.
  if (typeof b.t !== 'number' || !Number.isInteger(b.t)) return { status: 400, body: { error: 'bad t' } };
  const skew = Math.abs(now / 1000 - b.t);
  if (skew > KIN_SKEW_S) return { status: 400, body: { error: 'skew', skewS: Math.round(skew) } };
  if (typeof b.sig !== 'string' || !KIN_REG_SIG_RE.test(b.sig)) return { status: 400, body: { error: 'bad sig' } };
  if (!kinWindow(hits, 'reg:' + to, now, 60_000, KIN_REG_PER_MIN)) {
    return { status: 429, body: { error: 'rate' } };
  }
  const pub = kinB64(b.k, 32);
  const sig = kinB64(b.sig, 64);
  if (!pub) return { status: 400, body: { error: 'bad k' } };
  if (!sig) return { status: 400, body: { error: 'bad sig' } };
  // (2) The proof. Everything above this line is free; this is the one
  // expensive operation, and it is deliberately the last gate crossed.
  const msg = new TextEncoder().encode(KIN_REG_CONTEXT + to + '|' + b.tok + '|' + b.t);
  if (!await verify(pub, sig, msg)) return { status: 401, body: { error: 'no' } };
  // (3) First-writer-wins on the KEY. One canonical spelling on both sides, so
  // this comparison is byte equality of key material and cannot be fooled by a
  // url-safe or unpadded rendering of the very same key.
  const kc = kinB64Encode(pub);
  if (haveKey && kc !== haveKey) return { status: 403, body: { error: 'taken' } };
  // LEGACY ROWS, and why they are not a second squat window: a mailbox
  // registered before proof-of-possession existed has a `tok` and no key. If
  // such a row could be key-claimed by any valid signature, the migration
  // itself would be a takeover window — exactly the hole being closed. So a
  // legacy row is adoptable only by someone who already knows its `tok`, which
  // in practice is the device that wrote it.
  if (have && !haveKey && !kinTimingSafeEqual(have, b.tok)) {
    return { status: 403, body: { error: 'taken' } };
  }
  // Write only what actually changed, so the durable-write count stays honest:
  // a steady-state refresh from an unchanged device writes nothing at all.
  const putTok = have === b.tok ? undefined : b.tok;
  const putKey = haveKey === kc ? undefined : kc;
  return {
    status: 200,
    body: { ok: true, fresh: !haveKey, pollMs: 5000, leaseMs: KIN_LEASE_MS },
    ...(putTok === undefined ? {} : { put: putTok }),
    ...(putKey === undefined ? {} : { putKey }),
  };
}

/**
 * Everything a silent-mode toggle decides. Read the block above kinQuietActive
 * first — this function is the write half of it.
 *
 *   POST /api/kin/<handle>/quiet   {to, k, t, sig, quiet, until}
 *   sig = Ed25519(devicePriv, "kin-quiet-v1|" + to + "|" + quiet + "|" + until + "|" + t)
 *
 * `haveKey` is the STORED device key for this handle, canonical base64, or null.
 *
 * ── ONLY THE OWNING DEVICE MAY SILENCE A HANDLE ─────────────────────────────
 *
 * The signature is verified against the STORED key, never against the key in
 * the request. Verifying against the presented key would prove only "somebody
 * holds some private key" — which every attacker does — and would let anyone
 * silence anyone. So the presented `k` must first be byte-equal to the stored
 * key (both canonicalised, exactly as in kinRegisterDecide step 3), and the
 * proof is then checked under the stored bytes.
 *
 * A handle with NO registered key therefore cannot be silenced: there is nothing
 * to prove possession against. It answers 401 `no` — the SAME response as a
 * wrong key, because a distinguishable "nobody has claimed this" would be a
 * second existence oracle. (Register already discloses existence, by design, via
 * 403 `taken`; this endpoint must not add another, and it must not spend a curve
 * operation on a key that cannot possibly be the owner's either.)
 *
 * ── THE ORDER, same law as register ─────────────────────────────────────────
 *
 *  1. shape, then SKEW BEFORE ANY CRYPTO — a captured toggle must expire, and it
 *     can only expire on the timestamp;
 *  2. the ownership comparison, which is free, so a stranger never buys a curve
 *     operation and is charged to a window of their own;
 *  3. the owner's rate window;
 *  4. the proof.
 */
export async function kinQuietDecide(
  raw: string, to: string, haveKey: string | null,
  hits: Map<string, number[]>, now: number,
  verify: KinVerify = kinVerifyEd25519,
): Promise<KinDecision> {
  if (!KIN_HANDLE_RE.test(to)) return { status: 400, body: { error: 'bad handle' } };
  if (raw.length > KIN_QUIET_MAX_BODY) return { status: 413, body: { error: 'too big' } };
  let parsed: unknown;
  try { parsed = JSON.parse(raw); } catch { return { status: 400, body: { error: 'bad json' } }; }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return { status: 400, body: { error: 'bad body' } };
  }
  const b = parsed as Record<string, unknown>;
  const keys = Object.keys(b);
  if (keys.length !== KIN_QUIET_KEYS.size || keys.some((k) => !KIN_QUIET_KEYS.has(k))) {
    return { status: 400, body: { error: 'bad fields' } };
  }
  if (typeof b.to !== 'string' || b.to !== to) return { status: 400, body: { error: 'to mismatch' } };
  if (typeof b.k !== 'string' || !KIN_KEY_RE.test(b.k)) return { status: 400, body: { error: 'bad k' } };
  // A BOOLEAN, and it is stringified into the signed message as 'true'/'false'.
  // Not a number, not '1': the signed string is a cross-language contract and
  // `String(true)` is the one spelling Swift and JS agree on without argument.
  if (typeof b.quiet !== 'boolean') return { status: 400, body: { error: 'bad quiet' } };
  // (1) `t` integer, then skew, before any crypto. Same rule and same reason as
  // register and ring: `t` is stringified into the signature, and 1e21 renders
  // as "1e+21" — a signature that verifies on the device and never here.
  if (typeof b.t !== 'number' || !Number.isInteger(b.t)) return { status: 400, body: { error: 'bad t' } };
  const skew = Math.abs(now / 1000 - b.t);
  if (skew > KIN_SKEW_S) return { status: 400, body: { error: 'skew', skewS: Math.round(skew) } };
  // `until`: 0 is indefinite, otherwise a deadline AFTER the moment it was
  // signed and inside the horizon. Integer for the same stringification reason.
  // A deadline already in the past would store as a toggle that reads on and
  // behaves off, which is the desynchronised state this feature exists to avoid.
  const until = b.until;
  if (typeof until !== 'number' || !Number.isInteger(until) || until < 0) {
    return { status: 400, body: { error: 'bad until' } };
  }
  if (until !== 0 && (until <= b.t || until - b.t > KIN_QUIET_MAX_S)) {
    return { status: 400, body: { error: 'bad until' } };
  }
  if (typeof b.sig !== 'string' || !KIN_REG_SIG_RE.test(b.sig)) return { status: 400, body: { error: 'bad sig' } };
  const pub = kinB64(b.k, 32);
  if (!pub) return { status: 400, body: { error: 'bad k' } };
  const sig = kinB64(b.sig, 64);
  if (!sig) return { status: 400, body: { error: 'bad sig' } };
  // ONE refusal for every way this can fail to be the owner — unclaimed handle,
  // wrong key, or a signature that does not check out. Three causes, one answer.
  const deny: KinDecision = { status: 401, body: { error: 'no' } };
  // (2) The ownership comparison. Free, so it comes before the window and before
  // the curve: a stranger spends neither.
  const stored = haveKey ? kinB64(haveKey, 32) : null;
  if (!stored || kinB64Encode(pub) !== haveKey) {
    // Charged to its OWN window, exactly like a failed poll: if failures shared
    // the owner's budget, anyone who knows a handle could 429 its owner out of
    // their own silent-mode toggle.
    if (!kinWindow(hits, 'qbad:' + to, now, 60_000, KIN_BAD_AUTH_PER_MIN)) {
      return { status: 429, body: { error: 'rate' } };
    }
    return deny;
  }
  // (3) The owner's window. Bounds both the curve operations and the durable
  // writes this route can cause, and a human pressing a toggle never reaches it.
  if (!kinWindow(hits, 'quiet:' + to, now, 60_000, KIN_QUIET_PER_MIN)) {
    return { status: 429, body: { error: 'rate' } };
  }
  // (4) The proof, under the STORED key. `stored` and `pub` are byte-equal by
  // the check above; passing `stored` is the statement the comment makes.
  const msg = new TextEncoder().encode(
    KIN_QUIET_CONTEXT + to + '|' + String(b.quiet) + '|' + until + '|' + b.t,
  );
  if (!await verify(stored, sig, msg)) return deny;
  // Stored verbatim, so the row matches the signature that authorised it. With
  // quiet:false a non-zero `until` is retained and has no effect — kinQuietActive
  // short-circuits on the toggle — but a client should send 0.
  const row: KinQuiet = { quiet: b.quiet, until, exceptKnown: false, at: now };
  return {
    status: 200,
    // The evaluated verdict, not the raw bit, so the device can compare what it
    // asked for against what is actually in force.
    body: { ok: true, quiet: kinQuietActive(row, now), until, exceptKnown: row.exceptKnown },
    putQuiet: row,
  };
}

// ── Edge rate limits for the doorbell: A SIBLING MAP, not macPosts ───────────
//
// macPosts is telemetry's 5000/h budget. Sharing it would mean a Mac that beats
// hard cannot ring, and a ring flood silences telemetry — two unrelated things
// failing as one. Same shape, own map, and the three verbs get their own
// budgets inside it via the key so they cannot spend each other either.
//
// THE COST THESE NUMBERS ARE REALLY CAPPING, stated plainly: every distinct
// handle touched here mints a Room DO via idFromName("inbox:" + handle), and
// Room's constructor does blockConcurrencyWhile with two storage.get and, the
// first time, two storage.put plus CREATE TABLE events. So an unauthenticated
// POST to a made-up handle leaves a durable, empty-table DO behind. Reusing
// Room is what makes this feature deployable with no new class and no
// migration, and that storage is the price; the per-IP window is the only thing
// bounding it. Sized accordingly: `ring` and `register` are tight because a
// human presses call a few times an hour, `poll` is loose because a false 429
// there is a SILENTLY MISSED CALL and a real NAT can hold many Macs (a poll
// every 5 s is 720/h per device, so 20k/h is ~27 devices behind one address).
// The proper fix is a registry the ring path can consult before minting
// anything, which is a v2 item and is named as one.
const KIN_EDGE_WINDOW_MS = 3600_000;
// `quiet` is sized like `register`: both are pressed by a person, not by a loop,
// and both mint a DO on first touch. Its own key inside the map, so a ring flood
// cannot stop someone turning their own silence off.
const KIN_EDGE_CAP: Record<string, number> = { ring: 240, poll: 20_000, register: 120, quiet: 120 };
const kinPosts = new Map<string, number[]>();

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

// ── Which UDP relay port the native app is told to use ───────────────────────
//
// THE BUG THIS REPLACES WAS NOT A WRONG CONSTANT, IT WAS AN UNPINNED ONE.
//
// /api/mac/turn used to loop over every UDP `turn:` URL Cloudflare returned and
// OVERWRITE host/port on each match, so whichever URL Cloudflare happened to
// list LAST silently became our transport. `let port = 3478` looked like a
// default but was a dead initializer — the first parsed URL killed it. There
// was no preference in the code at all.
//
// Two consequences, and the second is the one worth remembering: the port we
// shipped was wrong (`:53`), and it was decided by the ORDER OF A THIRD PARTY'S
// JSON. Cloudflare reordering its response would have changed our media
// transport with no deploy, no commit and no log line on our side. A value that
// can change under you without a deploy is not a configuration, it is a
// liability — pin it, or measure it every time.
//
// EVIDENCE for the rank below, measured 2026-08-24 from this network against
// turn.cloudflare.com with real minted credentials: 3478 answered an Allocate
// in 4 ms; 443 and 53 both TIMED OUT. So here 3478 is not merely preferable, it
// is the only port that answers.
//
// 443 and 53 are NOT removed, and must not be. They exist for networks that
// block 3478 outright — exactly the networks this fallback list is for — and one
// measurement from one network says nothing about theirs. This change is a
// PREFERENCE, not a removal: 3478 goes first because it is the standard STUN/TURN
// port and the one measured working, 443 next because a network that blocks 3478
// is usually letting https-shaped traffic out, 53 last because DNS-port UDP is
// the most likely to be intercepted or rewritten by a captive resolver.
const TURN_PORT_RANK = [3478, 443, 53];

export interface TurnPick {
  host: string; port: number; ports: number[]; username: string; credential: string;
}

/**
 * Pick the UDP relay to hand the native app, in preference order.
 *
 * Pure and exported so the ordering can be proved without a deploy or a live
 * Cloudflare key — same seam as the diagnose layer. `null` means "no usable UDP
 * relay in this response", which the caller answers as p2pOnly exactly like a
 * missing key or a failed mint.
 *
 * Only `turn:` UDP entries are considered: the app speaks raw UDP STUN/TURN and
 * has no TLS or TCP relay path, so a `turns:`/`transport=tcp` URL is not a
 * fallback for it, it is a dead end.
 */
export function turnOrderUdp(
  iceServers: { urls?: string | string[]; username?: string; credential?: string }[] | undefined,
): TurnPick | null {
  const cands: { host: string; port: number; username: string; credential: string; seq: number }[] = [];
  let seq = 0;
  for (const s of iceServers ?? []) {
    const urls = Array.isArray(s.urls) ? s.urls : s.urls ? [s.urls] : [];
    for (const u of urls) {
      if (typeof u !== 'string' || !u.startsWith('turn:')) continue;
      if (u.includes('transport=tcp')) continue;
      const hp = u.slice(5).split('?')[0];
      const colon = hp.lastIndexOf(':');
      if (colon < 0) continue;
      const host = hp.slice(0, colon);
      const port = Number(hp.slice(colon + 1));
      if (!host || !Number.isInteger(port) || port < 1 || port > 65_535) continue;
      // A relay with no credential is not a relay. The old code took the LAST
      // entry's username whatever it was, so one credential-less entry at the
      // end of the list turned a working mint into p2pOnly.
      if (!s.username) continue;
      cands.push({ host, port, username: s.username, credential: s.credential ?? '', seq: seq++ });
    }
  }
  if (!cands.length) return null;
  const rank = (p: number): number => {
    const i = TURN_PORT_RANK.indexOf(p);
    return i < 0 ? TURN_PORT_RANK.length : i;
  };
  // Stable by construction: equal rank falls back to arrival order, so a
  // response made entirely of unranked ports is passed through in Cloudflare's
  // own order rather than shuffled into an arbitrary one.
  cands.sort((a, b) => rank(a.port) - rank(b.port) || a.seq - b.seq);
  const best = cands[0];
  // Only ports on the CHOSEN host. A fallback list that silently changed host
  // mid-array would hand the client an address its credential does not cover.
  const ports: number[] = [];
  for (const c of cands) if (c.host === best.host && !ports.includes(c.port)) ports.push(c.port);
  return { host: best.host, port: best.port, ports, username: best.username, credential: best.credential };
}

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
const macPosts = new Map<string, number[]>();
// ── Crash reports get their own budget ───────────────────────────────────────
//
// A SIBLING MAP, for the same reason the doorbell has one: a Mac that beats hard
// during a long call must not lose the ability to report the crash that ends it,
// and a Mac stuck in a crash loop must not silence its own telemetry. Two
// unrelated things failing as one is the thing being avoided.
//
// 200/h is deliberately loose for something a healthy machine sends zero of. A
// crash loop is the case this whole feature exists for, and it is also the case
// that posts most: a copy that dies on launch, relaunches, sends the previous
// death, and dies again. Being rate limited out of reporting exactly then would
// leave the loudest possible failure looking like silence.
const crashPosts = new Map<string, number[]>();
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

/// A stored beat's fields are JSON in one column, so every reader goes through
/// this: a malformed row must not take down a dashboard that is showing forty
/// other calls.
/// The mirror of safeParse, and the reason it needs to exist.
///
/// `JSON.stringify(x).slice(0, n)` cuts a valid document mid-token. safeParse()
/// turns invalid JSON into `{}`. So one oversized beat did not lose its longest
/// field -- it lost EVERY field it had and read as a completely blind end, which
/// is the single thing this layer must never silently do. A dashboard would show
/// "cannot see" for a client that was in fact reporting everything.
///
/// Drop whole keys instead, largest serialised first, and leave the count behind
/// so a reader can tell "trimmed here" from "never sent by the client". Always
/// returns parseable JSON, including the degenerate case of one enormous field.
export function packFields(rest: Record<string, unknown>, limit = 8000): string {
  let out = JSON.stringify(rest);
  if (out.length <= limit) return out;
  const kept: Record<string, unknown> = { ...rest };
  const bySize = Object.keys(kept).sort(
    (a, b) => JSON.stringify(kept[b] ?? null).length - JSON.stringify(kept[a] ?? null).length);
  let dropped = 0;
  for (const k of bySize) {
    delete kept[k];
    dropped++;
    out = JSON.stringify({ ...kept, fields_dropped: dropped });
    if (out.length <= limit) return out;
  }
  return JSON.stringify({ fields_dropped: dropped });
}

function safeParse(t: unknown): Record<string, unknown> {
  if (typeof t !== 'string') return {};
  try { const v = JSON.parse(t); return v && typeof v === 'object' ? v : {}; } catch { return {}; }
}

function shapeMacRow(r: any): Record<string, unknown> {
  return {
    call: r.call, install: r.install, version: r.version, model: r.model,
    phase: r.phase, wall: r.wall, ...safeParse(r.fields),
  };
}

// ── Self-diagnosis: turning stored beats into a NAMED fault ─────────────────
//
// DIAGNOSE.md is the design. Three properties matter more than the rule list:
//
// 1. Every rule is a FRACTION or a RATE. A count carries no meaning without the
//    seconds it happened over: "40 concealments" is a clean call across one beat
//    and a broken one across ten.
// 2. Every latency rule subtracts prop = rtt_ms/2, exactly as calls.js:23-25
//    already does for the dashboard. Distance is not a defect, and an absolute-ms
//    threshold containing propagation is a hidden distance limit -- a bug this
//    codebase has now shipped four separate times.
// 3. The BLINDNESS GATE runs first. An instrument that cannot see an event
//    returns the same value as a real negative, so a missing field must produce
//    `unknown` with a named reason -- never a default, and never `healthy`.
//
// The client does not send most of the fields below yet, so a diagnose over
// today's beats is expected to come back mostly `unknown`. That is the correct
// answer, not a gap: it says exactly which instrument is missing.
//
// Pure functions on purpose. The Durable Object below only fetches rows; the
// verdicts are computed by `diagnoseEnd` / `diagnoseAgreement`, which can be
// fed hand-written beats and checked without a deploy.

const DIAG_EXPECTED_PPS = 1500;   // 48 kHz / 32 samples per packet
const DIAG_EXPECTED_FPS = 30;
const DIAG_WINDOW = 3;            // last 3 beats ~ 15 s
const DIAG_MIN_BEATS = 2;

type DiagSev = 'critical' | 'major' | 'minor' | 'info' | 'none' | 'unknown';
type DiagSource = 'local' | 'peer_report' | 'mixed';

const DIAG_SEV: Record<string, DiagSev> = {
  never_connected: 'critical', no_route: 'critical', dropped: 'critical',
  one_way_out: 'critical', one_way_in: 'critical', mic_denied: 'critical',
  capture_broken: 'critical', mic_silent: 'critical', crypto_broken: 'critical',
  video_black_in: 'critical', video_frozen_in: 'critical',
  audio_dropouts_in: 'major', audio_dropouts_out: 'major', starved: 'major',
  high_latency: 'major', video_lag: 'major', path_flapping: 'major',
  internal_defect: 'major', echo: 'major', version_skew: 'major',
  device_wrong: 'major',
  jittery_audio: 'minor', aec_thrashing: 'minor', video_stutter_in: 'minor',
  video_pixelated_in: 'minor', video_low_res_in: 'minor',
  mic_muted: 'info', peer_left: 'info', reconnecting: 'info',
};
const DIAG_RANK: Record<DiagSev, number> = {
  critical: 5, major: 4, minor: 3, info: 2, unknown: 1, none: 0,
};

interface DiagFault { name: string; severity: DiagSev; evidence: string; source: DiagSource; }
interface DiagSkip { rule: string; why: string; }
interface DiagDirection {
  verdict: string; severity: DiagSev; reason: string | null;
  coverage: boolean; faults: DiagFault[]; skipped: DiagSkip[];
}
interface DiagLatency {
  m2e_p50: number | null; m2e_p99: number | null; rtt_ms: number | null;
  prop_ms: number | null; overhead_ms: number | null;
  g2g_p50: number | null; g2g_overhead_ms: number | null;
  probes: number | null; graded: boolean; why: string | null;
}
export interface DiagEnd {
  call: string; install: string | null; version: string | null; model: string | null;
  verdict: string; severity: DiagSev; reason: string | null;
  directions: { audio_in: DiagDirection; audio_out: DiagDirection; video_in: DiagDirection };
  latency: DiagLatency;
  coverage: Record<string, boolean>;
  faults: DiagFault[];
  skipped: DiagSkip[];
  beatsInWindow: number; lastBeatAgeS: number | null; endedCleanly: boolean;
}
export interface DiagEndInput {
  call: string;
  install?: string | null; version?: string | null; model?: string | null;
  beats: Record<string, unknown>[];   // any order; `wall` in SECONDS
  endedCleanly?: boolean;
  now?: number;                       // seconds
}

function dnum(v: unknown): number | null {
  return typeof v === 'number' && isFinite(v) ? v : null;
}
function diagRound(v: number | null, d = 2): number | null {
  if (v === null) return null;
  const m = Math.pow(10, d);
  return Math.round(v * m) / m;
}

/// The window's view of one field. Nothing here ever invents a value: a field
/// the beats do not carry comes back `null`, and the caller must then name the
/// blindness instead of grading it.
function diagWindow(beats: Record<string, unknown>[]) {
  const first = beats[0];
  const last = beats[beats.length - 1];
  const spanS = Math.max(0, (dnum(last.wall) ?? 0) - (dnum(first.wall) ?? 0));
  const vals = (k: string): number[] =>
    beats.map((b) => dnum(b[k])).filter((v): v is number => v !== null);
  const avg = (k: string): number | null => {
    const v = vals(k);
    return v.length ? v.reduce((a, x) => a + x, 0) / v.length : null;
  };
  const maxOf = (k: string): number | null => {
    const v = vals(k);
    return v.length ? v.reduce((a, x) => (x > a ? x : a), v[0]) : null;
  };
  const has = (k: string): boolean => vals(k).length > 0;
  const flips = (k: string): boolean => {
    const v = vals(k);
    return v.length > 1 && v.some((x) => x !== v[0]);
  };
  // A counter's RATE per second, or null when these beats cannot yield one.
  //
  // `foo_ps` is a rate already and is believed directly. Everything else in
  // this schema is a CUMULATIVE total -- that is how calls.js reads every one
  // of them -- so its rate is the delta over the seconds between the beats,
  // and a flat counter means a rate of zero. That is the whole point: a
  // `peer_played` that does not move is one-way audio.
  //
  // Two cases yield null instead of a number, because they are genuinely
  // unreadable rather than zero: no beat carried the field at all, and a
  // counter that went DOWN (a restarted peer resets to zero, and this codebase
  // has already been bitten by treating that as data).
  const rateOf = (k: string): number | null => {
    const ps = avg(k + '_ps');
    if (ps !== null) return ps;
    const v = vals(k);
    if (!v.length) return null;
    const d = v[v.length - 1] - v[0];
    if (d < 0) return null;
    if (spanS <= 0) return null;
    return d / spanS;
  };
  return { beats, first, last, spanS, vals, avg, maxOf, has, flips, rateOf };
}

/// One end's account of one call. `beats` should be that end's most recent
/// beats; only the last DIAG_WINDOW of them are graded.
export function diagnoseEnd(input: DiagEndInput): DiagEnd {
  const now = input.now ?? Date.now() / 1000;
  const all = (input.beats ?? []).slice()
    .sort((a, b) => (dnum(a.wall) ?? 0) - (dnum(b.wall) ?? 0));
  // ── A `pre_connect` beat is not a blind end. It is a call that had not
  // started yet ───────────────────────────────────────────────────────────────
  // The mac client's audioBeat returns early before its time-sync exists and
  // emits seven fields marked `pre_connect: 1` -- no rtt, no probes, no rings,
  // correctly, because none of them exist at that moment. Left in the window
  // they made a fully instrumented client look like one that had stopped
  // sending `probes`, and sent a whole lane hunting for a field that has been in
  // every beat since 0.20.1. The instrument was fine; the call had not begun.
  //
  // "Never got past setup" is a verdict of its own, and it is the useful one --
  // it points at rendezvous, ICE and TURN rather than at audio.
  const connected = all.filter((b) => dnum((b as any).pre_connect) !== 1);
  const preConnectOnly = all.length > 0 && connected.length === 0;
  const thinReason = preConnectOnly ? 'pre_connect_only' : 'insufficient_beats';
  const lastWall = all.length ? dnum(all[all.length - 1].wall) : null;
  const lastBeatAgeS = lastWall !== null ? diagRound(now - lastWall, 1) : null;
  const endedCleanly = input.endedCleanly === true;
  const ident = {
    call: input.call, install: input.install ?? null,
    version: input.version ?? null, model: input.model ?? null,
  };
  const blindDir = (reason: string): DiagDirection => ({
    verdict: 'unknown', severity: 'unknown', reason,
    coverage: false, faults: [], skipped: [],
  });

  // ── Blindness gate, first rule: two beats is the minimum from which a rate
  // can exist at all. One beat is a birth certificate, not a health record.
  if (connected.length < DIAG_MIN_BEATS) {
    return {
      ...ident,
      verdict: 'unknown', severity: 'unknown', reason: thinReason,
      directions: {
        audio_in: blindDir(thinReason),
        audio_out: blindDir(thinReason),
        video_in: blindDir(thinReason),
      },
      latency: {
        m2e_p50: null, m2e_p99: null, rtt_ms: null, prop_ms: null, overhead_ms: null,
        g2g_p50: null, g2g_overhead_ms: null, probes: null,
        graded: false, why: thinReason,
      },
      coverage: { beats: false, latency: false, audio_in: false, audio_out: false, video_in: false, v_glass: false },
      faults: [], skipped: [], beatsInWindow: connected.length, lastBeatAgeS, endedCleanly,
    };
  }

  const win = connected.slice(-DIAG_WINDOW);
  const w = diagWindow(win);

  // ── Blindness gate: latency ───────────────────────────────────────────────
  // prop is NEVER 0 when the round trip is unknown. Defaulting it turns a
  // 300 ms antipodal call -- the whole point of the product -- into a fault.
  const rtt = w.avg('rtt_ms');
  const probes = w.maxOf('probes');
  const m2e = w.avg('m2e_p50');
  const m2e99 = w.avg('m2e_p99');
  const g2g = w.avg('g2g_p50');
  let latWhy: string | null = null;
  if (rtt === null) latWhy = 'no_rtt_ms';
  else if (probes === null) latWhy = 'no_probe_count';
  else if (probes < 20) latWhy = 'probes_lt_20';
  const latGraded = latWhy === null;
  const prop = latGraded && rtt !== null ? rtt / 2 : null;
  const over = prop !== null && m2e !== null ? m2e - prop : null;
  const g2gOver = prop !== null && g2g !== null ? g2g - prop : null;
  const latency: DiagLatency = {
    m2e_p50: diagRound(m2e), m2e_p99: diagRound(m2e99), rtt_ms: diagRound(rtt),
    prop_ms: diagRound(prop), overhead_ms: diagRound(over),
    g2g_p50: diagRound(g2g), g2g_overhead_ms: diagRound(g2gOver),
    probes, graded: latGraded, why: latWhy,
  };

  // ── Blindness gate: the peer's receive report ─────────────────────────────
  // Nothing an end measures about its OWN sending is evidence about the path
  // out of it. cap_ps says packets left; only the far end can say they landed.
  const peerReports = w.maxOf('peer_reports');
  const outBlind = peerReports === null ? 'no_peer_report'
    : peerReports <= 0 ? 'no_peer_report' : null;

  // ── Blindness gate: is video even running? ───────────────────────────────
  const vEncodes = w.rateOf('v_encodes');
  const vFrags = w.rateOf('v_frags');
  let videoRunning: boolean | null = null;
  let videoSrc = 'v_encodes/v_frags';
  if (vEncodes !== null || vFrags !== null) {
    videoRunning = (vEncodes ?? 0) > 0 || (vFrags ?? 0) > 0;
  } else {
    const encPs = w.rateOf('v_enc');
    const decPs = w.rateOf('v_dec');
    if (encPs !== null || decPs !== null) {
      videoRunning = (encPs ?? 0) > 0 || (decPs ?? 0) > 0;
      videoSrc = 'v_enc_ps/v_dec_ps';
    } else {
      videoSrc = 'none';
    }
  }

  // ── Blindness gate: a percentile over a tenth of the frames is not a
  // latency (main.swift:2286-2294), so below half coverage it is discarded.
  const glassCov = w.avg('v_glass_cov');
  const glassOk = glassCov !== null && glassCov >= 0.5;
  const glass = glassOk ? w.avg('v_glass_ms_p50') : null;

  const endFaults: DiagFault[] = [];
  const endSkipped: DiagSkip[] = [];
  const mk = (
    bag: DiagFault[], name: string, evidence: string, source: DiagSource = 'local',
  ): void => { bag.push({ name, severity: DIAG_SEV[name] ?? 'major', evidence, source }); };

  // ── audio_in: the path INTO this end. Receiver-side evidence only. ────────
  const inFaults: DiagFault[] = [];
  const inSkipped: DiagSkip[] = [];
  const concealPs = w.rateOf('conceal');
  const recvPs = w.rateOf('recv');
  const peerStatus = w.maxOf('peer_status');
  const audioInCov = concealPs !== null || recvPs !== null || m2e !== null;

  if (concealPs === null) inSkipped.push({ rule: 'audio_dropouts_in', why: 'no_conceal_ps' });
  else if (concealPs / DIAG_EXPECTED_PPS > 0.005) {
    mk(inFaults, 'audio_dropouts_in',
      `${diagRound(concealPs, 1)} concealed/s = ${diagRound(100 * concealPs / DIAG_EXPECTED_PPS, 2)}% of ${DIAG_EXPECTED_PPS}/s (>0.5%)`);
  }
  if (recvPs === null) {
    inSkipped.push({ rule: 'one_way_in', why: 'no_inbound_packet_rate' });
    inSkipped.push({ rule: 'starved', why: 'no_inbound_packet_rate' });
  } else if (recvPs === 0 && peerStatus !== 2) {
    mk(inFaults, 'one_way_in', `0 packets/s arriving; peer_status=${peerStatus ?? 'unknown'}`);
  } else if (recvPs > 0 && recvPs / DIAG_EXPECTED_PPS < 0.5) {
    mk(inFaults, 'starved',
      `${diagRound(recvPs, 0)} pkt/s in = ${diagRound(100 * recvPs / DIAG_EXPECTED_PPS, 1)}% of expected (<50%)`);
  }
  const latePs = w.rateOf('late');
  const snapPs = w.rateOf('snaps');
  if (latePs === null && snapPs === null) inSkipped.push({ rule: 'jittery_audio', why: 'no_late_or_snaps' });
  else if ((snapPs ?? 0) > 0.1 || (latePs ?? 0) / DIAG_EXPECTED_PPS > 0.02) {
    mk(inFaults, 'jittery_audio',
      `${diagRound(snapPs ?? 0, 2)} cursor jumps/s, late ${diagRound(100 * (latePs ?? 0) / DIAG_EXPECTED_PPS, 2)}% of expected`);
  }
  if (!latGraded) inSkipped.push({ rule: 'high_latency', why: latWhy ?? 'latency_blind' });
  else if (over !== null && over > 40) {
    mk(inFaults, 'high_latency',
      `m2e ${diagRound(m2e, 1)} ms - prop ${diagRound(prop, 1)} ms = ${diagRound(over, 1)} ms overhead (>40)`);
  } else if (over === null) inSkipped.push({ rule: 'high_latency', why: 'no_m2e_p50' });

  // ── audio_out: the path OUT of this end. Only the peer can testify. ───────
  const outFaults: DiagFault[] = [];
  const outSkipped: DiagSkip[] = [];
  const capPs = w.rateOf('cap');
  const sigRms = w.avg('sig_rms');
  const micMuted = w.maxOf('mic_muted');
  const capCbPs = w.rateOf('cap_callbacks');
  if (!outBlind) {
    const peerPlayedPs = w.rateOf('peer_played');
    if (capPs === null) outSkipped.push({ rule: 'one_way_out', why: 'no_cap_ps' });
    else if (peerPlayedPs === null) outSkipped.push({ rule: 'one_way_out', why: 'no_peer_played' });
    else if (capPs / DIAG_EXPECTED_PPS >= 0.5 && peerPlayedPs === 0) {
      mk(outFaults, 'one_way_out',
        `sending ${diagRound(capPs, 0)} pkt/s but the peer played 0/s`, 'peer_report');
    }
    const lostPs = w.rateOf('peer_rx_lost');
    const recPs = w.rateOf('peer_rx_recovered');
    if (lostPs === null && recPs === null) outSkipped.push({ rule: 'audio_dropouts_out', why: 'no_peer_rx_lost' });
    else if (capPs === null || capPs <= 0) outSkipped.push({ rule: 'audio_dropouts_out', why: 'no_cap_ps' });
    else {
      const frac = ((lostPs ?? 0) + (recPs ?? 0)) / capPs;
      if (frac > 0.02) {
        mk(outFaults, 'audio_dropouts_out',
          `peer lost+recovered ${diagRound(100 * frac, 2)}% of what this end sent (>2%)`, 'peer_report');
      }
    }
  } else {
    outSkipped.push({ rule: 'one_way_out', why: outBlind });
    outSkipped.push({ rule: 'audio_dropouts_out', why: outBlind });
  }
  // Local capture faults belong to the outbound direction: they are the reason
  // the peer hears nothing, and they need no peer report to establish.
  if (micMuted === null) outSkipped.push({ rule: 'mic_muted', why: 'no_mic_muted' });
  else if (micMuted > 0) mk(outFaults, 'mic_muted', 'the microphone is muted at this end');
  if (capCbPs === null) outSkipped.push({ rule: 'capture_broken', why: 'no_cap_callbacks' });
  else if (capCbPs === 0) mk(outFaults, 'capture_broken', 'the capture callback is not firing');
  if (sigRms === null) outSkipped.push({ rule: 'mic_silent', why: 'no_sig_rms' });
  else if (sigRms < 0.0005 && (micMuted ?? 0) === 0 && (capCbPs === null || capCbPs > 0)) {
    mk(outFaults, 'mic_silent',
      `capture is running but the signal is silent (rms ${sigRms.toExponential(1)})`);
  }
  const micAccess = w.maxOf('mic_access');
  if (micAccess === null) outSkipped.push({ rule: 'mic_denied', why: 'no_mic_access' });
  else if (micAccess === 0) mk(outFaults, 'mic_denied', 'microphone permission is not granted');

  // ── video_in: the picture arriving at this end ────────────────────────────
  const vidFaults: DiagFault[] = [];
  const vidSkipped: DiagSkip[] = [];
  let vidBlind: string | null = null;
  if (videoRunning === null) vidBlind = 'no_video_counters';
  else if (!videoRunning) vidBlind = 'video_not_running';
  if (!vidBlind) {
    const shownPs = w.rateOf('v_shown');
    const decPs = w.rateOf('v_dec');
    const fragPs = vFrags;
    if (shownPs === null && decPs === null) vidSkipped.push({ rule: 'video_frozen_in', why: 'no_v_shown_or_v_dec_ps' });
    else if ((shownPs ?? decPs ?? 0) === 0 && (fragPs === null || fragPs > 0)) {
      mk(vidFaults, 'video_frozen_in', 'frames are arriving but none reached the screen');
    } else {
      const fps = shownPs ?? decPs ?? 0;
      if (fps > 0 && fps / DIAG_EXPECTED_FPS < 0.6) {
        mk(vidFaults, 'video_stutter_in',
          `${diagRound(fps, 1)} fps shown = ${diagRound(100 * fps / DIAG_EXPECTED_FPS, 0)}% of ${DIAG_EXPECTED_FPS} (<60%)`);
      }
    }
    const luma = w.avg('dec_luma');
    if (luma === null) vidSkipped.push({ rule: 'video_black_in', why: 'no_dec_luma' });
    else if (luma < 4) mk(vidFaults, 'video_black_in', `decoded luma ${diagRound(luma, 1)} -- the picture is black, not frozen`);
    const peerQ = w.avg('peer_q_level');
    const bpf = w.avg('v_bytes_frame');
    if (peerQ === null && bpf === null) vidSkipped.push({ rule: 'video_pixelated_in', why: 'no_peer_q_level_or_v_bytes_frame' });
    else if ((peerQ !== null && peerQ <= 0) || (bpf !== null && bpf < 1500)) {
      mk(vidFaults, 'video_pixelated_in',
        peerQ !== null && peerQ <= 0 ? 'the sender is pinned at its lowest quality level'
          : `${diagRound(bpf, 0)} bytes/frame is below the floor for a watchable picture`,
        peerQ !== null ? 'peer_report' : 'local');
    }
    const rxW = w.maxOf('v_rx_w');
    if (rxW === null) vidSkipped.push({ rule: 'video_low_res_in', why: 'no_v_rx_w' });
    else if (rxW > 0 && rxW < 640) mk(vidFaults, 'video_low_res_in', `arriving at ${rxW} px wide`);
    if (!latGraded) vidSkipped.push({ rule: 'video_lag', why: latWhy ?? 'latency_blind' });
    else if (g2gOver !== null && g2gOver > 90) {
      mk(vidFaults, 'video_lag',
        `g2g ${diagRound(g2g, 0)} ms - prop ${diagRound(prop, 0)} ms = ${diagRound(g2gOver, 0)} ms overhead (>90)`);
    } else if (g2gOver === null) vidSkipped.push({ rule: 'video_lag', why: 'no_g2g_p50' });
    if (!glassOk) vidSkipped.push({ rule: 'v_glass_ms_p50', why: glassCov === null ? 'no_v_glass_cov' : 'v_glass_cov_lt_0.5' });
  }

  // ── Faults that belong to the call rather than to one direction ───────────
  const route = w.maxOf('route');
  const turnOk = w.maxOf('turn_ok');
  if (route === null) endSkipped.push({ rule: 'no_route', why: 'no_route_field' });
  else if (route === 2 && turnOk === 0) mk(endFaults, 'no_route', 'relay was the only path left and TURN did not come up');
  if (route !== null && w.flips('route')) mk(endFaults, 'path_flapping', 'the media path changed inside the window');
  const relockPs = w.rateOf('relocks');
  const restartPs = w.rateOf('peer_restarts');
  if (relockPs === null && restartPs === null) endSkipped.push({ rule: 'path_flapping', why: 'no_relocks_or_peer_restarts' });
  else if ((relockPs ?? 0) > 0 || (restartPs ?? 0) > 0) {
    mk(endFaults, 'path_flapping',
      `${diagRound(relockPs ?? 0, 2)} relocks/s, ${diagRound(restartPs ?? 0, 2)} peer restarts/s`);
  }
  const crypt = w.maxOf('crypt');
  const cryptBadPs = w.rateOf('crypt_bad');
  if (crypt !== null && crypt === 0) mk(endFaults, 'crypto_broken', 'media is not encrypted');
  else if (cryptBadPs !== null && cryptBadPs > 0) mk(endFaults, 'crypto_broken', `${diagRound(cryptBadPs, 2)} packets/s failed to decrypt`);
  else if (crypt === null && cryptBadPs === null) endSkipped.push({ rule: 'crypto_broken', why: 'no_crypt_fields' });
  const fmtPs = w.rateOf('fmt_mismatch');
  if (fmtPs === null) endSkipped.push({ rule: 'version_skew', why: 'no_fmt_mismatch' });
  else if (fmtPs > 0) mk(endFaults, 'version_skew', `${diagRound(fmtPs, 2)} packets/s refused for format mismatch`);
  const renderErrPs = w.rateOf('render_errs');
  const auditDelta = w.maxOf('audit_delta');
  const enqFailPs = w.rateOf('v_enq_fail');
  if (renderErrPs !== null && renderErrPs > 0) mk(endFaults, 'internal_defect', `${diagRound(renderErrPs, 2)} render errors/s`);
  else if (auditDelta !== null && auditDelta !== 0) mk(endFaults, 'internal_defect', `sample audit off by ${auditDelta}`);
  else if (enqFailPs !== null && enqFailPs > 0) mk(endFaults, 'internal_defect', `${diagRound(enqFailPs, 2)} frames/s the window refused`);
  else if (renderErrPs === null && auditDelta === null && enqFailPs === null) {
    endSkipped.push({ rule: 'internal_defect', why: 'no_render_errs_or_audit' });
  }
  const inRate = w.maxOf('in_rate');
  const outRate = w.maxOf('out_rate');
  if (inRate === null && outRate === null) endSkipped.push({ rule: 'device_wrong', why: 'no_in_rate_or_out_rate' });
  else if ((inRate !== null && inRate !== 48000) || (outRate !== null && outRate !== 48000)) {
    mk(endFaults, 'device_wrong', `device is running at ${inRate ?? '?'} in / ${outRate ?? '?'} out, not 48000`);
  }
  const echoCorr = w.avg('echo_corr');
  const erle = w.avg('erle_db');
  const mute = w.maxOf('mute');
  if (echoCorr === null || erle === null || mute === null) {
    endSkipped.push({ rule: 'echo', why: 'no_echo_corr_erle_db_or_mute' });
  } else if (echoCorr > 0.45 && mute === 0 && erle < 6) {
    mk(endFaults, 'echo', `correlation ${diagRound(echoCorr, 2)} with only ${diagRound(erle, 1)} dB ERLE, speaker live`);
  }
  const freezePs = w.rateOf('aec_freezes');
  if (freezePs === null) endSkipped.push({ rule: 'aec_thrashing', why: 'no_aec_freezes' });
  else if (freezePs > 0.2) mk(endFaults, 'aec_thrashing', `${diagRound(freezePs, 2)} canceller freezes/s`);
  if (peerStatus === null) endSkipped.push({ rule: 'peer_left', why: 'no_peer_status' });
  else if (peerStatus === 2) mk(endFaults, 'peer_left', 'the peer left');
  else if (peerStatus === 1) mk(endFaults, 'reconnecting', 'this end is reconnecting');
  if (probes !== null && probes === 0 && recvPs === 0) {
    mk(endFaults, 'never_connected', 'no time-sync probe ever answered and nothing arrived');
  } else if (probes === null) endSkipped.push({ rule: 'never_connected', why: 'no_probe_count' });
  if (!endedCleanly && lastBeatAgeS !== null && lastBeatAgeS > 30) {
    mk(endFaults, 'dropped', `beats stopped ${lastBeatAgeS} s ago with no final beat`);
  }

  // ── Roll up. `healthy` requires the gate to have PASSED. ─────────────────
  const dir = (
    faults: DiagFault[], skipped: DiagSkip[], coverage: boolean, blind: string | null,
  ): DiagDirection => {
    // A fired fault is a finding whatever else is blind, so it is reported
    // first -- blindness cannot erase evidence that did arrive.
    if (faults.length) {
      const worst = faults.reduce((a, f) => (DIAG_RANK[f.severity] > DIAG_RANK[a.severity] ? f : a), faults[0]);
      return { verdict: worst.name, severity: worst.severity, reason: null, coverage, faults, skipped };
    }
    if (blind || !coverage) {
      return { verdict: 'unknown', severity: 'unknown', reason: blind ?? 'no_instrument',
               coverage: false, faults, skipped };
    }
    // Nothing fired -- but a rule that could not RUN is not a rule that passed,
    // and calling this direction green would be the exact shape of every green
    // metric in this project that turned out to be hiding a defect.
    if (skipped.length) {
      return { verdict: 'unknown', severity: 'unknown',
               reason: 'blind_rules:' + skipped.map((s) => s.rule).join(','),
               coverage: true, faults, skipped };
    }
    return { verdict: 'healthy', severity: 'none', reason: null, coverage: true, faults, skipped };
  };
  const directions = {
    audio_in: dir(inFaults, inSkipped, audioInCov, audioInCov ? null : 'no_inbound_instrument'),
    audio_out: dir(outFaults, outSkipped, outBlind === null, outBlind),
    video_in: dir(vidFaults, vidSkipped, vidBlind === null, vidBlind),
  };
  const coverage = {
    beats: true,
    latency: latGraded,
    audio_in: directions.audio_in.coverage,
    audio_out: directions.audio_out.coverage,
    video_in: directions.video_in.coverage,
    v_glass: glassOk,
    video_source: videoSrc !== 'none',
  };
  const faults = [...directions.audio_in.faults, ...directions.audio_out.faults,
                  ...directions.video_in.faults, ...endFaults];

  let verdict: string;
  let severity: DiagSev;
  let reason: string | null = null;
  if (faults.length) {
    const worst = faults.reduce((a, f) => (DIAG_RANK[f.severity] > DIAG_RANK[a.severity] ? f : a), faults[0]);
    verdict = worst.name; severity = worst.severity;
  } else {
    // Green with a blind instrument is not green. Video is the one exception:
    // an audio-only call is a legitimate call, so a missing picture blocks the
    // VIDEO verdict without blocking the call's. Latency, inbound audio and the
    // peer's receive report all gate `healthy`.
    const missing = (['latency', 'audio_in', 'audio_out'] as const).filter((k) => !coverage[k]);
    const blindRules = [...directions.audio_in.skipped, ...directions.audio_out.skipped,
                        ...directions.video_in.skipped, ...endSkipped];
    if (missing.length) {
      verdict = 'unknown'; severity = 'unknown';
      reason = missing.map((k) => k === 'latency' ? (latWhy ?? 'latency_blind')
        : k === 'audio_out' ? (outBlind ?? 'no_peer_report') : 'no_inbound_instrument').join(',');
    } else if (blindRules.length) {
      verdict = 'unknown'; severity = 'unknown';
      reason = 'blind_rules:' + blindRules.map((s) => s.rule).join(',');
    } else { verdict = 'healthy'; severity = 'none'; }
  }

  return {
    ...ident, verdict, severity, reason, directions, latency, coverage, faults,
    skipped: endSkipped,
    beatsInWindow: win.length, lastBeatAgeS, endedCleanly,
  };
}

/// One end saying `one_way_out` and the other not saying `one_way_in` is not a
/// tie to be broken -- the DISAGREEMENT is the finding, because one of the two
/// instruments is wrong and which one matters more than the verdict.
const DIAG_MIRROR: [string, string][] = [
  ['one_way_out', 'one_way_in'],
  ['audio_dropouts_out', 'audio_dropouts_in'],
];
export function diagnoseAgreement(ends: DiagEnd[]): { agree: boolean | null; notes: string[] } {
  if (ends.length < 2) return { agree: null, notes: ['single_end'] };
  const notes: string[] = [];
  let contradiction = false;
  let blind = false;
  for (const a of ends) {
    for (const b of ends) {
      if (a === b) continue;
      const an = new Set(a.faults.map((f) => f.name));
      const bn = new Set(b.faults.map((f) => f.name));
      for (const [out, inn] of DIAG_MIRROR) {
        if (!an.has(out)) continue;
        if (!b.directions.audio_in.coverage) {
          blind = true;
          notes.push(`${a.call} says ${out}; ${b.call} cannot see inbound audio (${b.directions.audio_in.reason ?? 'unknown'})`);
        } else if (!bn.has(inn)) {
          contradiction = true;
          notes.push(`${a.call} says ${out} but ${b.call} does not report ${inn} -- one of the two instruments is wrong`);
        } else {
          notes.push(`${a.call} ${out} matches ${b.call} ${inn}`);
        }
      }
    }
  }
  if (contradiction) return { agree: false, notes };
  if (blind) return { agree: null, notes };
  return { agree: true, notes };
}

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
    // ── Native macOS call beats ───────────────────────────────────────────────
    //
    // The web app's `beats` are one row per session event; a native call posts a
    // rolling summary of itself every five seconds and once at the end. Separate
    // table because the questions are different: "which of MY calls was bad, and
    // what was wrong with it" rather than "how is the fleet doing".
    //
    // NO ROOM CODE, EVER. On the native app the room name is the encryption salt,
    // so `call` is a per-process random id with no path back to a room.
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS mac_beats (
        id INTEGER PRIMARY KEY,
        wall REAL NOT NULL,
        install TEXT NOT NULL,
        call TEXT NOT NULL,
        version TEXT,
        model TEXT,
        phase TEXT,
        fields TEXT NOT NULL
      );
    `);
    // `pair` joins the TWO ENDS of one call, added 2026-08-24. It is the first
    // 8 hex of SHA-256("tk-pair-v1" || sharedKey), computed once at handshake:
    // both ends land on the same value, and there is no path from it back to
    // the room code or the key. Without it the two accounts of one call cannot
    // be put side by side -- `call` is per-PROCESS -- and "the damage is on the
    // path out of me" is unsayable. Same idempotent-ALTER pattern as `beats`
    // above: the table already exists in production, so CREATE cannot add it
    // and "duplicate column name" here is the expected no-op.
    try { this.sql.exec(`ALTER TABLE mac_beats ADD COLUMN pair TEXT`); } catch { /* already there */ }
    // ── How the app DIED, which no beat has ever been able to say ─────────────
    //
    // A beat describes a call that is happening. The one thing it can never
    // describe is the app not being there any more, and until now that was the
    // whole of what anybody knew about a crash on somebody else's Mac: the beats
    // stop. "Stopped beating" is also what a closed lid, a lost network and a
    // person hanging up look like, so it said nothing.
    //
    // Own table, because the questions are different: not "which of my calls was
    // bad" but "is the version we pushed this afternoon killing people's Macs".
    // That question is asked across installs and across versions, and it has to
    // be answerable from a row that has no call in it at all -- a copy that dies
    // during launch never had one.
    //
    // `incident` is the crash report's own UUID (or `run-<id>` for a death that
    // left no report), and it is UNIQUE: the client will not knowingly send one
    // twice, and a client that has lost its state file will. Better a conflict
    // the database refuses than a crash counted five times, which would make a
    // single bad build look like an outbreak.
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS mac_crashes (
        incident TEXT PRIMARY KEY,
        wall REAL NOT NULL,
        at REAL,
        install TEXT,
        kind TEXT,
        app_version TEXT,
        reporter_version TEXT,
        proc TEXT,
        model TEXT,
        os TEXT,
        exc TEXT,
        sig TEXT,
        where_sym TEXT,
        ran_ms REAL,
        crashed_call TEXT,
        fields TEXT NOT NULL
      );
    `);
    try { this.sql.exec(`CREATE INDEX IF NOT EXISTS mac_crash_wall ON mac_crashes(wall)`); } catch {}
    try { this.sql.exec(`CREATE INDEX IF NOT EXISTS mac_crash_ver ON mac_crashes(app_version, wall)`); } catch {}
    try { this.sql.exec(`CREATE INDEX IF NOT EXISTS mac_call ON mac_beats(call, wall)`); } catch {}
    try { this.sql.exec(`CREATE INDEX IF NOT EXISTS mac_wall ON mac_beats(wall)`); } catch {}
    try { this.sql.exec(`CREATE INDEX IF NOT EXISTS mac_pair ON mac_beats(pair, wall)`); } catch {}
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

    // ── Native call telemetry ────────────────────────────────────────────────
    if (url.pathname === '/mac/beat' && request.method === 'POST') {
      const b = await request.json().catch(() => null) as Record<string, unknown> | null;
      if (!b || typeof b.call !== 'string' || typeof b.install !== 'string') {
        return json({ ok: false, why: 'need call and install' }, 400);
      }
      // Anything that looks like a room code is refused rather than stored: the
      // client is not supposed to send one, and a server that quietly accepts it
      // would make the guarantee unverifiable.
      for (const k of ['room', 'secret', 'peer']) if (k in b) delete b[k];
      // `pair` is NOT a room code and is deliberately not on that list: it is a
      // one-way hash of the shared key with a fixed prefix, so it identifies
      // "these two beats are the same call" and nothing else. It gets its own
      // indexed column rather than living in `fields`, because joining the two
      // ends is a query, not a display value. Hex only, so a client that sent
      // something else cannot smuggle a room name through this door.
      const pairRaw = typeof b.pair === 'string' ? b.pair.toLowerCase() : '';
      const pair = /^[0-9a-f]{4,32}$/.test(pairRaw) ? pairRaw : null;
      delete b.pair;
      const { install, call, version, model, phase, ...rest } = b as any;
      this.sql.exec(
        `INSERT INTO mac_beats (wall, install, call, version, model, phase, pair, fields)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        Date.now() / 1000, String(install).slice(0, 40), String(call).slice(0, 40),
        String(version ?? '').slice(0, 20), String(model ?? '').slice(0, 40),
        // ── A THIRD PHASE, BECAUSE A WATCHER IS NOT A CALL ──────────────────
        //
        // 'watch' is the background agent reporting that it is alive and what it
        // did about updates. It has to be storable and it must NOT read as a
        // call: every listing below groups by `call` and would otherwise show a
        // zero-length call for every heartbeat. Anything unrecognised still
        // becomes 'live', so an older client cannot invent a phase.
        phase === 'final' ? 'final' : phase === 'watch' ? 'watch' : 'live',
        pair, packFields(rest));
      // Keep a week. Long enough for "the call on Tuesday was bad", short enough
      // that the DO stays small without a scheduled job to remember.
      this.sql.exec(`DELETE FROM mac_beats WHERE wall < ?`, Date.now() / 1000 - 7 * 86400);
      return json({ ok: true });
    }

    // ── A crash, arriving from the launch AFTER the one that died ────────────
    if (url.pathname === '/mac/crash' && request.method === 'POST') {
      const b = await request.json().catch(() => null) as Record<string, unknown> | null;
      if (!b || typeof b.install !== 'string' || typeof b.incident !== 'string') {
        return json({ ok: false, why: 'need install and incident' }, 400);
      }
      // Same refusal as the beat route: the room name is the encryption salt on
      // this app and must never leave the two machines. A crash report has no
      // business carrying one, and a server that quietly accepted it would make
      // the guarantee unverifiable.
      for (const k of ['room', 'secret', 'peer']) if (k in b) delete b[k];
      const {
        install, incident, kind, app_version: appVer, version, proc, model, os,
        exc, sig, at, ran_ms: ranMs, crashed_call: crashedCall, ...rest
      } = b as any;
      const wh = typeof (b as any).where === 'string' ? (b as any).where : null;
      // INSERT OR REPLACE on the incident: a client that lost its "already sent"
      // file re-sends, and the honest answer to the same crash twice is one row,
      // not two. The count on this table is read as "how many times did this
      // build fall over", and a duplicate there is a fabricated outbreak.
      this.sql.exec(
        `INSERT OR REPLACE INTO mac_crashes
           (incident, wall, at, install, kind, app_version, reporter_version, proc,
            model, os, exc, sig, where_sym, ran_ms, crashed_call, fields)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        String(incident).slice(0, 64), Date.now() / 1000,
        typeof at === 'number' ? at : null,
        String(install).slice(0, 40),
        kind === 'vanished' || kind === 'restart' ? kind : 'crash',
        String(appVer ?? '').slice(0, 24), String(version ?? '').slice(0, 24),
        String(proc ?? '').slice(0, 40), String(model ?? '').slice(0, 40),
        String(os ?? '').slice(0, 48), String(exc ?? '').slice(0, 40),
        String(sig ?? '').slice(0, 24), wh === null ? null : wh.slice(0, 160),
        typeof ranMs === 'number' ? ranMs : null,
        String(crashedCall ?? '').slice(0, 40) || null,
        packFields(rest, 24_000));
      // Kept a month, not a week like the beats. A beat is about a call somebody
      // remembers having; a crash is about a RELEASE, and "did 0.61 do this too"
      // is asked long after the call it happened on has been forgotten.
      this.sql.exec(`DELETE FROM mac_crashes WHERE wall < ?`, Date.now() / 1000 - 30 * 86400);
      return json({ ok: true });
    }

    // Crashes, newest first, with the call each one ended when there was one.
    if (url.pathname === '/mac/crashes') {
      const n = Math.min(200, Number(url.searchParams.get('n') ?? 40));
      const rows = [...this.sql.exec(
        `SELECT * FROM mac_crashes ORDER BY wall DESC LIMIT ?`, n)] as any[];
      // ── HOW BAD IS THIS, RIGHT NOW ───────────────────────────────────────
      //
      // The count alone cannot answer it: five crashes across five weeks and
      // five crashes this afternoon are the same number and completely
      // different news. So the day is broken out, and so is the split by
      // version -- because the question this table exists to answer is whether
      // the build that went out unattended is the one killing people.
      //
      // Broken out by kind as well, because they are not the same news and a
      // single total would make them look like it. A crash has a stack and a
      // cause; a run that vanished has neither, and a headline that called
      // eleven of those "crashes" would be training whoever reads this page to
      // stop believing the number.
      const now = Date.now() / 1000;
      const day = [...this.sql.exec(
        `SELECT COUNT(*) AS n, COUNT(DISTINCT install) AS macs,
                SUM(CASE WHEN kind = 'crash' THEN 1 ELSE 0 END) AS crashed,
                SUM(CASE WHEN kind != 'crash' THEN 1 ELSE 0 END) AS died
           FROM mac_crashes WHERE wall > ?`, now - 86400)][0] as any;
      const byVersion = [...this.sql.exec(
        `SELECT app_version AS version, kind, COUNT(*) AS n,
                COUNT(DISTINCT install) AS macs, MAX(wall) AS last
           FROM mac_crashes WHERE wall > ?
          GROUP BY app_version, kind ORDER BY n DESC LIMIT 24`, now - 7 * 86400)] as any[];
      return json({
        now,
        today: {
          total: Number(day?.n ?? 0), macs: Number(day?.macs ?? 0),
          crashes: Number(day?.crashed ?? 0), deaths: Number(day?.died ?? 0),
        },
        byVersion,
        crashes: rows.map((r) => ({
          incident: r.incident, wall: r.wall, at: r.at, install: r.install,
          kind: r.kind, appVersion: r.app_version, reporterVersion: r.reporter_version,
          proc: r.proc, model: r.model, os: r.os, exc: r.exc, sig: r.sig,
          where: r.where_sym, ranMs: r.ran_ms, crashedCall: r.crashed_call,
          ...safeParse(r.fields),
        })),
      });
    }

    // Calls with a beat in the last 90 s AND NO FINAL BEAT: still going.
    //
    // "Recent beat" alone is not the same as "in progress" -- a call that ended
    // thirty seconds ago has a recent beat too, and showed under "Happening now"
    // for a minute and a half after everyone hung up. A call that said goodbye is
    // over, whatever its timestamps say.
    if (url.pathname === '/mac/live') {
      const rows = [...this.sql.exec(
        `SELECT call, install, version, model, phase, MAX(wall) AS wall, fields
           FROM mac_beats
          WHERE wall > ? AND phase != 'watch'
            AND call NOT IN (SELECT call FROM mac_beats WHERE phase = 'final')
          GROUP BY call ORDER BY wall DESC LIMIT 40`,
        Date.now() / 1000 - 90)];
      return json({ now: Date.now() / 1000, calls: rows.map(shapeMacRow) });
    }

    // ── ONE ROW PER MAC, NOT PER CALL ───────────────────────────────────────
    //
    // "Which of my Macs is on which version, and why is that one stuck?" could
    // not be answered at all. Every view here groups by CALL, so a Mac was
    // visible only while somebody was talking on it -- and the machine being
    // asked about was precisely the one that had stopped calling. A Mac that
    // updated late and a Mac that simply made no calls produced identical
    // evidence: nothing.
    //
    // Reads every phase, so a Mac that called counts as seen just as much as one
    // that only sent a watcher heartbeat, and reports the newest update state it
    // has said anything about. `update_stage` on the newest beat can be absent
    // (a call beat carries it only if that copy checked during the call), so the
    // stage is taken from the newest beat that HAS one rather than from the
    // newest beat.
    if (url.pathname === '/mac/macs') {
      const rows = [...this.sql.exec(
        `SELECT install, version, model, phase, wall, fields
           FROM mac_beats WHERE wall > ? ORDER BY wall ASC`,
        Date.now() / 1000 - 7 * 86400)] as any[];
      const byMac = new Map<string, Record<string, unknown>>();
      for (const r of rows) {
        const f = safeParse(r.fields) as Record<string, unknown>;
        const cur: Record<string, any> = byMac.get(r.install)
          ?? { install: r.install, calls: 0, watches: 0 };
        // ASC order, so plain assignment leaves the newest value in place.
        cur.lastSeen = r.wall;
        cur.version = r.version || cur.version;
        cur.model = r.model || cur.model;
        cur.lastPhase = r.phase;
        if (r.phase === 'watch') cur.watches++;
        else if (r.phase === 'final') cur.calls++;
        // ── FACTS ARE NESTED, AND READING THEM FLAT FOUND NOTHING ───────────
        //
        // Every beat carries `facts` and `events` as their own objects, so a
        // flat `f['update_stage']` was always undefined and this view reported
        // `stage: null` for every Mac -- while the beats it was reading had the
        // stage in them the whole time. Read both: nested is where they live,
        // and top level costs nothing to allow.
        const facts = (f.facts ?? {}) as Record<string, unknown>;
        const events = (f.events ?? {}) as Record<string, unknown>;
        for (const k of ['update_stage', 'update_blocked', 'update_offered',
                         'update_installed', 'reachable_closed', 'io', 'output_route']) {
          const v = facts[k] ?? f[k];
          if (v !== undefined && v !== null && v !== '') {
            cur[k] = v;
            if (k === 'update_stage') cur.update_stage_at = r.wall;
          }
        }
        if (typeof events.update_checks === 'number') cur.update_checks = events.update_checks;
        byMac.set(r.install, cur);
      }
      const now = Date.now() / 1000;
      const macs = [...byMac.values()]
        .map((m: any) => ({ ...m, seenAgoS: Math.round(now - (m.lastSeen ?? 0)) }))
        .sort((a: any, b: any) => b.lastSeen - a.lastSeen);
      return json({ now, macs });
    }

    // One row per call, most recent first, with how long it ran.
    if (url.pathname === '/mac/recent') {
      const n = Math.min(200, Number(url.searchParams.get('n') ?? 60));
      const rows = [...this.sql.exec(
        `SELECT call, install, version, model,
                MIN(wall) AS first_wall, MAX(wall) AS wall, COUNT(*) AS beats
           FROM mac_beats WHERE phase != 'watch'
          GROUP BY call ORDER BY wall DESC LIMIT ?`, n)];
      const out = [];
      for (const r of rows as any[]) {
        // The last beat is the one worth showing: a final beat if there was one,
        // otherwise the newest live beat.
        // THE NEWEST BEAT, not the one labelled final. A client can post a live
        // beat after its final one -- and it did: the final beat landed at 53 s
        // and a live beat at 55 s carried the 1772 concealed packets that ended
        // the call. Preferring `final` showed the clean snapshot and hid the
        // reason. Ordering the server does not control is not a fact it can rely
        // on, so `ended` is reported separately from which beat is shown.
        const last = [...this.sql.exec(
          `SELECT fields, phase, version, model FROM mac_beats
             WHERE call = ? ORDER BY wall DESC LIMIT 1`, r.call)][0] as any;
        const ended = [...this.sql.exec(
          `SELECT COUNT(*) AS n FROM mac_beats WHERE call = ? AND phase = 'final'`, r.call)][0] as any;
        out.push({
          call: r.call, install: r.install, version: last?.version ?? r.version,
          model: last?.model ?? r.model, phase: last?.phase,
          startedAt: r.first_wall, endedAt: r.wall,
          endedCleanly: Number(ended?.n ?? 0) > 0 ? 1 : 0,
          durationS: Math.round((r.wall as number) - (r.first_wall as number)),
          beats: r.beats, ...safeParse(last?.fields),
        });
      }
      return json({ calls: out });
    }

    // Every beat of one call, so a bad minute can be found inside a good call.
    if (url.pathname === '/mac/call') {
      const id = url.searchParams.get('id') ?? '';
      const rows = [...this.sql.exec(
        `SELECT wall, phase, fields FROM mac_beats WHERE call = ? ORDER BY wall ASC LIMIT 2000`, id)];
      return json({ call: id, beats: (rows as any[]).map((r) => ({ wall: r.wall, phase: r.phase, ...safeParse(r.fields) })) });
    }

    // ── What is wrong with this call, in words ────────────────────────────────
    //
    // Same rows /mac/call already serves, read through the verdict layer above.
    // Zero client cost: the app posts numbers, the opinion lives here, and an
    // opinion that changes does not need every installed copy to update first.
    //
    // Default is every call with a beat in the last 90 s -- the same window
    // /mac/live uses -- so "a call is bad right now" is one request.
    if (url.pathname === '/mac/diagnose') {
      const now = Date.now() / 1000;
      const qCall = (url.searchParams.get('call') ?? '').slice(0, 40);
      const qPair = (url.searchParams.get('pair') ?? '').slice(0, 32);
      let ids: string[] = [];
      if (qCall) {
        // Asking about ONE end pulls in the other one: half of the design is
        // that the far end's beat is the only evidence about the path out.
        ids = [qCall];
        const p = [...this.sql.exec(
          `SELECT pair FROM mac_beats WHERE call = ? AND pair IS NOT NULL ORDER BY wall DESC LIMIT 1`,
          qCall)][0] as any;
        if (p?.pair) {
          ids = ([...this.sql.exec(
            `SELECT DISTINCT call FROM mac_beats WHERE pair = ? LIMIT 8`, p.pair)] as any[])
            .map((r) => String(r.call));
          if (!ids.includes(qCall)) ids.push(qCall);
        }
      } else if (qPair) {
        ids = ([...this.sql.exec(
          `SELECT DISTINCT call FROM mac_beats WHERE pair = ? LIMIT 40`, qPair)] as any[])
          .map((r) => String(r.call));
      } else {
        ids = ([...this.sql.exec(
          `SELECT call, MAX(wall) AS w FROM mac_beats WHERE wall > ?
             GROUP BY call ORDER BY w DESC LIMIT 40`, now - 90)] as any[])
          .map((r) => String(r.call));
      }

      interface DiagRow { pair: string | null; end: DiagEnd; startedAt: number; endedAt: number; }
      const rowsOut: DiagRow[] = [];
      for (const id of ids) {
        // More beats than the window needs: the window is the last 3, but
        // `dropped` and the call's own span are questions about all of them.
        const raw = [...this.sql.exec(
          `SELECT wall, phase, pair, install, version, model, fields FROM mac_beats
             WHERE call = ? ORDER BY wall DESC LIMIT 12`, id)] as any[];
        if (!raw.length) continue;
        const asc = raw.slice().reverse();
        const span = [...this.sql.exec(
          `SELECT MIN(wall) AS a, MAX(wall) AS b,
                  SUM(CASE WHEN phase = 'final' THEN 1 ELSE 0 END) AS fin
             FROM mac_beats WHERE call = ?`, id)][0] as any;
        const newest = raw[0];
        rowsOut.push({
          pair: (asc.map((r) => r.pair).filter((v: unknown) => typeof v === 'string' && v)[0] as string | undefined) ?? null,
          startedAt: Number(span?.a ?? newest.wall),
          endedAt: Number(span?.b ?? newest.wall),
          end: diagnoseEnd({
            call: id, install: newest.install, version: newest.version, model: newest.model,
            beats: asc.map((r) => ({ wall: r.wall, phase: r.phase, ...safeParse(r.fields) })),
            endedCleanly: Number(span?.fin ?? 0) > 0, now,
          }),
        });
      }

      // Group by `pair` when the ends computed one; otherwise a call is its own
      // group. One end still gets a verdict -- it just cannot be checked against
      // the other side's account of the same seconds, and `agree` says so.
      const groups = new Map<string, DiagRow[]>();
      for (const r of rowsOut) {
        const k = r.pair ? 'pair:' + r.pair : 'call:' + r.end.call;
        const g = groups.get(k);
        if (g) g.push(r); else groups.set(k, [r]);
      }
      const calls = [];
      for (const g of groups.values()) {
        const ag = diagnoseAgreement(g.map((r) => r.end));
        const startedAt = Math.min(...g.map((r) => r.startedAt));
        const endedAt = Math.max(...g.map((r) => r.endedAt));
        const worst = g.map((r) => r.end)
          .reduce((a, e) => (DIAG_RANK[e.severity] > DIAG_RANK[a.severity] ? e : a), g[0].end);
        calls.push({
          pair: g[0].pair, call: g[0].end.call,
          verdict: ag.agree === false ? 'ends_disagree' : worst.verdict,
          severity: worst.severity,
          agree: ag.agree, agreement: ag.notes,
          startedAt, endedAt, durationS: Math.round(endedAt - startedAt),
          endedCleanly: g.every((r) => r.end.endedCleanly),
          ends: g.map((r) => r.end),
        });
      }
      calls.sort((a, b) => b.endedAt - a.endedAt);
      return json({
        now, windowBeats: DIAG_WINDOW, expectedPps: DIAG_EXPECTED_PPS,
        expectedFps: DIAG_EXPECTED_FPS, calls,
      });
    }

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

    // Native Mac app — no Sec-Fetch-Site, so /api/ice 403s it. Same TURN mint,
    // same per-IP cap, no origin gate. A missing relay must never block a call:
    // the app races STUN + LAN if this returns ok:false.
    if (url.pathname === '/api/mac/turn') {
      const none = { ok: false, p2pOnly: true };
      const ip = request.headers.get('cf-connecting-ip') ?? 'local';
      const now = Date.now();
      const hits = (iceMints.get(ip) ?? []).filter((t) => now - t < ICE_MINT_WINDOW_MS);
      if (hits.length >= ICE_MINT_MAX) {
        iceMints.set(ip, hits);
        return json({ ...none, gated: 'rate' }, 429);
      }
      hits.push(now);
      iceMints.set(ip, hits);
      if (!env.TURN_KEY_ID || !env.TURN_KEY_API_TOKEN) return json(none);
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
        if (!res.ok) return json(none);
        const body = (await res.json()) as {
          iceServers?: { urls?: string | string[]; username?: string; credential?: string }[];
        };
        // Ordered by turnOrderUdp — see the rank and the measurement beside it.
        // `host`/`port` stay SCALARS on purpose: every installed client reads
        // o["port"] as one Int (Turn.swift:54, defaulting to 3478 only when the
        // key is absent), so correcting this one field switches TURN on for the
        // whole installed base without another app release. `ports` is the
        // ordered fallback list, additive and ignored by today's decoder.
        const pick = turnOrderUdp(body.iceServers);
        if (!pick) return json(none);
        return json({ ok: true, ...pick });
      } catch {
        return json(none);
      }
    }

    // Call-health beacon. POST is the client's beat; GET /summary is aggregate
    // numbers only (no per-call rows are ever served). The per-IP cap bounds a
    // hostile flooder; the DO's allowlist bounds a careless client.
    // ── Who may READ the call dashboard ──────────────────────────────────────
    //
    // The beats carry no room name, no audio and nothing identifying a person --
    // but they do say when someone was on a call and how it went, and that is the
    // operator's business rather than the public's. Ingest stays open, because the
    // app is AGPL and ships as a binary: any key embedded in it is a public key,
    // so the honest defence there is the rate limit, not a secret.
    //
    // One click to get in: open the dashboard once with ?key=..., which sets a
    // cookie and redirects to a clean URL so the key stops appearing in the
    // address bar, in history, or in a screenshot.
    const dashKey = env.MAC_DASH_KEY;
    // LOG_ADMIN_TOKEN opens this too. Not a second door: it is the SAME operator
    // credential that already dumps any room's full telemetry, which is strictly
    // more than these anonymous call beats -- so accepting it here widens
    // nothing, and the alternative was rotating MAC_DASH_KEY (which lives only
    // in a browser cookie on one Mac) every time somebody needs to read a
    // dashboard from a machine that is not that one.
    const adminTok = env.LOG_ADMIN_TOKEN;
    const dashOK = (): boolean => {
      if (!dashKey) return true;                        // unset: open, as before
      const k = url.searchParams.get('key');
      if (k === dashKey) return true;
      if (adminTok && k === adminTok) return true;
      const c = request.headers.get('cookie') ?? '';
      return c.split(';').some((p) => p.trim() === `tk_dash=${dashKey}`);
    };
    if (url.pathname === '/macos/calls' || url.pathname === '/macos/calls.html'
        || url.pathname === '/macos/calls.js') {
      if (!dashOK()) {
        return new Response(
          '<!doctype html><meta charset=utf-8><title>Tokkah calls</title>'
          + '<style>body{background:#0e1014;color:#8b93a3;font:15px/1.6 -apple-system,sans-serif;'
          + 'display:grid;place-items:center;height:100vh;margin:0;text-align:center}'
          + 'b{color:#e8eaf0;display:block;font-size:19px;margin-bottom:6px}</style>'
          + '<div><b>Tokkah calls</b>This dashboard is private.<br>Open it with the link you were given.</div>',
          { status: 403, headers: { 'content-type': 'text/html; charset=utf-8' } });
      }
      if (url.searchParams.get('key') === dashKey) {
        const clean = new URL(url); clean.searchParams.delete('key');
        return new Response(null, { status: 302, headers: {
          location: clean.pathname + (clean.search || ''),
          // A year, HttpOnly so a script cannot read it back out, Lax so a link
          // from elsewhere still works.
          'set-cookie': `tk_dash=${dashKey}; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax`,
        } });
      }
    }

    // ── Native macOS call telemetry ──────────────────────────────────────────
    //
    // Rate limited per IP like the web heartbeat: a beat every five seconds from
    // a handful of Macs is nothing, and an accident that posts in a loop should
    // cost the loop rather than the Durable Object.
    if (url.pathname === '/api/mac/beat' && request.method === 'POST') {
      const ip = request.headers.get('cf-connecting-ip') ?? 'local';
      const now = Date.now();
      const hits = (macPosts.get(ip) ?? []).filter((t) => now - t < 3600_000);
      if (hits.length >= 5000) { macPosts.set(ip, hits); return json({ error: 'rate' }, 429); }
      hits.push(now);
      macPosts.set(ip, hits);
      const body = await request.text();
      if (body.length > 16_384) return json({ error: 'too big' }, 413);
      return env.HEALTH.get(env.HEALTH.idFromName('global')).fetch(
        new Request('https://do/mac/beat', { method: 'POST', body,
          headers: { 'content-type': 'application/json' } }),
      );
    }
    // ── A crash on a Mac nobody is watching ──────────────────────────────────
    //
    // Its own route rather than a `kind` on the beat, because it is a different
    // thing: it describes a process that is already dead, it belongs to a
    // PREVIOUS run, and it must have its own rate budget (see crashPosts) so a
    // machine in a crash loop can still be heard.
    //
    // The body cap is larger than a beat's because a stack is larger than a set
    // of counters, and the client has already dropped WHOLE FIELDS to fit under
    // its own 6 KB. Anything past this is not a crash report we wrote.
    if (url.pathname === '/api/mac/crash' && request.method === 'POST') {
      const ip = request.headers.get('cf-connecting-ip') ?? 'local';
      const now = Date.now();
      const hits = (crashPosts.get(ip) ?? []).filter((t) => now - t < 3600_000);
      if (hits.length >= 200) { crashPosts.set(ip, hits); return json({ error: 'rate' }, 429); }
      hits.push(now);
      crashPosts.set(ip, hits);
      const body = await request.text();
      if (body.length > 32_768) return json({ error: 'too big' }, 413);
      return env.HEALTH.get(env.HEALTH.idFromName('global')).fetch(
        new Request('https://do/mac/crash', { method: 'POST', body,
          headers: { 'content-type': 'application/json' } }),
      );
    }
    if (url.pathname.startsWith('/api/mac/') && request.method === 'GET') {
      const tail = url.pathname.slice('/api/mac/'.length);
      if (!['live', 'recent', 'call', 'diagnose', 'crashes', 'macs'].includes(tail)) return json({ error: 'no' }, 404);
      if (!dashOK()) return json({ error: 'private' }, 403);
      return env.HEALTH.get(env.HEALTH.idFromName('global')).fetch(
        new Request(`https://do/mac/${tail}${url.search}`),
      );
    }

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

    // ── The doorbell: /api/kin/<handle>/(register|ring|poll) ─────────────────
    //
    // Deliberately its OWN path family, not a room verb. Two reasons, and the
    // second is a requirement:
    //   · a handle is not a room code, and putting it through /api/room/ would
    //     make every future room verb reachable on an inbox DO;
    //   · the room-seen registry stamp below is inside the /api/room/ match, so
    //     a ring physically cannot reach it. An inbox is not a call, and a
    //     mailbox write must never appear in the operator's "which room was
    //     live when" table — that table is for turning a complaint into a call
    //     log, and a doorbell press is not a call.
    const kin = url.pathname.match(KIN_ROUTE_RE);
    if (kin) {
      const handle = kin[1];
      const verb = kin[2];
      if (request.method !== (verb === 'poll' ? 'GET' : 'POST')) return json({ error: 'method' }, 405);
      const ip = request.headers.get('cf-connecting-ip') ?? 'local';
      if (!kinWindow(kinPosts, verb + '|' + ip, Date.now(), KIN_EDGE_WINDOW_MS, KIN_EDGE_CAP[verb])) {
        return json({ error: 'rate' }, 429);
      }
      // The handle rides along as ?to= for the same reason the room code does
      // below: the DO's URL is rewritten to https://do/<verb>, so the DO cannot
      // otherwise see which mailbox it is. It re-validates the handle itself.
      const doUrl = new URL(`https://do/kin/${verb}${url.search}`);
      doUrl.searchParams.set('to', handle);
      return env.ROOM.get(env.ROOM.idFromName('inbox:' + handle)).fetch(new Request(doUrl.toString(), request));
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
      // Immutable ONLY when the filename carries a version, because then the bytes
      // behind the URL never change. `Kin.dmg` (and the retained `Tokkah.dmg`)
      // is the stable link a human shares, so its content changes every release
      // and a year of caching would pin the world to whatever shipped first.
      // Neither stable name contains a version, so both fall to max-age=300.
      const versioned = /\d+\.\d+\.\d+/.test(rel[1]);
      h.set('cache-control', versioned
        ? 'public, max-age=31536000, immutable'
        : 'public, max-age=300');
      // By extension, not a constant. This served a disk image as application/gzip.
      h.set('content-type', rel[1].endsWith('.dmg')
        ? 'application/x-apple-diskimage'
        : 'application/gzip');
      // ── HOW BIG IS IT: THE ONE HEADER NOBODY WAS SENDING ─────────────────────
      //
      // `writeHttpMetadata` copies what R2 stored ABOUT the object -- type,
      // encoding, disposition -- and never its length. So every release has gone
      // out chunked, with no `content-length` at all, and two things that quietly
      // depended on it have been dead the whole time:
      //
      //   · the size on the front door. kin.js asks this route for a HEAD and
      //     prints `content-length / 1e6`, guarded by `bytes > 500e3` so that a
      //     404 body can never be read as a download. With no header at all the
      //     guard is never passed, the line never runs, and the hand-typed
      //     fallback in the page stands forever -- it says "1.1 MB", and the disk
      //     image is 1,514,539 bytes. The number that exists so the page cannot
      //     go stale was itself the stale one, and nothing said so.
      //   · every progress bar. A browser, `curl`, and the updater's URLSession
      //     all size a download from this header; without it a 1.5 MB fetch is an
      //     indeterminate spinner, and a truncated one is caught only later, by
      //     the SHA-256 in the signed manifest.
      //
      // Taken from `obj.size`, which is R2's own count of the bytes about to be
      // streamed, so the promise cannot disagree with the body. Guarded rather
      // than assumed: a length we are not certain of is worse than none, because
      // a client would then treat a whole file as a short one.
      if (Number.isFinite(obj.size) && obj.size > 0) h.set('content-length', String(obj.size));
      return new Response(obj.body, { headers: h });
    }
    // Short invite links: room.tokkah.com/etm-bkmb-iev (Meet-shaped, minted by
    // the client). The path IS the room. Tightly scoped to the minted format so
    // real assets (/app.js, /embed.js) can never be shadowed by a room name.
    // ── kin.tokkah.com is the front door ─────────────────────────────────────
    //
    // The product's name is Kin (0.41.0); the native app mints its invite links
    // as kin.tokkah.com/<room> and kin.tokkah.com/?r=<room>. So on that host the
    // BARE root -- no room in the path, no ?r= -- is the only URL that means
    // "nobody invited me, I came to look", and it gets the landing page. Every
    // invite shape now goes to the funnel below instead of the app shell: this
    // worker serves both hostnames, so nothing else needs to know which door
    // was used.
    //
    // /mac was the landing page's first home, for one day; a 302 keeps whatever
    // links exist alive without maintaining two copies of the page.
    if (url.pathname === '/mac' || url.pathname === '/mac.html') {
      return Response.redirect('https://kin.tokkah.com/', 302);
    }
    let assetReq = request;
    // ── AND ON room.tokkah.com TOO, WHICH WAS THE LAST BROWSER-CALL DOOR ─────
    //
    // This used to be scoped to kin.tokkah.com, so typing the older hostname
    // still opened the browser call shell -- a call UI that can no longer place
    // a call, presented as the front door. Somebody arriving there saw the
    // retired product and no way to the real one.
    //
    // The reasoning above does not depend on which hostname was typed: a bare
    // root with no room in the path and no ?r= is "nobody invited me, I came to
    // look", on either door. It is an internal rewrite rather than a redirect
    // because a front door that bounces before it opens is a worse front door.
    //
    // ?web=1 and ?hb=1 still reach the shell, which is what keeps the
    // browser-to-browser measurement rigs alive.
    if (url.pathname === '/' && !url.searchParams.has('r')
        && url.searchParams.get('web') !== '1' && !url.searchParams.has('hb')) {
      const front = new URL(url);
      // The extensionless form: the assets layer 307s '/kin.html' to '/kin'
      // (html_handling), and a front door that bounces once before opening is
      // a worse front door. '/kin' serves kin.html's bytes directly.
      front.pathname = '/kin';
      assetReq = new Request(front.toString(), request);
    }
    // ── AN INVITE LINK NO LONGER LANDS IN A BROWSER CALL ─────────────────────
    //
    // Kin, the Mac app, is the only way into a call now. An invite therefore has
    // exactly two honest destinations and neither of them is this origin's call
    // page: the app (via its URL scheme) for people who have it, or the download
    // for people who don't. /join.html is that fork; it fires the deep link on
    // load, and falls back to the DMG plus the room name in plain text.
    //
    // The two invite shapes, both minted by the app's roomURL() (main.swift):
    //   /<abc-defg-hij>   a minted 3-4-3 code -- the path IS the room
    //   /?r=<name>        any named room
    // Both are recognised on either hostname, because room.tokkah.com and
    // kin.tokkah.com are the same worker and links of both shapes are already
    // out in the world.
    //
    // NOTHING IS DELETED. The app shell is still at / and still reachable with
    // ?web=1 on an invite URL -- the browser-to-browser rigs (testbed, the
    // far-away lab room) are the only remaining users of it, and taking it away
    // would cost the measurement lane for no gain in the pivot. What ends here
    // is a browser LANDING in a call from a link somebody was sent, which is the
    // whole of the retired surface as far as an invited person can see it.
    //
    // Every backend surface the app depends on is upstream of this line and
    // untouched: /api/room/<code>/ws (signaling), /api/ice + /api/mac/turn,
    // /macos/* (manifest, install.sh, dl/), /api/* (telemetry, health).
    // ── `far-away-lab` IS A 3-4-3 CODE, AND THAT BROKE EVERY RIG ─────────────
    //
    // The permanent cross-planet room is called far-away-lab, which matches the
    // minted-invite pattern exactly -- 3 letters, 4, 3. So the funnel below
    // caught it, and the human side of the lab stopped being a call and started
    // being a download page. Every browser rig goes to `${BASE}/${ROOM}?hb=1`,
    // five call sites of it, and all five were pointed at the funnel.
    //
    // ?web=1 was the documented escape hatch and the rigs never carried it,
    // because they were written before the funnel existed. Rather than editing
    // five URLs and waiting for the sixth, `hb` counts too: it is the rig
    // heartbeat flag, nothing else sets it, and a request carrying it is by
    // definition not a person who was sent a link.
    const invitePath = /^\/[a-z]{3}-[a-z]{4}-[a-z]{3}$/.test(url.pathname);
    const inviteQuery = url.pathname === '/' && url.searchParams.has('r');
    const wantsShell = url.searchParams.get('web') === '1' || url.searchParams.has('hb');
    if ((invitePath || inviteQuery) && !wantsShell) {
      const funnel = new URL(url);
      // Extensionless, for the same reason as '/kin': the assets layer 307s
      // '/join.html' -> '/join', and one redirect before the page is a slower
      // page. The address bar keeps the ORIGINAL invite URL -- this is an
      // internal rewrite -- which is what lets /join.js read the room out of
      // the link the sender actually pasted.
      funnel.pathname = '/join';
      funnel.search = '';
      assetReq = new Request(funnel.toString(), request);
    } else if (invitePath) {
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
