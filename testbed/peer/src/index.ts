// THE FAR END OF THE PLANET, ON DEMAND.
//
// One permanent link — https://room.tokkah.com/far-away-lab — and a browser on
// the other side of the world to answer it.
//
// Why this worker exists at all: every latency number this project owned was
// measured on ONE laptop against a SIMULATED network, and the 150 ms goal turns
// on a number nobody had — what a REAL media path costs between two continents.
// A container instance is owned by a Durable Object, so the DO's placement is
// what decides which continent the browser runs on. That is the entire trick.
//
// It is a SEPARATE worker from tape-app on purpose. Production must never be
// able to break because an experiment's config was wrong, and nothing in here
// touches the app: the presence signal is the already-shipped lab channel, and
// the far peer joins through the same lobby button a person presses.
//
// ── Where "furthest" comes from ──────────────────────────────────────────────
// Measured 2026-08-23 with the deployed /api/probe?region=X&via=Y (DO->DO over
// Cloudflare's own backbone, min of 4, same-region arm subtracted):
//
//   eeur <-> oc    320 ms   <- the furthest pair this network will place
//   oc   <-> weur  280 ms
//   sam  <-> oc    225 ms
//   From the DEL edge (this operator's own city):
//   wnam 305   enam 305   sam 262   weur 207   oc 184   eeur 170   apac 81
//
// Two of those numbers are lies and the table says so: `afr` answers Delhi in
// 207 ms and Western Europe in 1 ms, and `me` answers Delhi in 266 ms — neither
// hint is being honoured, so neither is offered as a far end here. `apac`'s own
// same-region calibration arm came back at 84 ms, meaning its two probe DOs
// landed in different countries, so its corrected numbers are not trustworthy
// either. What survives is exactly the five regions in REGIONS below.
//
// The consequence worth stating out loud: eeur<->oc is 160 ms ONE WAY on the
// network alone. The 150 ms goal is already lost to propagation before the app
// runs a single line of code, which is precisely why this rig had to exist.

export interface Env {
  PEER_WNAM: DurableObjectNamespace;
  PEER_ENAM: DurableObjectNamespace;
  PEER_OC: DurableObjectNamespace;
  PEER_APAC: DurableObjectNamespace;
  PEER_AFR: DurableObjectNamespace;
  PEER_EEUR: DurableObjectNamespace;
  PEER_SAM: DurableObjectNamespace;
  LAB: DurableObjectNamespace;
  // tape-app's live-laboratory key. Read-only use here: `{"op":"drain"}` on a
  // room returns its occupant roles, which is the only presence oracle that
  // needs no change to production and holds no room slot.
  LAB_KEY?: string;
  // The cron has no Request, so it has no origin — and the container needs an
  // absolute URL to fetch its script from and report back to. A var, not a
  // guess: a wrong origin here is six blind attempts wearing a different hat.
  SELF_ORIGIN: string;
}

type RegionKey = 'wnam' | 'enam' | 'sam' | 'eeur' | 'apac';

// `constraints.regions` in wrangler.jsonc is per CLASS, and constraints are the
// half that actually binds — locationHint alone was caught putting a wnam DO in
// Mumbai, which would have turned a cross-planet measurement into a domestic
// one and reported it as US West. So there is one class per region, and this
// table is the only place the mapping lives.
// OC and AFR are deliberately absent. Both are refused outright by the container
// platform — "Regions <X> have limited capacity, and require additional
// capabilities" — so Oceania, the far half of the furthest pair the CONTROL
// plane can reach (eeur<->oc, 320 ms), will not hold a browser on this account.
// Their DO classes still exist, so the day capacity opens is a one-line change
// here and not a migration.
//
// What is left is the honest ceiling: enam <-> apac at 243 ms between two
// containers, and 305 ms from this operator's own city to wnam.
const REGIONS: Record<RegionKey, { binding: keyof Env; label: string; delhiRttMs: number }> = {
  wnam: { binding: 'PEER_WNAM', label: 'US West', delhiRttMs: 305 },
  enam: { binding: 'PEER_ENAM', label: 'US East', delhiRttMs: 305 },
  sam: { binding: 'PEER_SAM', label: 'South America', delhiRttMs: 262 },
  eeur: { binding: 'PEER_EEUR', label: 'East Europe', delhiRttMs: 170 },
  apac: { binding: 'PEER_APAC', label: 'Asia-Pacific', delhiRttMs: 81 },
};
const isRegion = (s: string): s is RegionKey => Object.prototype.hasOwnProperty.call(REGIONS, s);

// TWO permanent human links, not one, and at the SAME distance on purpose.
//
// A room holds two occupants, so one browser plus one far peer fills it — a
// second browser on the same desk would just be told the room is full. Two
// rooms means Chrome and Safari can each hold a planet-scale call at the same
// moment, which is the comparison that matters most here: the fleet's own
// numbers put video glass-to-glass at 1434 ms p50 on Chromium against 173 ms on
// WebKit, the largest split this project has. wnam and enam both measure 305 ms
// from the DEL edge, so the two lanes differ by ENGINE and not by distance —
// pick two different distances and the engine result is confounded on arrival.
const LANES: Array<{ room: string; region: RegionKey }> = [
  { room: 'far-away-lab', region: 'wnam' },
  { room: 'far-away-two', region: 'enam' },
];
const LAB_ROOM = LANES[0].room; // the link people are given
const PAIR_ROOM = 'far-away-max'; // the machine-vs-machine furthest call
const APP = 'https://room.tokkah.com';

const json = (b: unknown, status = 200): Response =>
  new Response(JSON.stringify(b), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });

// ── The script the container runs ────────────────────────────────────────────
//
// SERVED, not baked, so the experiment can change without rebuilding and
// re-pushing two gigabytes. The image only ever needs a rebuild when the MEDIA
// changes.
const JOIN_JS = String.raw`
// playwright-core first: the image installs THAT, because the base ships the
// browsers already and the full package would re-download them.
const { chromium } = (() => { try { return require('playwright-core'); }
                              catch (e) { return require('playwright'); } })();
const ROOM = process.env.ROOM, BASE = process.env.BASE, QS = process.env.EXTRA_QS || '';
const REPORT = process.env.REPORT_URL, HOLD = Number(process.env.HOLD_S || 600);
const SIDE = (process.env.SIDE || 'B').toUpperCase() === 'A' ? 'A' : 'B';
const TICK_MS = Math.max(5000, Number(process.env.TICK_MS || 15000));

const post = async (o) => { try {
  await fetch(REPORT, { method:'POST', headers:{'content-type':'application/json'},
                        body: JSON.stringify(o) });
} catch (e) { console.log('report failed', String(e)); } };

// WHERE AM I, REALLY. locationHint is advisory and constraints bind a region,
// not a city, so the container asks Cloudflare from the inside. Every latency
// number below is meaningless without this line.
const geo = async () => { try {
  const t = await fetch('https://www.cloudflare.com/cdn-cgi/trace').then((r) => r.text());
  const g = {}; for (const l of t.split('\n')) { const i = l.indexOf('=');
    if (i > 0 && ['colo','loc','ip'].includes(l.slice(0, i))) g[l.slice(0, i)] = l.slice(i + 1); }
  return g;
} catch (e) { return { err: String(e).slice(0, 80) }; } };

// One snapshot of everything a call is worth measuring. Read through the app's
// own published surface (window.__tape), never by reaching into internals — a
// rig that re-implements the thing it measures measures the rig.
const SNAP = () => {
  const t = window.__tape || {};
  const pcm = t.pcm, lane = t.lane;
  const s = pcm && typeof pcm.snapshot === 'function' ? pcm.snapshot() : pcm;
  const l = lane && typeof lane.snapshot === 'function' ? lane.snapshot() : null;
  return {
    // Connection state travels WITH the numbers, so a call that never connected
    // reports as not-connected rather than as a tempting null.
    conn: t.pc ? t.pc.connectionState : null,
    ice: t.pc ? t.pc.iceConnectionState : null,
    mouthToEarMs: (s && s.mouthToEarMs) || null,
    ringDepthMs: (s && s.m2eParts && s.m2eParts.ringDepthMs) || null,
    framesRecv: (s && s.framesRecv) || null,
    concealedMs: (s && s.concealedMs) || null,
    glassToGlassMs: (l && l.glassToGlassMs) || null,
    // framesIn > 0 is the cheap proof the fast video lane is ALIVE on this
    // path. A long-haul call once ran for weeks with the lane dead and every
    // pipeline number quoted from a lab measurement that was never in effect.
    laneFramesIn: (l && l.framesIn) || null,
    ipiP50: (l && l.ipiP50) || null,
    // §10 A-V sync, reported from the FAR end on purpose.
    //
    // The near-side rigs all send a LOOPING mjpeg file, and Chromium resets
    // VideoFrame.timestamp when the file restarts. mco is a running minimum
    // over the whole call, so a timestamp reset drifts it without bound -- which
    // is a plausible manufacturer of the -633 s .. -1636 s peerAvDeltaUs this
    // rig measured, and it would be OUR artefact rather than a user's defect.
    //
    // This container is the one peer in the fleet whose sender is a REAL webcam
    // (the human on room.tokkah.com/far-away-lab), so its receive-side view of
    // that camera is the only clean read available. If avd is sane here and
    // absurd in the other direction, the drift is the looping file; if it is
    // absurd here too, it is the app.
    peerAvDeltaUs: (l && l.peerAvDeltaUs) ?? null,
    avEngaged: (l && l.avEngaged) ?? null,
    avGaveUp: (l && l.avGaveUp) ?? null,
    avHolds: (l && l.avHolds) ?? null,
    avPresents: (l && l.avPresents) ?? null,
    avMapRejects: (l && l.avMapRejects) ?? null,
    avMapErrMs: (l && l.avMapErrMs) ?? null,
    mcoReanchors: (l && l.mcoReanchors) ?? null,
    // The 30-fps-in, 10-fps-out accounting, as cumulative counters so two
    // reports can be differenced into a rate.
    framesEncoded: (l && l.framesEncoded) ?? null,
    framesSkipped: (l && l.framesSkipped) ?? null,
    framesOut: (l && l.framesOut) ?? null,
    achievedFps: (l && l.achievedFps) ?? null,
    vp: (l && l.vp) ? { p: l.vp.presents, s: l.vp.skips, d: l.vp.drops, e: l.vp.early, r: l.vp.resyncs } : null,
    // WHY, not just WHETHER. A null m2e has two completely different meanings —
    // "the lane is up and has not measured yet" and "the lane is dead on this
    // path" — and an instrument that returns the same value for both points
    // investigation in the wrong direction. It already did once here: the first
    // cross-planet call on this rig reported ICE connected, 17,000 packets
    // received, and every pipeline number null, which reads like a broken rig
    // and is in fact a real defect.
    tapeMode: t.tapeMode || null,
    pcmUp: !!s,
    // The container's own account of why a lane is not running, in the lane's
    // own words. Without this the far end reports nulls and the near end reports
    // "the peer said no", and neither says WHICH capability was missing — which
    // is a whole debugging arc spent guessing at a headless browser from 15,000
    // km away.
    diag: (() => {
      const m = (t.tel && t.tel.mirror) || [];
      const want = /fallback|unsupported|watchdog|mismatch|tape-start|gum/;
      const rows = m.filter((e) => e && typeof e.kind === 'string' && want.test(e.kind)).slice(-8)
                    .map((e) => { const o = { k: e.kind }; for (const [kk, vv] of Object.entries(e)) {
                      if (kk !== 'kind' && kk !== 't' && typeof vv !== 'object') o[kk] = vv; } return o; });
      return { rows,
        // The three environment facts a headless container can plausibly fail:
        // a secure context (the lanes require one), an encoded-transform API for
        // the video carrier, and an actual audio OUTPUT device for the playout
        // ring. A no-audio fallback means frames arrived and none ever played.
        secure: isSecureContext,
        xform: typeof RTCRtpScriptTransform !== 'undefined',
        enc: typeof VideoEncoder !== 'undefined',
        vTracks: (() => { try { const v = document.querySelector('video');
          return v && v.srcObject ? v.srcObject.getVideoTracks().length : -1; } catch (e) { return -2; } })(),
        outs: -1,
      };
    })(),
  };
};

// The ICE pair is the whole point: which route carried it, and what the network
// itself cost on that route.
const ICE = async () => {
  const pc = (window.__tape && window.__tape.pc) || null;
  if (!pc || !pc.getStats) return { pc: false };
  const st = await pc.getStats(); let pair = null, inb = null;
  st.forEach((r) => {
    if (r.type === 'candidate-pair' && r.state === 'succeeded' && (r.nominated || !pair)) pair = r;
    if (r.type === 'inbound-rtp' && r.kind === 'audio') inb = r;
  });
  const out = { pktsRecv: (inb && inb.packetsReceived) || null };
  if (!pair) return out;
  const L = st.get(pair.localCandidateId), R = st.get(pair.remoteCandidateId);
  return Object.assign(out, {
    local: L && L.candidateType, remote: R && R.candidateType, proto: L && L.protocol,
    rttMs: pair.currentRoundTripTime != null ? Math.round(pair.currentRoundTripTime * 1000) : null,
  });
};

(async () => {
  const where = await geo();
  await post({ kind: 'start', side: SIDE, room: ROOM, qs: QS, holdS: HOLD, geo: where });
  let b;
  try {
    b = await chromium.launch({ args: [
      '--use-fake-ui-for-media-stream','--use-fake-device-for-media-stream',
      // A REAL talking head and REAL speech as the camera and microphone, the
      // same files the local rigs use. SIDE picks the speaker, so a
      // container-to-container call carries two different people the way an
      // actual conversation does; Chromium's synthetic pattern and beep
      // compress to almost nothing and would measure an empty pipe.
      '--use-file-for-fake-video-capture=/peer/media/real' + SIDE + '.mjpeg',
      '--use-file-for-fake-audio-capture=/peer/media/real' + SIDE + '.wav',
      '--autoplay-policy=no-user-gesture-required','--no-sandbox',
      // Headless Chrome may skip the audio render pipeline entirely without an
      // output device, which would show up as silence for the wrong reason.
      '--alsa-output-device=null',
      '--disable-features=WebRtcHideLocalIpsWithMdns',
      // Same GPU flags the local rig launches with. Both ends of a measurement
      // have to be the same browser configured the same way, or the comparison
      // is between two machines and not between two places.
      '--use-gl=angle', '--enable-gpu',
    ]});
    const url = BASE + '/' + ROOM + '?hb=1' + (QS ? '&' + QS : '');
    const deadline = Date.now() + HOLD * 1000;
    let page = null, rejoins = 0, dead = 0, ticks = 0;

    const open = async () => {
      if (page) { try { await page.close(); } catch (e) { /* already gone */ } }
      page = await b.newPage();
      page.on('console', (m) => { if (m.type() === 'error') console.log('[page]', m.text().slice(0, 160)); });
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
      // The join button is the same one a person presses; driving the real UI
      // keeps this honest rather than reaching into internals to fake a call.
      await page.waitForSelector('#join', { timeout: 30000 }).catch(() => {});
      await page.click('#join', { timeout: 30000 }).catch(() => {});
    };
    await open();

    // PERIODIC, not once-at-the-end. A metric sampled on a state change is a
    // birth certificate, not a health record — and a rig that only speaks when
    // it finishes is indistinguishable from a rig that died.
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, TICK_MS));
      ticks++;
      let snap = null, ice = null;
      try {
        snap = await page.evaluate(SNAP);
        ice = await page.evaluate(ICE);
      } catch (e) { snap = { err: String(e).slice(0, 120) }; }
      await post({ kind: 'tick', side: SIDE, room: ROOM, n: ticks, geo: where,
                   rejoins, snap, ice, leftS: Math.round((deadline - Date.now()) / 1000) });
      // AUTO-REJOIN. An idle signaling socket dies, a background tab is
      // throttled, a DO restarts — and a far peer that quietly stops being in
      // the room turns every later measurement into a measurement of nothing.
      // Three consecutive dead ticks, so one transient does not re-negotiate a
      // healthy call out from under itself.
      const live = snap && (snap.conn === 'connected' || snap.conn === 'connecting' || snap.conn === 'new');
      dead = live ? 0 : dead + 1;
      if (dead >= 3 && Date.now() < deadline - 20000) {
        rejoins++; dead = 0;
        await post({ kind: 'rejoin', side: SIDE, room: ROOM, n: rejoins });
        await open();
      }
    }
    await post({ kind: 'done', side: SIDE, room: ROOM, ticks, rejoins, geo: where,
                 snap: await page.evaluate(SNAP).catch(() => null),
                 ice: await page.evaluate(ICE).catch(() => null) });
  } catch (e) {
    await post({ kind: 'error', side: SIDE, room: ROOM, error: String(e && e.stack || e).slice(0, 900) });
  } finally { if (b) await b.close().catch(() => {}); }
})();
`;

// ── One container, one continent ─────────────────────────────────────────────
//
// A base class, five exported subclasses. The subclass NAME is what wrangler
// binds a `constraints.regions` block to, so the region is pinned in config and
// cannot be talked out of by a runtime argument.
abstract class PeerBase implements DurableObject {
  constructor(protected state: DurableObjectState, protected env: Env) {}

  // Re-arms itself until the deadline. The only job is to exist: a container
  // outlives only as long as the Durable Object that owns it, and a DO that
  // goes idle mid-way through a cold image pull abandons the container before
  // it ever runs. A pull into a region that has never seen this image takes
  // MINUTES, so that window is wide.
  async alarm(): Promise<void> {
    const deadline = (await this.state.storage.get('deadline')) as number | undefined;
    if (deadline && Date.now() < deadline) await this.state.storage.setAlarm(Date.now() + 20_000);
  }

  private ctr() {
    return (this.state as unknown as { container?: {
      running: boolean;
      start(o?: { env?: Record<string, string>; enableInternet?: boolean }): void;
      monitor(): Promise<unknown>;
      destroy(): Promise<void>;
    } }).container;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const c = this.ctr();
    if (!c) return json({ error: 'no container binding on this class' }, 500);

    if (url.pathname === '/stop') {
      await c.destroy().catch(() => {});
      await this.state.storage.deleteAll();
      return json({ stopped: true });
    }
    if (url.pathname === '/status') {
      return json({ running: c.running, deadline: (await this.state.storage.get('deadline')) ?? null });
    }
    if (url.pathname === '/call') {
      const q = (k: string, d = '') => url.searchParams.get(k) ?? d;
      const holdS = Math.max(60, Math.min(21_600, Number(q('hold', '900')) || 900));
      if (c.running) await c.destroy().catch(() => {});
      // ENV ONLY -- NO ENTRYPOINT. Five attempts died passing `entrypoint`, and
      // staged reporting finally proved the override is silently DISCARDED: not
      // even its first line ever ran while the container reported itself
      // healthy running the image's own CMD forever.
      c.start({
        // A container gets NO outbound network unless this is set. Its config
        // reads back `assign_ipv4: none, mode: private`, which is why six
        // attempts saw perfect silence: everything it tried to reach was
        // unreachable — including, fatally for a WEBRTC peer, the internet.
        enableInternet: true,
        env: {
          // `join` overrides the browser script so a native UDP far-peer can
          // run in the same container without a new image.
          JOIN_URL: q('join') || `${q('self')}/join.js`,
          // The report target is a SINGLE Durable Object, addressed by name and
          // nothing else. The previous design keyed it by region+generation and
          // a far peer that ran perfectly in Seattle posted into the wrong
          // mailbox — a whole debugging arc spent reading an empty inbox next
          // to the full one. One mailbox cannot be missed.
          REPORT_URL: `${q('self')}/report?region=${q('region')}&slot=${encodeURIComponent(q('slot'))}&run=${q('run')}`,
          ROOM: q('room', LAB_ROOM), BASE: q('base', APP), EXTRA_QS: q('qs'),
          SIDE: q('side', 'B'), HOLD_S: String(holdS), TICK_MS: q('tick', '15000'),
        },
      });
      // monitor() resolves when the container exits, so holding it keeps the DO
      // awake exactly as long as the call needs and no longer. The alarm chain
      // above is the belt to this brace.
      this.state.waitUntil(c.monitor().catch(() => {}));
      await this.state.storage.put('deadline', Date.now() + (holdS + 300) * 1000);
      await this.state.storage.setAlarm(Date.now() + 20_000);
      return json({ started: true, holdS });
    }
    if (!c.running) c.start({ enableInternet: true });
    return json({ running: c.running });
  }
}
export class PeerWnam extends PeerBase {}
export class PeerEnam extends PeerBase {}
export class PeerSam extends PeerBase {}
export class PeerEeur extends PeerBase {}
// Provisioned, no container attached: OC will not take one on this account.
// The class stays so switching Oceania on later is a config change, not a
// Durable Object migration.
export class PeerOc extends PeerBase {}
export class PeerApac extends PeerBase {}
export class PeerAfr extends PeerBase {}

// ── The one mailbox, and the keeper's memory ─────────────────────────────────
export class LabState implements DurableObject {
  constructor(private state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === '/report' && request.method === 'POST') {
      // Two shapes arrive here. The image's shell posts stage pings with the
      // stage name in the query and the detail as a PLAIN-TEXT body, because an
      // earlier version interpolated it into a JSON literal and every stack
      // trace — which all contain quotes and newlines — destroyed the message
      // it was meant to carry. join.js posts real JSON.
      const stage = url.searchParams.get('stage');
      const body = stage
        ? { kind: 'stage', stage, detail: (await request.text().catch(() => '')).slice(0, 600) }
        : ((await request.json().catch(() => ({}))) as Record<string, unknown>);
      const region = url.searchParams.get('region') ?? '?';
      const run = url.searchParams.get('run') ?? '?';
      // Falls back to the region alone so a container started by an older
      // worker version still lands somewhere readable rather than under '?'.
      const key = url.searchParams.get('slot') || region;
      const row = { at: Date.now(), region, slot: key, run, ...body };
      const log = ((await this.state.storage.get('log')) as unknown[]) ?? [];
      log.push(row);
      // 120, not 400. A single storage value caps at 128 KiB and these rows
      // carry a snapshot each, so a generous ring is a write that fails —
      // silently losing the log it was meant to keep.
      await this.state.storage.put('log', log.slice(-120));
      // Latest-per-region is what the console renders; scanning the ring on
      // every poll is work the reader should not have to do.
      const latest = ((await this.state.storage.get('latest')) as Record<string, unknown>) ?? {};
      latest[key] = row;
      await this.state.storage.put('latest', latest);
      // PRESENCE IS A SEPARATE KEY, and this is not a tidiness point.
      // `latest` is overwritten by the image's boot STAGE pings too, which
      // carry no room — so a keeper reading `latest` sees "not in the room"
      // for the whole 30-90 s a container takes to boot, summons another one
      // on top of it, and churns forever. Only a join.js frame, which names
      // the room it is actually in, counts as being there.
      const kind = String((body as { kind?: unknown }).kind ?? '');
      if (kind === 'start' || kind === 'tick' || kind === 'rejoin') {
        const seen = ((await this.state.storage.get('peerAt')) as Record<string, unknown>) ?? {};
        seen[key] = { at: Date.now(), room: (body as { room?: string }).room ?? null, kind, run };
        await this.state.storage.put('peerAt', seen);
      }
      return json({ stored: true });
    }
    if (url.pathname === '/log') {
      const n = Math.max(1, Math.min(400, Number(url.searchParams.get('n')) || 60));
      const log = ((await this.state.storage.get('log')) as unknown[]) ?? [];
      return json({ log: log.slice(-n) });
    }
    if (url.pathname === '/latest') {
      return json({
        latest: (await this.state.storage.get('latest')) ?? {},
        peerAt: (await this.state.storage.get('peerAt')) ?? {},
        keeper: (await this.state.storage.get('keeper')) ?? {},
      });
    }
    if (url.pathname === '/keeper' && request.method === 'POST') {
      const patch = (await request.json().catch(() => ({}))) as Record<string, unknown>;
      const cur = ((await this.state.storage.get('keeper')) as Record<string, unknown>) ?? {};
      const next = { ...cur, ...patch };
      await this.state.storage.put('keeper', next);
      return json({ keeper: next });
    }
    if (url.pathname === '/reset') {
      await this.state.storage.deleteAll();
      return json({ reset: true });
    }
    return json({ error: 'no such path' }, 404);
  }
}

// ── Helpers shared by the HTTP surface and the cron ──────────────────────────

const labDO = (env: Env) => env.LAB.get(env.LAB.idFromName('lab-v1'));

// THE ROOM IS PART OF THE IDENTITY, and leaving it out cost a whole experiment.
//
// The name used to be `peer-<region>-<gen>`, so a container was identified by
// WHERE it runs and nothing else. The keeper's second lane owns `enam`; an A/B
// running in a different room also asked for `enam`; both resolved to the same
// Durable Object, and the moment the keeper saw ITS room empty it issued a stop
// that destroyed the experiment's peer instead — 17 s after it had connected,
// with no error anywhere, because from the platform's point of view nothing had
// gone wrong. The slow reaper added minutes earlier turned that from a one-off
// into every five minutes, forever.
//
// Region decides placement; room decides identity. Two peers in one region are
// now two different objects.
const peerStub = (env: Env, region: RegionKey, room: string, gen: string) => {
  const ns = env[REGIONS[region].binding] as DurableObjectNamespace;
  // `gen` forces a FRESH Durable Object. Placement is decided once, when a DO
  // is first created, so an instance already sitting in the wrong city stays
  // there no matter what the config later says. Bumping gen is the only way to
  // re-roll placement without deleting the namespace.
  return ns.get(ns.idFromName(`peer-${region}-${room}-${gen}`),
    { locationHint: region } as DurableObjectNamespaceGetDurableObjectOptions);
};

// Reports are keyed the same way, for the same reason: two peers in one region
// writing one `latest[region]` slot means each erases the other's presence, and
// the keeper reads presence to decide whether to summon.
const slot = (region: string, room: string) => `${region}|${room}`;

// The presence oracle. tape-app's lab channel answers `{"op":"drain"}` with the
// occupant ROLES of a room — which is presence without holding a room slot, and
// without one line of change in production.
async function occupants(env: Env, room: string): Promise<{ peers: string[]; err?: string }> {
  if (!env.LAB_KEY) return { peers: [], err: 'LAB_KEY not configured' };
  try {
    const r = await fetch(`${APP}/api/room/${room}/lab`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-lab-key': env.LAB_KEY },
      body: JSON.stringify({ op: 'drain' }),
    });
    const j = (await r.json()) as { peers?: string[]; error?: string };
    if (!r.ok) return { peers: [], err: j.error ?? `http ${r.status}` };
    return { peers: Array.isArray(j.peers) ? j.peers : [] };
  } catch (e) {
    return { peers: [], err: String(e).slice(0, 120) };
  }
}

async function summon(env: Env, origin: string, o: {
  region: RegionKey; room: string; side?: string; hold?: string; qs?: string; gen?: string; tick?: string; join?: string;
}): Promise<unknown> {
  const gen = o.gen ?? '1';
  const run = `${o.region}-${Date.now()}`;
  const u = new URL(`${origin}/call`);
  u.searchParams.set('self', origin);
  u.searchParams.set('region', o.region);
  u.searchParams.set('room', o.room);
  u.searchParams.set('side', o.side ?? 'B');
  u.searchParams.set('hold', o.hold ?? '900');
  u.searchParams.set('qs', o.qs ?? '');
  u.searchParams.set('tick', o.tick ?? '15000');
  u.searchParams.set('run', run);
  u.searchParams.set('slot', slot(o.region, o.room));
  if (o.join) u.searchParams.set('join', o.join);
  const res = await peerStub(env, o.region, o.room, gen).fetch(u.toString());
  const body = await res.json().catch(() => ({}));
  await labDO(env).fetch(`https://do/keeper`, {
    method: 'POST',
    body: JSON.stringify({ [`summoned_${slot(o.region, o.room)}`]: { at: Date.now(), room: o.room, run, gen } }),
  });
  return { region: o.region, room: o.room, run, gen, container: body };
}

// ── The console ──────────────────────────────────────────────────────────────
const PAGE = String.raw`<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Tokkah — far-away lab</title><style>
:root{--bg:#0b0d10;--fg:#e8eaed;--dim:#9aa0a6;--ok:#34d399;--warn:#fbbf24;--bad:#f87171;--line:#22262b;--card:#12151a}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace}
main{max-width:940px;margin:0 auto;padding:28px 18px 60px}
h1{font-size:19px;margin:0 0 4px;letter-spacing:.2px}
p.sub{color:var(--dim);margin:0 0 22px}
a{color:#7dd3fc}
.link{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin:0 0 22px}
.link b{font-size:16px}
table{width:100%;border-collapse:collapse;margin:0 0 8px}
th,td{text-align:left;padding:7px 8px;border-bottom:1px solid var(--line);font-size:13px}
th{color:var(--dim);font-weight:400}
button{background:#1b2027;color:var(--fg);border:1px solid var(--line);border-radius:7px;padding:5px 11px;cursor:pointer;font:inherit;font-size:12px}
button:hover{background:#242a33}button[disabled]{opacity:.45;cursor:default}
.g{color:var(--ok)}.y{color:var(--warn)}.r{color:var(--bad)}.d{color:var(--dim)}
h2{font-size:13px;color:var(--dim);font-weight:400;margin:26px 0 8px;text-transform:uppercase;letter-spacing:.9px}
pre{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;overflow:auto;max-height:340px;font-size:12px;margin:0}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:0 0 10px}
input,select{background:#1b2027;color:var(--fg);border:1px solid var(--line);border-radius:7px;padding:5px 8px;font:inherit;font-size:12px}
</style></head><body><main>
<h1>far-away lab</h1>
<p class=sub>A real call, on real Cloudflare hardware, from as far away as this network will place a browser.</p>

<div class=link>
  <b><a href="https://room.tokkah.com/far-away-lab">room.tokkah.com/far-away-lab</a></b>
  &nbsp;<span class=d>&rarr; a browser in <b>US West</b>, 305 ms away</span><br>
  <b><a href="https://room.tokkah.com/far-away-two">room.tokkah.com/far-away-two</a></b>
  &nbsp;<span class=d>&rarr; a browser in <b>US East</b>, 305 ms away</span>
  <p class=d style="margin:10px 0 0">Both permanent, both always the latest deploy. Open one, press <i>Start a call</i>,
  and within a minute the peer that answers is a real browser on another continent — summoned while you are in the room,
  torn down when you leave. <b>Two links because a room holds two people:</b> one browser plus one far peer fills it, so
  put Chrome on the first and Safari on the second and both get their own planet-scale call.
  Same distance on both, deliberately — so what differs between them is the <i>engine</i> and not the route.</p>
</div>

<h2>far ends — measured, not assumed</h2>
<table id=regions><thead><tr><th>region</th><th>place</th><th>RTT from Delhi</th><th>one-way</th><th>container</th><th></th></tr></thead><tbody></tbody></table>
<p class=d style="margin:0 0 4px">RTT is Cloudflare backbone, DO&rarr;DO, min of 4 samples, measured from the DEL edge.
<b>eeur&harr;oc = 320&nbsp;ms</b> is the furthest pair the network will <i>route</i>, but OC will not take a container, so
the furthest a browser goes is <b>enam&harr;apac, 243&nbsp;ms</b>. Either way one-way exceeds 150&nbsp;ms on propagation
alone — the goal is lost before the app runs a line. <span class=d>Every row's real city comes from the container's own
<code>cdn-cgi/trace</code>, not from the region name.</span></p>

<h2>the machine-only furthest call</h2>
<div class=row>
  <span class=d>enam &harr; apac in <code>far-away-max</code> (243&nbsp;ms) &mdash; both ends a real recorded human, no laptop involved.</span>
  <input id=pairhold value=300 size=4 title="seconds"> <button id=pair>run the pair</button>
</div>

<h2>live</h2>
<div class=row>
  <span id=presence class=d>presence …</span>
  <button id=refresh>refresh</button>
  <button id=stopall>stop everything</button>
</div>
<pre id=out>loading…</pre>
</main><script>
const $ = (s) => document.querySelector(s);
const fmt = (v) => v == null ? '<span class=d>–</span>' : v;
let REG = {};

async function draw() {
  const s = await fetch('/api/state').then((r) => r.json());
  REG = s.regions;
  const tb = $('#regions tbody'); tb.innerHTML = '';
  for (const [k, r] of Object.entries(s.regions)) {
    // latest is keyed region|room since two peers can share a region; show
    // this region's most recent row whichever room it was in. (No backticks in
    // this block -- it lives inside a String.raw template and a stray one ends
    // the literal, which has now broken this build twice.)
    const l = Object.entries(s.latest).filter(([key]) => key === k || key.startsWith(k + '|'))
      .map(([, v]) => v).sort((a, b) => b.at - a.at)[0];
    const live = l && (Date.now() - l.at) < 90000;
    const snap = l && l.snap || {};
    const geo = (l && l.geo && l.geo.colo) ? l.geo.colo + '/' + (l.geo.loc || '?') : null;
    const cls = live ? (snap.conn === 'connected' ? 'g' : 'y') : 'd';
    const state = !l ? '<span class=d>idle</span>'
      : '<span class=' + cls + '>' + (live ? (snap.conn || l.kind || l.stage || 'up') : 'last ' + Math.round((Date.now() - l.at) / 1000) + 's ago') + '</span>'
        + (l.room ? ' <span class=d>' + l.room + '</span>' : '')
        + (geo ? ' <span class=d>' + geo + '</span>' : '')
        + (snap.mouthToEarMs ? ' <span class=d>m2e ' + Math.round(snap.mouthToEarMs) + 'ms</span>' : '')
        + (snap.glassToGlassMs ? ' <span class=d>g2g ' + Math.round(snap.glassToGlassMs) + 'ms</span>' : '')
        + (l.ice && l.ice.rttMs ? ' <span class=d>ice ' + l.ice.rttMs + 'ms</span>' : '');
    tb.insertAdjacentHTML('beforeend', '<tr><td>' + k + '</td><td class=d>' + r.label + '</td><td>' + r.delhiRttMs
      + ' ms</td><td class=d>' + Math.round(r.delhiRttMs / 2) + ' ms</td><td>' + state
      + '</td><td><button data-r="' + k + '">summon</button></td></tr>');
  }
  $('#presence').innerHTML = (s.lanes || []).map((L) => {
    const p = s.presence[L.room] || { peers: [] };
    return 'room <code>' + L.room + '</code> (' + L.region + '): ' + (p.err ? '<span class=r>' + p.err + '</span>'
      : p.peers.length ? '<span class=g>' + p.peers.length + ' in [' + p.peers.join(',') + ']</span>' : '<span class=d>empty</span>');
  }).join(' &nbsp;·&nbsp; ');
  $('#out').textContent = s.log.slice(-40).reverse().map((r) =>
    new Date(r.at).toISOString().slice(11, 19) + '  ' + (r.region || '?').padEnd(5) + ' ' + (r.kind || '') +
    (r.stage ? ':' + r.stage : '') + '  ' +
    JSON.stringify(r.snap || r.ice || r.detail || r.geo || r.error || '').slice(0, 200)).join('\n');
  for (const b of document.querySelectorAll('#regions button')) {
    b.onclick = async () => { b.disabled = true; b.textContent = '…';
      await fetch('/api/summon?region=' + b.dataset.r + '&hold=1800').then((r) => r.json());
      setTimeout(draw, 1200); };
  }
}
$('#refresh').onclick = draw;
$('#stopall').onclick = async () => { await fetch('/api/stopall').then((r) => r.json()); setTimeout(draw, 800); };
$('#pair').onclick = async (e) => { e.target.disabled = true; e.target.textContent = 'starting…';
  await fetch('/api/pair?hold=' + ($('#pairhold').value || 300)).then((r) => r.json());
  e.target.disabled = false; e.target.textContent = 'run the pair'; setTimeout(draw, 1500); };
draw(); setInterval(draw, 6000);
</script></body></html>`;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const origin = url.origin;

    if (url.pathname === '/join.js') {
      return new Response(JOIN_JS, { headers: { 'content-type': 'application/javascript', 'cache-control': 'no-store' } });
    }
    if (url.pathname === '/' || url.pathname === '/index.html') {
      return new Response(PAGE, { headers: { 'content-type': 'text/html;charset=utf-8', 'cache-control': 'no-store' } });
    }
    // The container's mailbox. Anyone can post here, which is deliberate: the
    // alternative is a credential inside an image, and the blast radius of a
    // forged row is a wrong line in a debug log.
    if (url.pathname === '/report') {
      // Read it out rather than forwarding the stream: the body is a few
      // hundred bytes and a subrequest that inherits content-length from a
      // stream it no longer owns is a failure mode with nothing to gain.
      const raw = await request.text().catch(() => '');
      return labDO(env).fetch(`https://do/report${url.search}`, {
        method: 'POST', body: raw,
        headers: { 'content-type': request.headers.get('content-type') ?? 'text/plain' },
      });
    }
    if (url.pathname === '/api/state') {
      const [latest, log, ...pres] = await Promise.all([
        labDO(env).fetch('https://do/latest').then((r) => r.json()) as Promise<{ latest: Record<string, unknown>; peerAt: Record<string, unknown>; keeper: unknown }>,
        labDO(env).fetch('https://do/log?n=80').then((r) => r.json()) as Promise<{ log: unknown[] }>,
        ...LANES.map((l) => occupants(env, l.room)),
      ]);
      const presence: Record<string, unknown> = {};
      LANES.forEach((l, i) => { presence[l.room] = pres[i]; });
      return json({ regions: REGIONS, lanes: LANES, labRoom: LAB_ROOM, pairRoom: PAIR_ROOM,
                    latest: latest.latest, peerAt: latest.peerAt, keeper: latest.keeper,
                    log: log.log, presence });
    }
    if (url.pathname === '/api/log') {
      return labDO(env).fetch(`https://do/log${url.search}`);
    }
    if (url.pathname === '/api/summon') {
      const region = url.searchParams.get('region') ?? 'wnam';
      if (!isRegion(region)) return json({ error: 'bad region', allowed: Object.keys(REGIONS) }, 400);
      return json(await summon(env, origin, {
        region,
        room: url.searchParams.get('room') ?? LAB_ROOM,
        side: url.searchParams.get('side') ?? 'B',
        hold: url.searchParams.get('hold') ?? '1800',
        qs: url.searchParams.get('qs') ?? '',
        gen: url.searchParams.get('gen') ?? '1',
        tick: url.searchParams.get('tick') ?? '15000',
        join: url.searchParams.get('join') ?? '',
      }));
    }
    // THE FURTHEST CALL ON EARTH THAT THIS NETWORK CAN PLACE: two containers,
    // 320 ms apart, two different recorded humans, no laptop anywhere in it.
    if (url.pathname === '/api/pair') {
      // enam <-> apac, 243 ms measured, is the furthest pair a container can be
      // placed in on this account. eeur <-> oc is 320 ms and would have been the
      // answer, but OC will not take a container at all.
      const a = url.searchParams.get('a') ?? 'enam';
      const b = url.searchParams.get('b') ?? 'apac';
      if (!isRegion(a) || !isRegion(b) || a === b) return json({ error: 'bad pair' }, 400);
      const room = url.searchParams.get('room') ?? PAIR_ROOM;
      const hold = url.searchParams.get('hold') ?? '300';
      const gen = url.searchParams.get('gen') ?? '1';
      const A = await summon(env, origin, { region: a, room, side: 'A', hold, gen });
      const B = await summon(env, origin, { region: b, room, side: 'B', hold, gen });
      return json({ pair: [a, b], room, hold, a: A, b: B });
    }
    if (url.pathname === '/api/stop') {
      const region = url.searchParams.get('region') ?? '';
      if (!isRegion(region)) return json({ error: 'bad region' }, 400);
      const room = url.searchParams.get('room') ?? LAB_ROOM;
      const gen = url.searchParams.get('gen') ?? '1';
      // `legacy=1` addresses the PRE-room-scoped name (`peer-<region>-<gen>`).
      // Renaming an identity orphans whatever is already running under the old
      // one: it keeps its container, keeps holding a room slot, and no amount of
      // asking the new name will stop it. Kept as a named door rather than a
      // one-off script, because the next rename will do this again.
      const ns = env[REGIONS[region].binding] as DurableObjectNamespace;
      const stub = url.searchParams.get('legacy') === '1'
        ? ns.get(ns.idFromName(`peer-${region}-${gen}`),
          { locationHint: region } as DurableObjectNamespaceGetDurableObjectOptions)
        : peerStub(env, region, room, gen);
      const r = await stub.fetch('https://do/stop');
      return json({ region, room, legacy: url.searchParams.get('legacy') === '1',
                    stopped: await r.json().catch(() => null) });
    }
    if (url.pathname === '/api/stopall') {
      // Every region across every room this worker knows about. Identity is
      // (region, room) now, so a sweep has to name the rooms or it misses
      // exactly the peers a sweep exists to catch. `room=` adds an ad-hoc one
      // (an experiment's own room) to the list.
      const rooms = new Set([...LANES.map((l) => l.room), PAIR_ROOM]);
      const extra = url.searchParams.get('room');
      if (extra) rooms.add(extra);
      const out: Record<string, unknown> = {};
      for (const region of Object.keys(REGIONS) as RegionKey[]) {
        for (const room of rooms) {
          out[`${region}|${room}`] = await peerStub(env, region, room, '1')
            .fetch('https://do/stop').then((r) => r.json()).catch(() => null);
        }
      }
      await labDO(env).fetch('https://do/keeper', { method: 'POST', body: JSON.stringify({ stoppedAll: Date.now(), armed: false }) });
      return json({ stopped: out });
    }
    if (url.pathname === '/api/presence') {
      return json(await occupants(env, url.searchParams.get('room') ?? LAB_ROOM));
    }
    return json({ error: 'not found' }, 404);
  },

  // ── The keeper ──────────────────────────────────────────────────────────────
  //
  // Runs every minute. Its whole job is to make the permanent link behave like
  // a permanent thing: a human who opens it finds somebody on the other side,
  // and a human who closes it stops paying for one.
  //
  // Zero idle cost is the design constraint, not a nicety. An always-on 2 vCPU
  // container bills continuously whether or not anyone is looking at it, and
  // "leave the rig running" is how a test environment turns into a subscription.
  async scheduled(_c: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil((async () => {
      const lab = labDO(env);
      const st = (await lab.fetch('https://do/latest').then((r) => r.json())) as {
        latest: Record<string, { at: number; kind?: string; room?: string }>;
        peerAt: Record<string, { at: number; room?: string | null; kind?: string }>;
        keeper: Record<string, unknown>;
      };
      const keeper = st.keeper ?? {};
      const note = (patch: Record<string, unknown>) =>
        lab.fetch('https://do/keeper', { method: 'POST', body: JSON.stringify({ ...patch, tickAt: Date.now() }) });
      // Sequential, not parallel: each lane's decision reads the keeper state
      // the previous one just wrote, and two concurrent read-modify-writes on
      // one Durable Object value is how the second lane's summon record
      // overwrites the first lane's cooldown.
      for (const lane of LANES) await tend(env, lane, st, keeper, note);
    })());
  },
};

// One lane: one room, one far peer, one decision per minute.
async function tend(
  env: Env,
  lane: { room: string; region: RegionKey },
  st: { peerAt: Record<string, { at: number; room?: string | null; kind?: string }> },
  keeper: Record<string, unknown>,
  noteAll: (p: Record<string, unknown>) => unknown,
): Promise<void> {
  const { room, region } = lane;
  // Every note is scoped to this lane's region, so two lanes writing the same
  // Durable Object value do not overwrite each other's cooldown and idle count.
  const note = (patch: Record<string, unknown>) => {
    const scoped: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(patch)) scoped[`${k}_${slot(region, room)}`] = v;
    return noteAll(scoped);
  };
  const pres = await occupants(env, room);
  if (pres.err) { await note({ lastErr: pres.err }); return; }

  // Is OUR peer the thing occupying the room? A join frame inside the last 90 s,
  // naming THIS room, is the only evidence that counts — "we started a container
  // two minutes ago" is a birth certificate, not a health record, and the whole
  // point of periodic reporting was to stop reading one as the other.
  const mine = st.peerAt?.[slot(region, room)];
  const minePresent = !!mine && Date.now() - mine.at < 90_000 && mine.room === room;
  const humans = pres.peers.length - (minePresent ? 1 : 0);
  // A container takes 30-90 s to boot and says nothing while it does. Without
  // this the keeper reads that silence as "no peer", summons on top of the one
  // already coming up, and churns forever — the same trap as reading `latest`
  // instead of a join frame, one layer out.
  const lastSummon = (keeper[`summoned_${slot(region, room)}`] as { at?: number } | undefined)?.at ?? 0;
  const gen = String(keeper[`gen_${slot(region, room)}`] ?? 1);
  const booting = Date.now() - lastSummon < 150_000;

  // NEVER SUMMON INTO A FULL ROOM, whoever is in it.
  //
  // The room holds two. `humans` is "occupants minus the peer I can account
  // for", so an occupant this keeper cannot identify — a peer it lost track of,
  // a second browser, a stale socket — reads as another human needing company,
  // and it summons a THIRD party into a two-seat room. Measured 2026-08-23: a
  // mid-flight change to the container's identity orphaned a running peer, the
  // keeper read the room as "someone alone", and the operator watched
  // "connection paused, reconnecting" for four minutes while two bots fought
  // over one slot. Occupancy is the authority here, not our own bookkeeping.
  if (pres.peers.length >= 2) { await note({ lastAction: 'room full', idleTicks: 0 }); return; }

  if (humans >= 1 && !minePresent) {
    if (booting) { await note({ lastAction: `waiting on ${region} boot`, idleTicks: 0 }); return; }
    // Somebody is in the room with nobody to talk to. This is the entire reason
    // the keeper exists.
    await note({ lastAction: `summon ${region}`, idleTicks: 0 });
    await summon(env, env.SELF_ORIGIN, { region, room, side: 'B', hold: '1800', gen });
    return;
  }
  if (humans <= 0) {
    // Nobody but us. Two consecutive empty ticks before tearing down, so a page
    // reload — which briefly empties the room — does not cost the person their
    // far end and another cold start.
    //
    // Exactly ONE teardown, then park. The counter clamps at 3 and the stop
    // fires only on the transition, because an unbounded counter that re-issues
    // destroy() every minute forever is a cron job whose steady state is work —
    // and "in call" would stay printed next to idleTicks: 9 as the last thing it
    // claimed to be doing.
    const idle = Math.min(Number(keeper[`idleTicks_${slot(region, room)}`] ?? 0) + 1, 3);
    // ONE teardown on the transition — and then a slow REAPER, because one
    // teardown is not enough. Measured: a container was still `running` on the
    // platform 793 s after its last report, while the keeper sat parked at
    // idleTicks 3 having already spent its single attempt. A destroy() that did
    // not take, or a container that outlived the Durable Object that owned it,
    // is a bill nobody is watching — and "zero idle cost" is the whole design
    // constraint. destroy() on nothing is a no-op, so re-issuing it every five
    // minutes while the room stays empty costs one subrequest and closes the
    // hole that a one-shot cannot.
    const reapAt = Number(keeper[`reapAt_${slot(region, room)}`] ?? 0);
    const dueForReap = idle >= 2 && Date.now() - reapAt > 300_000;
    if (idle === 2 || dueForReap) {
      // ONLY this lane's peer. A sweep across every region would reach into
      // `far-away-max` and kill a furthest-pair run that has nothing to do with
      // whether anybody is standing in this room.
      await peerStub(env, region, room, gen).fetch('https://do/stop').catch(() => {});
      await note({ lastAction: `torn down ${region} (room empty)`, idleTicks: 3, reapAt: Date.now() });
    } else {
      await note({ lastAction: idle >= 3 ? 'idle' : 'room emptying', idleTicks: idle });
    }
    return;
  }
  await note({ lastAction: 'in call', idleTicks: 0 });
}
