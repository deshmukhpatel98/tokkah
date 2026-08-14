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
// playwright-core first: the image installs THAT, because the base ships the
// browsers already and the full package would re-download them. The fallback
// keeps this script runnable against a plain playwright install too.
const { chromium } = (() => { try { return require('playwright-core'); }
                              catch (e) { return require('playwright'); } })();
const ROOM = process.env.ROOM, BASE = process.env.BASE, QS = process.env.EXTRA_QS || '';
const REPORT = process.env.REPORT_URL, HOLD = Number(process.env.HOLD_S || 75);
const post = async (o) => { try {
  await fetch(REPORT, { method:'POST', headers:{'content-type':'application/json'}, body: JSON.stringify(o) });
} catch (e) { console.log('report failed', String(e)); } };
(async () => {
  let b;
  try {
    b = await chromium.launch({ args: [
      '--use-fake-ui-for-media-stream','--use-fake-device-for-media-stream',
      // A REAL talking head and REAL speech as the camera and microphone, the
      // same files and the same flags the local rig uses -- side B here against
      // side A there, so the two ends carry different speakers the way an
      // actual conversation does. Chromium's synthetic pattern and beep
      // compress to almost nothing: a call carrying them measures an empty pipe
      // on a long route and reports it as a video call.
      '--use-file-for-fake-video-capture=/peer/media/realB.mjpeg',
      '--use-file-for-fake-audio-capture=/peer/media/realB.wav',
      '--autoplay-policy=no-user-gesture-required','--no-sandbox',
      // Headless Chrome may skip the audio render pipeline entirely without an
      // output device, which would show up as silence for the wrong reason.
      '--alsa-output-device=null',
      '--disable-features=WebRtcHideLocalIpsWithMdns',
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
      // window.__tape.pc -- NOT window.__tapePc. The latter never existed, so
      // this returned null on every attempt and a call that never connected was
      // indistinguishable from one that connected and measured nothing.
      const pc = (window.__tape && window.__tape.pc) || null;
      if (!pc || !pc.getStats) return { pc: false };
      const st = await pc.getStats(); let pair = null, inb = null;
      st.forEach((r) => {
        if (r.type === 'candidate-pair' && r.state === 'succeeded' && (r.nominated || !pair)) pair = r;
        if (r.type === 'inbound-rtp' && r.kind === 'audio') inb = r;
      });
      // Connection state travels WITH the numbers, so a call that never
      // connected reports as not-connected rather than as a tempting null.
      const out = { conn: pc.connectionState, iceState: pc.iceConnectionState,
                    pktsRecv: (inb && inb.packetsReceived) || null };
      if (!pair) return out;
      const L = st.get(pair.localCandidateId), R = st.get(pair.remoteCandidateId);
      return Object.assign(out, { local: L && L.candidateType, remote: R && R.candidateType,
               proto: L && L.protocol,
               rttMs: pair.currentRoundTripTime != null ? Math.round(pair.currentRoundTripTime * 1000) : null });
    }).catch((e) => ({ err: String(e).slice(0, 120) }));
    await post({ ok: true, room: ROOM, qs: QS, snap, ice });
    console.log('reported', JSON.stringify(snap));
  } catch (e) {
    await post({ ok: false, room: ROOM, qs: QS, error: String(e && e.stack || e) });
  } finally { if (b) await b.close().catch(() => {}); }
})();
`;

export class PeerContainer implements DurableObject {
  constructor(private state: DurableObjectState, private env: Env) {}

  // Re-arms itself until the deadline. The only job is to exist: a Durable
  // Object with a pending alarm stays alive, and a container outlives only as
  // long as the DO that owns it.
  async alarm(): Promise<void> {
    const deadline = (await this.state.storage.get('deadline')) as number | undefined;
    if (deadline && Date.now() < deadline) await this.state.storage.setAlarm(Date.now() + 20_000);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const c = (this.state as unknown as { container?: {
      running: boolean;
      start(opts?: {
        entrypoint?: string[];
        env?: Record<string, string>;
        // Off by default -- which is the whole reason six attempts saw silence.
        enableInternet?: boolean;
      }): void;
      // Resolves when the container exits. Holding this keeps the DO alive, and
      // a DO that goes idle takes its container down with it.
      monitor(): Promise<unknown>;
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
      // Two shapes arrive here. The shell's stage pings put the stage name in
      // the query and the detail in a plain-text body -- because building JSON
      // in bash destroyed every detail that contained a quote, which is every
      // stack trace. join.js still posts real JSON.
      const stageName = url.searchParams.get('stage');
      const body = stageName
        ? { stage: stageName, detail: (await request.text().catch(() => '')).slice(0, 500) }
        : await request.json().catch(() => ({}));
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
      const gen = url.searchParams.get('gen') ?? '1';
      await this.state.storage.delete('result');
      if (c.running) await c.destroy();
      // ENV ONLY -- NO ENTRYPOINT.
      //
      // Five attempts died here passing `entrypoint`, and staged reporting
      // finally proved why: the override is silently DISCARDED. Not even the
      // first line of it ever ran, while the container reported itself healthy
      // running the image's own CMD (`sleep infinity`) forever. So the work now
      // lives in the image's CMD, where nothing can drop it, and this call
      // passes only env -- the half of the API there is no evidence against.
      //
      // The script itself is still SERVED, not baked, so the experiment can
      // change without rebuilding and re-pushing two gigabytes.
      c.start({
        // A container gets NO outbound network unless this is set. Its config
        // read back `assign_ipv4: none, assign_ipv6: none, mode: private`, which
        // is why six attempts saw perfect silence: the image was fine, the CMD
        // was fine, and every single thing it tried to reach was unreachable --
        // including, fatally for a WEBRTC peer, the entire internet.
        enableInternet: true,
        env: {
          JOIN_URL: `${self}/join.js`,
          // `gen` MUST ride along. Without it the container posted to the
          // default-generation DO while the experiment polled the one it had
          // just created, so a far peer that ran perfectly in Seattle read as
          // total silence -- a whole debugging arc spent reading an empty
          // mailbox next to the full one.
          REPORT_URL: `${self}/report?region=${url.searchParams.get('region') ?? 'wnam'}&gen=${gen}`,
          ROOM: room, BASE: base, EXTRA_QS: extra, HOLD_S: hold,
        },
      });
      // A container's lifetime is its Durable Object's lifetime. Return without
      // holding anything and the DO goes idle the moment this response is sent,
      // taking the container with it -- which is why `containers instances`
      // showed the instance `inactive` with location `-`, i.e. never placed on
      // hardware at all. monitor() resolves when the container exits, so holding
      // it keeps the DO awake exactly as long as the call needs and no longer.
      this.state.waitUntil(c.monitor().catch(() => {}));
      // Belt and braces on that: an alarm chain keeps this DO awake on its own
      // schedule. monitor() alone is a single promise, and if it settles early
      // -- which it can, on a container that has not been placed yet -- the DO
      // goes idle in the middle of a cold image pull and the container is
      // abandoned before it ever runs. A pull into a region that has never seen
      // this image takes MINUTES, so that window is wide.
      await this.state.storage.put('deadline', Date.now() + 15 * 60_000);
      await this.state.storage.setAlarm(Date.now() + 20_000);
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
    // `gen` exists to force a FRESH Durable Object. Placement is decided once,
    // when a DO is first created, so an instance already sitting in the wrong
    // city stays there no matter what the config later says. Bumping gen is the
    // only way to re-roll placement without deleting the namespace.
    const gen = url.searchParams.get('gen') ?? '1';
    const stub = env.PEER.get(
      env.PEER.idFromName(`peer-${region}-${gen}`),
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
