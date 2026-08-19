// tickInterval(fn, ms): setInterval that keeps its cadence in a BACKGROUND tab.
// One shared worker carries every clock (see tickworker.js for why); the
// callback still runs on the caller's thread with the caller's state. Falls
// back to plain setInterval when workers are unavailable (tests, file://) —
// degrading to exactly the old behaviour, never below it.
let w = null;
let nextId = 1;
const subs = new Map();
function worker() {
  if (w !== null) return w;
  try {
    w = new Worker(new URL('./tickworker.js', import.meta.url));
    w.onmessage = (e) => { const fn = subs.get(e.data); if (fn) fn(); };
  } catch { w = false; }
  return w;
}
export function tickInterval(fn, ms) {
  const wk = worker();
  if (!wk) {
    const t = setInterval(fn, ms);
    return { clear: () => clearInterval(t) };
  }
  const id = nextId++;
  subs.set(id, fn);
  wk.postMessage({ op: 'add', id, ms });
  return { clear: () => { subs.delete(id); wk.postMessage({ op: 'clear', id }); } };
}
