/**
 * Room — the per-call Durable Object.
 *
 * For phase 1 it does exactly three things:
 *   1. pairs two peers and assigns roles ('a' offers, 'b' answers)
 *   2. relays opaque signaling blobs between them
 *   3. serves as the session clock epoch
 *
 * It never sees a media byte, and it never will (DESIGN.md §14). If this file
 * ever grows a `case 'media':` branch, something has gone wrong.
 */

interface Peer {
  ws: WebSocket;
  role: 'a' | 'b';
}

export class Room implements DurableObject {
  private peers: Peer[] = [];
  private epochMs: number | null = null;

  constructor(
    private state: DurableObjectState,
    private env: unknown,
  ) {}

  async fetch(request: Request): Promise<Response> {
    if (this.peers.length >= 2) {
      return new Response('room full', { status: 409 });
    }

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();

    const role: 'a' | 'b' = this.peers.length === 0 ? 'a' : 'b';
    const peer: Peer = { ws: server, role };
    this.peers.push(peer);

    if (this.epochMs === null) this.epochMs = Date.now();

    server.addEventListener('message', (event: MessageEvent) => {
      // Opaque relay. The DO does not parse or validate signaling payloads —
      // it is a pipe, and treating it as one keeps it out of the media path.
      for (const other of this.peers) {
        if (other !== peer && other.ws.readyState === WebSocket.READY_STATE_OPEN) {
          try {
            other.ws.send(event.data as string);
          } catch {
            /* peer went away mid-send; the close handler will reap it */
          }
        }
      }
    });

    const teardown = () => {
      this.peers = this.peers.filter((p) => p !== peer);
      for (const other of this.peers) {
        try {
          other.ws.send(JSON.stringify({ type: 'peer-left' }));
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
        epochMs: this.epochMs,
        peerPresent: this.peers.length === 2,
      }),
    );

    // Tell the peer that was already waiting that its counterpart arrived.
    // 'a' is the offerer, so this is what unblocks the handshake.
    if (this.peers.length === 2) {
      for (const other of this.peers) {
        if (other !== peer) {
          try {
            other.ws.send(JSON.stringify({ type: 'peer-joined' }));
          } catch {
            /* ignore */
          }
        }
      }
    }

    return new Response(null, { status: 101, webSocket: client });
  }
}
