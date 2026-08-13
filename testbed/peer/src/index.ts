// Places a browser container on a named continent and reports where it landed.
//
// The 150 ms goal turns on one number nobody has: what a REAL media path costs
// between two continents. Everything measured so far is either this laptop
// against a simulated network, or Cloudflare's CONTROL plane (a Durable Object
// round trip), or the public internet to a third party. None of them is WebRTC
// media on a long route.
//
// A container instance is owned by a Durable Object, so the DO's locationHint
// is what decides which continent the browser runs on. That is the entire trick.

export interface Env {
  PEER: DurableObjectNamespace;
}

const REGIONS = new Set(['wnam', 'enam', 'sam', 'weur', 'eeur', 'apac', 'oc', 'afr', 'me']);

export class PeerContainer implements DurableObject {
  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    // `container` is only present when a containers block names this class.
    // Saying so plainly beats a TypeError three layers down.
    const c = (this.state as unknown as { container?: {
      running: boolean;
      start(opts?: { entrypoint?: string[]; env?: Record<string, string> }): void;
      destroy(): Promise<void>;
    } }).container;
    if (!c) return Response.json({ error: 'no container binding on this class' }, { status: 500 });

    if (url.pathname === '/stop') {
      await c.destroy();
      return Response.json({ stopped: true });
    }
    if (!c.running) c.start();
    return Response.json({ running: c.running });
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const region = url.searchParams.get('region') ?? 'wnam';
    if (!REGIONS.has(region)) {
      return Response.json({ error: 'bad region', allowed: [...REGIONS] }, { status: 400 });
    }
    // One DO per region, so each continent's container is a separate long-lived
    // instance rather than a single one that migrates.
    const stub = env.PEER.get(
      env.PEER.idFromName(`peer-${region}`),
      { locationHint: region } as DurableObjectNamespaceGetDurableObjectOptions,
    );
    const t0 = Date.now();
    const res = await stub.fetch(new Request(`https://peer${url.pathname}`));
    const body = await res.json().catch(() => ({}));
    return Response.json({
      region,
      // The edge that served this request, so the distance to the DO is knowable
      // rather than assumed — the region probe learned the hard way that
      // locationHint is ADVISORY and is silently ignored for some continents.
      edgeColo: (request.cf?.colo as string | undefined) ?? null,
      roundTripMs: Date.now() - t0,
      container: body,
    });
  },
};
