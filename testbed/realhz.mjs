// Read the display refresh rate the way the app does, from the REAL browser on the REAL
// screen. system_profiler reports what the OS drives the panel at; this reports what the
// browser can actually present at, which is the number the send rate should follow.
import { chromium } from '/Users/deveshpatel/Downloads/video calling/testbed/node_modules/playwright-core/index.mjs';
const b = await chromium.connectOverCDP('http://127.0.0.1:9333');
const p = (b.contexts()[0] ?? (await b.newContext())).pages()[0] ?? (await b.contexts()[0].newPage());
await p.goto('https://room.tokkah.com/', { waitUntil: 'domcontentloaded' });
const r = await p.evaluate(() => new Promise((resolve) => {
  const ts = [];
  const tick = (t) => {
    ts.push(t);
    if (ts.length <= 300) requestAnimationFrame(tick);
    else {
      const d = [];
      for (let i = 1; i < ts.length; i++) d.push(ts[i] - ts[i - 1]);
      d.sort((a, b) => a - b);
      const med = d[d.length >> 1];
      const near = d.filter((x) => Math.abs(x - med) <= med * 0.1).length;
      resolve({ hz: +(1000 / med).toFixed(1), medianMs: +med.toFixed(3),
        lockedPct: +((100 * near) / d.length).toFixed(1),
        iqrMs: +(d[Math.floor(d.length * 0.75)] - d[Math.floor(d.length * 0.25)]).toFixed(3),
        n: d.length });
    }
  };
  requestAnimationFrame(tick);
}));
console.log(`  real Brave on the real display: ${r.hz} Hz  (median ${r.medianMs} ms, locked ${r.lockedPct}%, iqr ${r.iqrMs} ms, n=${r.n})`);
const div = [];
for (let f = 12; f <= r.hz + 0.5; f++) if (Math.abs(r.hz / f - Math.round(r.hz / f)) < 0.01) div.push(f);
console.log(`  whole divisors of ${Math.round(r.hz)} Hz that are usable frame rates: ${div.join(', ')}`);
console.log(`  60 fps on this display: ratio ${(r.hz / 60).toFixed(2)} -> ${Math.abs(r.hz / 60 - Math.round(r.hz / 60)) < 0.01 ? 'even' : 'UNEVEN (judder)'}`);
await b.close();
