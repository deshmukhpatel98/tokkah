// tickInterval(fn, ms): setInterval that keeps its cadence in a BACKGROUND tab.
// One shared worker carries every clock (see tickworker.js for why); the
// callback still runs on the caller's thread with the caller's state.
//
// FALLS BACK HARD. A worker can fail three ways — constructor throw (CSP),
// async 'error' (404, MIME, parse), or messages that simply never come — and
// the first shipped version handled only the throw: a 404 left every clock
// subscribed to a dead worker and the whole pipeline froze at its start rates
// (testbed: 6% frames admitted, m2e +170 ms). Now every subscription ALSO
// arms a plain setInterval after a grace period unless the worker's first
// tick has arrived, and a worker 'error' flips everything to setInterval at
// once. ?tickworker=0 pins the plain-timer path (the control arm).
const PLAIN = typeof location !== 'undefined'
  && new URLSearchParams(location.search).get('tickworker') === '0';
let w = null;
let dead = PLAIN;
let seenTick = false;
let nextId = 1;
const subs = new Map(); // id -> { fn, ms, fallbackTimer, viaWorker }
function failover() {
  dead = true;
  try { w?.terminate?.(); } catch { /* already gone */ }
  w = null;
  for (const s of subs.values()) {
    if (s.fallbackTimer == null) s.fallbackTimer = setInterval(s.fn, s.ms);
  }
}
function worker() {
  if (dead) return null;
  if (w !== null) return w;
  try {
    w = new Worker(new URL('./tickworker.js', import.meta.url));
    w.onerror = failover;
    w.onmessage = (e) => {
      seenTick = true;
      const s = subs.get(e.data);
      if (!s) return;
      // The worker is alive: cancel this sub's insurance timer if it armed.
      if (s.fallbackTimer != null) { clearInterval(s.fallbackTimer); s.fallbackTimer = null; }
      s.fn();
    };
  } catch { w = null; dead = true; }
  return w;
}
export function tickInterval(fn, ms) {
  const id = nextId++;
  const sub = { fn, ms, fallbackTimer: null };
  subs.set(id, sub);
  const wk = worker();
  if (wk) {
    wk.postMessage({ op: 'add', id, ms });
    // Insurance: if no tick from the worker within 3 periods (min 1 s), run a
    // plain interval too. Duplicate ticks are impossible — the insurance only
    // arms while the worker is silent, and is cancelled on its first message.
    setTimeout(() => {
      if (!dead && !seenTick && subs.has(id) && sub.fallbackTimer == null) {
        sub.fallbackTimer = setInterval(fn, ms);
      }
    }, Math.max(1000, ms * 3));
  } else {
    sub.fallbackTimer = setInterval(fn, ms);
  }
  return {
    clear: () => {
      subs.delete(id);
      if (sub.fallbackTimer != null) clearInterval(sub.fallbackTimer);
      try { if (!dead && w) w.postMessage({ op: 'clear', id }); } catch { /* gone */ }
    },
  };
}

// #74 Observability: which clock is actually driving the ticks. 'worker' only
// after the worker's first real tick -- 'worker-pending' means subscriptions
// exist but no proof of life yet, and the two plain variants say WHY the
// fallback is in charge. A blocked worker script used to be indistinguishable
// from a healthy one out here.
export function tickMode() {
  if (PLAIN) return 'plain-flag';
  if (dead) return 'plain-failover';
  return seenTick ? 'worker' : 'worker-pending';
}
