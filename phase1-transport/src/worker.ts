/**
 * Phase 1 transport harness — HTTP entry point.
 *
 * Two jobs only:
 *   GET  /api/ice            → ICE servers (CF TURN creds, minted server-side)
 *   GET  /api/room/:code/ws  → WebSocket upgrade into the Room Durable Object
 *
 * Everything else is static assets. The Worker is never in the data path —
 * see DESIGN.md §14. That invariant starts here.
 */

export { Room } from './room';

interface Env {
  ASSETS: Fetcher;
  ROOM: DurableObjectNamespace;
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
}

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET,POST,OPTIONS',
  'access-control-allow-headers': 'content-type',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...CORS },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS });
    }

    // ── ICE servers ────────────────────────────────────────────────────────
    // Cloudflare TURN keys are long-term secrets and must never reach the
    // browser. We mint short-lived credentials here instead.
    if (path === '/api/ice') {
      if (!env.TURN_KEY_ID || !env.TURN_KEY_API_TOKEN) {
        return json({
          p2pOnly: true,
          reason: 'TURN_KEY_ID / TURN_KEY_API_TOKEN not configured',
          iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }],
        });
      }

      const endpoint =
        `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}` +
        `/credentials/generate-ice-servers`;

      const res = await fetch(endpoint, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`,
          'content-type': 'application/json',
        },
        // Short TTL: a harness session is minutes, not days.
        body: JSON.stringify({ ttl: 3600 }),
      });

      if (!res.ok) {
        return json(
          {
            p2pOnly: true,
            reason: `TURN credential mint failed: ${res.status} ${await res.text()}`,
            iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }],
          },
          200,
        );
      }

      const body = (await res.json()) as { iceServers?: unknown };
      return json({ p2pOnly: false, iceServers: body.iceServers });
    }

    // ── Signaling ──────────────────────────────────────────────────────────
    const roomMatch = path.match(/^\/api\/room\/([A-Za-z0-9_-]{1,64})\/ws$/);
    if (roomMatch) {
      if (request.headers.get('upgrade') !== 'websocket') {
        return json({ error: 'expected websocket upgrade' }, 426);
      }
      const id = env.ROOM.idFromName(roomMatch[1]);
      return env.ROOM.get(id).fetch(request);
    }

    if (path.startsWith('/api/')) {
      return json({ error: 'not found' }, 404);
    }

    return env.ASSETS.fetch(request);
  },
};
