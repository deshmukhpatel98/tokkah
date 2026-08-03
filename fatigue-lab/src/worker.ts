/**
 * Fatigue lab — signaling only.
 *
 * Deliberately separate from phase1-transport: experiments should not be able to
 * break each other. The ~60 lines of duplicated signaling is worth the isolation.
 *
 * This lab uses ordinary WebRTC media transport. That is on purpose — the fatigue
 * fixes (§1.1) are entirely independent of the transport, so they can and should
 * be tested before the custom pipeline exists. The transport gets replaced later;
 * none of this code changes when it does.
 */

interface Env {
  ASSETS: Fetcher;
  ROOM: DurableObjectNamespace;
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

export class Room implements DurableObject {
  private peers: WebSocket[] = [];

  constructor(state: DurableObjectState, env: unknown) {}

  async fetch(request: Request): Promise<Response> {
    if (this.peers.length >= 2) return new Response('room full', { status: 409 });

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();

    const role = this.peers.length === 0 ? 'a' : 'b';
    this.peers.push(server);

    server.addEventListener('message', (e: MessageEvent) => {
      for (const p of this.peers) {
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
      this.peers = this.peers.filter((p) => p !== server);
      for (const p of this.peers) {
        try {
          p.send(JSON.stringify({ type: 'peer-left' }));
        } catch {
          /* ignore */
        }
      }
    };
    server.addEventListener('close', teardown);
    server.addEventListener('error', teardown);

    server.send(JSON.stringify({ type: 'welcome', role, peerPresent: this.peers.length === 2 }));
    if (this.peers.length === 2) {
      for (const p of this.peers) {
        if (p !== server) {
          try {
            p.send(JSON.stringify({ type: 'peer-joined' }));
          } catch {
            /* ignore */
          }
        }
      }
    }

    return new Response(null, { status: 101, webSocket: client });
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === '/api/ice') {
      if (!env.TURN_KEY_ID || !env.TURN_KEY_API_TOKEN) {
        return json({
          p2pOnly: true,
          iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }],
        });
      }
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
      if (!res.ok) {
        return json({ p2pOnly: true, iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }] });
      }
      const body = (await res.json()) as { iceServers?: unknown };
      return json({ p2pOnly: false, iceServers: body.iceServers });
    }

    const m = url.pathname.match(/^\/api\/room\/([A-Za-z0-9_-]{1,64})\/ws$/);
    if (m) {
      if (request.headers.get('upgrade') !== 'websocket') {
        return json({ error: 'expected websocket' }, 426);
      }
      return env.ROOM.get(env.ROOM.idFromName(m[1])).fetch(request);
    }

    if (url.pathname.startsWith('/api/')) return json({ error: 'not found' }, 404);
    return env.ASSETS.fetch(request);
  },
};
