// Worker-side metronome. Dedicated workers are exempt from the background-tab
// timer clamps (1 Hz after seconds, 1/min under intensive throttling) that
// froze the main thread's setIntervals when the user minimised the window —
// measured live 2026-08-19: the 250 ms audio drain tick and the 16 ms carrier
// tick both crawled, video fell to 0.5 fps and the audio ring ballooned to
// 300+ ms, on a link that was fine. Messages from a worker are delivered to a
// hidden page at full rate; only its TIMERS are clamped — so the clock lives
// here and the work stays where its state is.
const timers = new Map();
onmessage = (e) => {
  const m = e.data;
  if (m.op === 'add' && !timers.has(m.id)) {
    timers.set(m.id, setInterval(() => postMessage(m.id), m.ms));
  } else if (m.op === 'clear') {
    const t = timers.get(m.id);
    if (t !== undefined) { clearInterval(t); timers.delete(m.id); }
  }
};
