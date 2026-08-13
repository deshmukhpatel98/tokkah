// Places a browser container on a named continent, drives it into a real call,
// and collects what that call cost.
//
// The 150 ms goal turns on one number nobody has: what a REAL media path costs
// between two continents. Everything measured so far is this laptop against a
// simulated network, or Cloudflare's CONTROL plane (a Durable Object round
// trip), or the public internet to a third party. None of them is WebRTC media
// on a long route.
//
// A container instance is owned by a Durable Object, so the DO's locationHint
// decides which continent the browser runs on. That is the entire trick.

export interface Env {
  PEER: DurableObjectNamespace;
}

const REGIONS = new Set(['wnam', 'enam', 'sam', 'weur', 'eeur', 'apac', 'oc', 'afr', 'me']);

// Served to the container at boot rather than baked into the image, so the
// experiment can change without rebuilding and re-pushing two gigabytes.
// Playwright and Chromium are already in the image; the fake-media flags match
// the ones our local rigs use, because two ends running different capture paths
// is not a comparison.
const JOIN_JS = String.raw`
const { chromium } = require('playwright');
const ROOM = process.env.ROOM, BASE = process.env.BASE, QS = process.env.EXTRA_QS || '';
const REPORT = process.env.REPORT_URL, HOLD = Number(process.env.HOLD_S || 75);
const post = async (o) => { try {
  await fetch(REPORT, { method:'POST', headers:{'content-type':'application/json'}, body: JSON.stringify(o) });
} catch (e) { console.log('report failed', String(e)); } };
(async () => {
  let b;
  try {
    b = await chromium.launch({ args: [
      '--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream',
      '--autoplay-policy=no-user-gesture-required','--no-sandbox',
    ]});
    const p = await b.newPage();
    const url = BASE + '/' + ROOM + '?hb=1' + (QS ? '&' + QS : '');
    await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    // The join button is the same one a person presses; driving the real UI
    // keeps this honest rather than reaching into internals to fake a call.
    await p.click('#join', { timeout: 30000 }).catch(() => {});
    await p.waitForTimeout(HOLD * 1000);
    const snap = await p.evaluate(() => {
      const pcm = window.__tape && window.__tape.pcm;
      const lane = window.__tape && window.__tape.lane && window.__tape.lane.snapshot
        ? window.__tape.lane.snapshot() : null;
      const s = pcm && typeof pcm.snapshot === 'function' ? pcm.snapshot() : pcm;
      return {
        mouthToEarMs: (s && s.mouthToEarMs) || null,
        ringDepthMs: (s && s.m2eParts && s.m2eParts.ringDepthMs) || null,
        framesRecv: (s && s.framesRecv) || null,
        concealedMs: (s && s.concealedMs) || null,
        glassToGlassMs: lane && lane.glassToGlassMs || null,
        ipiP50: lane && lane.ipiP50 || null,
        perAssoc: (s && s.perAssoc || []).map((a) => ({ rtt: a.rttMs, base: a.baseRttMs })),
      };
    });
    // The ICE pair is the whole point: which route carried it, and what the
    // network itself cost on that route.
    const ice = await p.evaluate(async () => {
      const pc = window.__tapePc || null;
      if (!pc || !pc.getStats) return null;
      const st = await pc.getStats(); let pair = null;
      st.forEach((r) => { if (r.type === 'candidate-pair' && r.state === 'succeeded' && (r.nominated || !pair)) pair = r; });
      if (!pair) return null;
      const L = st.get(pair.localCandidateId), R = st.get(pair.remoteCandidateId);
      return { local: L && L.candidateType, remote: R && R.candidateType, proto: L && L.protocol,
               rttMs: pair.currentRoundTripTime != null ? Math.round(pair.currentRoundTripTime * 1000) : null };
    }).catch(() => null);
    await post({ ok: true, room: ROOM, qs: QS, snap, ice });
    console.log('reported', JSON.stringify(snap));
  } catch (e) {
    await post({ ok: false, room: ROOM, qs: QS, error: String(e && e.stack || e) });
  } finally { if (b) await b.close().catch(() => {}); }
})();
`;

export class PeerContainer implements DurableObject {
  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const c = (this.state as unknown as { container?: {
      running: boolean;
      start(opts?: { entrypoint?: string[]; env?: Record<string, string> }): void;
      destroy(): Promise<void>;
    } }).container;
    if (!c) return Response.json({ error: 'no container binding on this class' }, { status: 500 });

    if (url.pathname === '/stop') {
      await c.destroy();
      await this.state.storage.deleteAll();
      return Response.json({ stopped: true });
    }
    // The container posts its result here; keeping it in DO storage means the
    // answer survives the container exiting, which it does as soon as it is done.
    if (url.pathname === '/report' && request.method === 'POST') {
      const body = await request.json().catch(() => ({}));
      const prev = (await this.state.storage.get('result')) as { stages?: unknown[] } | undefined;
      const stages = Array.isArray(prev?.stages) ? prev!.stages : [];
      stages.push({ at: Date.now(), ...(body as object) });
      await this.state.storage.put('result', { ...(prev ?? {}), stages: stages.slice(-12) });
      return Response.json({ stored: true });
    }
    if (url.pathname === '/result') {
      return Response.json((await this.state.storage.get('result')) ?? { pending: true });
    }
    if (url.pathname === '/call') {
      const room = url.searchParams.get('room') ?? '';
      const base = url.searchParams.get('base') ?? 'https://room.tokkah.com';
      const extra = url.searchParams.get('qs') ?? '';
      const hold = url.searchParams.get('hold') ?? '75';
      const self = url.searchParams.get('self') ?? '';
      await this.state.storage.delete('result');
      if (c.running) await c.destroy();
      // Fetch the script at boot and run it. `set -e` so a failed download is a
      // failed container rather than a browser that never starts and a result
      // that never arrives — silence is the one outcome that teaches nothing.
      c.start({
        entrypoint: ['bash', '-lc',
          // NODE_PATH from `npm root -g`: the Playwright image installs its
          // packages GLOBALLY, so `node join.js` in /peer cannot resolve
          // require('playwright') on its own -- the identical module-resolution
          // trap that broke the local half of this experiment twice. Errors are
          // echoed to stdout so a failure is visible in container logs instead
          // of arriving as a silent `pending` result forever.
          // STAGED REPORTING. Four attempts were burned guessing at a silent
          // `pending` because container stdout was never readable from here.
          // Each step now posts before it runs, so the last stage that arrives
          // names the step that failed -- a trace instead of silence.
          'stage(){ curl -fsS -X POST "$REPORT_URL" -H "content-type: application/json" -d "{\"stage\":\"$1\",\"detail\":\"$2\"}" >/dev/null 2>&1 || true; }; '
          + 'stage boot "entrypoint running"; '
          + 'export NODE_PATH="$(npm root -g)"; stage nodepath "$NODE_PATH"; '
          + 'curl -fsS "$JOIN_URL" -o /peer/join.js || { stage fetch-failed "cannot reach worker"; exit 1; }; '
          + 'stage fetched "$(wc -c < /peer/join.js) bytes"; '
          + 'cd /peer; OUT=$(node join.js 2>&1) || stage node-failed "$(echo "$OUT" | tail -c 400)"; '
          + 'stage exited "$(echo "$OUT" | tail -c 200)"'],
        env: {
          JOIN_URL: `${self}/join.js`,
          REPORT_URL: `${self}/report?region=${url.searchParams.get('region') ?? 'wnam'}`,
          ROOM: room, BASE: base, EXTRA_QS: extra, HOLD_S: hold,
        },
      });
      return Response.json({ started: true, room, base, qs: extra });
    }
    if (!c.running) c.start();
    return Response.json({ running: c.running });
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === '/join.js') {
      return new Response(JOIN_JS, { headers: { 'content-type': 'application/javascript' } });
    }
    const region = url.searchParams.get('region') ?? 'wnam';
    if (!REGIONS.has(region)) {
      return Response.json({ error: 'bad region', allowed: [...REGIONS] }, { status: 400 });
    }
    const stub = env.PEER.get(
      env.PEER.idFromName(`peer-${region}`),
      { locationHint: region } as DurableObjectNamespaceGetDurableObjectOptions,
    );
    // The container needs an absolute URL to reach back to; it has outbound
    // network but no idea what this worker is called.
    const fwd = new URL(url.toString());
    fwd.searchParams.set('self', url.origin);
    const t0 = Date.now();
    const res = await stub.fetch(new Request(fwd.toString(), {
      method: request.method,
      body: request.method === 'POST' ? await request.text() : undefined,
      headers: request.headers,
    }));
    const body = await res.json().catch(() => ({}));
    return Response.json({
      region,
      // locationHint is ADVISORY and was demonstrably ignored for `me` in the
      // probe, so the edge that served this is reported and the distance stays
      // knowable rather than assumed.
      edgeColo: (request.cf?.colo as string | undefined) ?? null,
      roundTripMs: Date.now() - t0,
      container: body,
    });
  },
};
