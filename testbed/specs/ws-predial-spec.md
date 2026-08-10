# Work order: WebSocket pre-dial — the lobby dials the room before the click

## The problem this solves

Measured live (room bot-msntyeea-shue, 2026-08-11): the second joiner's
472 ms click→connected decomposes as **241 ms ws dial + welcome**, 75 ms
peer offer generation, 12 ms ICE, 144 ms DTLS/stripes. The dial is the fat
slice, and it is pure waste: the lobby knows the room name long before the
click (deep link, typed name, or the pre-minted one) — it already pre-warms
the room DO with a /summary fetch on exactly that knowledge. Pre-dialing
the WebSocket the same way makes click→welcome ≈ one message RTT.

The trap is admission semantics: a 2-person room must NOT count a lobby
lurker as an occupant. So the pre-dialed socket connects in a **hold** state
— accepted, but not admitted — and admission happens when the client sends
`{type:'join'}` on it at click time.

## Files to edit (ONLY these two)

- `tape-app/src/worker.ts` — Room DO: hold state + admit-on-message
- `tape-app/public/app.js` — lobby pre-dial + join() adoption

## Server changes (worker.ts)

### 1. Extract admission into a private method

The block in Room's ws-upgrade path from the sid ghost-eviction comment
("Ghost eviction (task #50)...") through the `peer-joined` broadcast
(everything between the upgrade guard and `return new Response(null,
{ status: 101, webSocket: client })`, lines ~281–397) becomes a private
method:

```ts
private admit(server: WebSocket, opts: { lane: number; pcm: number; sid: string | null; full: () => void }): void
```

- Same logic, same order: sid eviction → full check → role slot → caps →
  relay message listener → teardown listeners → welcome → peer-joined.
- The full check changes shape only in HOW it rejects: call `opts.full()`
  and return (the upgrade path's closure returns a 409 Response as today;
  the hold path sends `{type:'full'}` and closes — see below).
- The relay `message` listener the method installs must first check for and
  IGNORE nothing new — held sockets get their own listener before admit (see
  3); once admitted, the relay listener is installed exactly as today. (Both
  listeners will receive messages after admission; the hold listener must
  therefore mark itself done — a `joined` flag — and pass through.)
- `this.peers.size >= 2` check: unchanged. Note the upgrade path today
  checks full BEFORE creating the WebSocketPair — preserve that for the
  upgrade path (the 409 must remain an HTTP response, not an open-then-
  close: clients today read pre-open failure as "room full", and that
  behaviour must stay byte-identical when `hold` is absent).

So the upgrade path becomes: sid-evict + full-check inline exactly as today
(early 409 return), then pair/accept, then call `admit()` for the REST
(role, caps, listeners, welcome, peer-joined). Refactor admit() so the sid
eviction and full check are a separate small private method
`evictAndCheckFull(sid): boolean` (true = full) used by both paths — the
upgrade path calls it before creating the pair; the hold-join path calls it
inside the message handler.

### 2. Hold-mode upgrade

In the ws route of Room.fetch, read `const hold = q.get('hold') === '1'`.
When hold:

- Do NOT run eviction/full-check/admission. Create the pair, `accept()`,
  and register the socket in a new `private held = new Set<WebSocket>()`.
- Arm a 120 s timer (`setTimeout`) that closes the socket if still held
  (clear it on join or close). Store timers in a
  `private heldTimers = new Map<WebSocket, ReturnType<typeof setTimeout>>()`.
- Install a `message` listener that parses JSON; on `{type:'join', lane,
  pcm, sid}` from a socket still in `held`: remove from `held`, clear its
  timer, run `evictAndCheckFull(sid)` — if full, `server.send(JSON.stringify(
  {type:'full'}))` then `server.close(1000, 'room full')`; else call
  `admit(server, {lane: Number(lane)||0, pcm: Number(pcm)||0, sid: sid ??
  null, ...})` and ALSO stamp the rooms registry (see 3). Any other message
  from a held socket is ignored (never relayed — a lurker must not be able
  to inject signaling).
- Install `close`/`error` listeners that remove from `held` and clear the
  timer (held sockets are not in `peers`, so today's teardown doesn't apply).
- Return the 101 with the client end, as the normal path does.

### 3. Registry stamp for hold-joins

The route-level `room-seen` waitUntil (worker fetch, ~line 1246) fires on
every ws UPGRADE today. Gate it: skip when the upgrade URL has `hold=1`
(a lobby lurk is not a call). Instead, in the DO, when a held socket's
join is admitted, fire-and-forget the same POST — the Room DO has `env`:

```ts
this.env.HEALTH.get(this.env.HEALTH.idFromName('global'))
  .fetch(new Request('https://do/room-seen', { method: 'POST', body: this.roomCode }))
  .then(() => {}, () => {});
```

`roomCode`: the DO does not currently know its own code — the route knows
it. Simplest honest carrier: the hold upgrade URL already contains it
(`/api/room/<code>/ws`), so in Room.fetch's ws branch parse the code from
`new URL(request.url).pathname` and keep it in a `private roomCode = ''`
field (set on every ws upgrade — idempotent).

## Client changes (app.js)

### 4. Flag

Next to `const L2_DURESS` (~line 1572), add:

```js
const PREDIAL = QS.get('predial') !== '0'; // lobby pre-dials the room ws; `?predial=0` control
```

### 5. Lobby pre-dial

Next to `prewarmRoom` (~line 5160), add a module-level cache + function:

```js
// Task: the second joiner's 241 ms click→welcome was the largest slice of
// click→connected (measured, room log, 2026-08-11) — and the lobby knows
// the room name as early as it knows to pre-warm the DO. The socket dials
// in HOLD state (?hold=1): the room accepts but does not admit, so a lobby
// lurker never occupies a slot; the click sends {type:'join'} and the
// welcome arrives in ~one RTT. 120 s server timeout; a closed pre-dial
// falls back to the fresh dial, losing nothing.
let predial = null; // { room, ws }
function predialWs(room) {
  if (!PREDIAL || !room) return;
  if (predial?.room === room && predial.ws.readyState <= WebSocket.OPEN) return;
  safe(() => { predial?.ws.close(); }, 'predial.close');
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const w = new WebSocket(`${proto}//${location.host}/api/room/${encodeURIComponent(room)}/ws?hold=1`);
  w.onclose = () => { if (predial?.ws === w) predial = null; };
  predial = { room, ws: w };
}
```

Call `predialWs(room)` immediately after every `prewarmRoom(room)` call
site (there are three: `prewarmRoom(urlRoom || pendingMint)` and the typed-
name debounce at ~5553, plus verify no other sites with grep).

### 6. join() adoption

At the dial site (~line 4017, `ws = new WebSocket(...)`): when `predial`
matches this room and its socket is CONNECTING or OPEN, adopt it instead of
dialing:

```js
const adopted = PREDIAL && predial?.room === room && predial.ws.readyState <= WebSocket.OPEN
  ? predial.ws : null;
if (adopted) predial = null;
ws = adopted ?? new WebSocket(
  `${proto}//${location.host}/api/room/${encodeURIComponent(room)}/ws?lane=${wantTape}&pcm=${PCM_AUDIO ? 1 : 0}&sid=${encodeURIComponent(sid)}`,
);
```

- The existing `ws.addEventListener('open', ...)` / `ws.onclose` /
  `ws.onerror` / `ws.onmessage` wiring stays exactly as-is (assignment
  replaces the lobby's minimal onclose).
- Send the join message once the socket is open. After the existing handler
  wiring, add:

```js
if (adopted) {
  const sendJoin = () => safe(() => ws.send(JSON.stringify({ type: 'join', lane: wantTape, pcm: PCM_AUDIO ? 1 : 0, sid })), 'predial.join');
  if (ws.readyState === WebSocket.OPEN) { wsOpened = true; tel.log('predial-adopt', { open: 1 }); sendJoin(); }
  else { ws.addEventListener('open', () => { tel.log('predial-adopt', { open: 0 }); sendJoin(); }); }
}
```

Note `wsOpened` must be set for the already-open case or the close handler
misreads a later close as a pre-open failure. (The CONNECTING case is
covered by the existing `open` listener setting `wsOpened = true`.)

- In `ws.onmessage`, add a `full` branch BEFORE the welcome branch:

```js
if (m.type === 'full') {
  tel.log('room-full-msg', {});
  wsPreOpenFail?.(new Error('this call may already have two people in it'));
  safe(() => ws.close(), 'full.close');
  return;
}
```

## Invariants (verify before finishing)

- With no `hold` param and no pre-dial (`?predial=0`), both server and
  client behave byte-identically to today, including the pre-open 409.
- A held socket never appears in `peers`, never relays, never receives
  relayed traffic, and cannot inject signaling before admission.
- A held socket abandoned in the lobby closes within 120 s and stamps
  nothing in the rooms registry.
- The recovery/rejoin path (recoverCall → join) is untouched: it dials
  fresh because `predial` is consumed or gone.

## Style rules (mandatory)

Comments explain WHY in each file's voice; no change-log comments; 2-space
indent; TypeScript in worker.ts must typecheck against existing types.
