// Emulator quick diagnostics: which request 403s, and does the front camera
// deliver frames? (The gUM probe is time-bounded so a wedged camera cannot
// hang the harness — that is itself a finding.)
import { chromium } from 'playwright-core';
const b = await chromium.connectOverCDP(process.env.EMU_CDP ?? 'http://127.0.0.1:9223');
const ctx = b.contexts()[0];
await ctx.grantPermissions(['camera', 'microphone'], { origin: 'https://room.tokkah.com' }).catch(() => {});
const p = await ctx.newPage();
p.on('response', (r) => { if (r.status() >= 400) console.log(`[http ${r.status()}] ${r.request().method()} ${r.url()}`); });
await p.goto('https://room.tokkah.com/', { waitUntil: 'domcontentloaded', timeout: 60000 });
await p.waitForTimeout(6000);
const res = await p.evaluate(() => Promise.race([
  (async () => {
    try {
      const s = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
      const t = s.getVideoTracks()[0];
      let n = 0;
      const rd = new MediaStreamTrackProcessor({ track: t }).readable.getReader();
      const t0 = performance.now();
      while (performance.now() - t0 < 4000) {
        const race = await Promise.race([rd.read(), new Promise((r) => setTimeout(() => r('slow'), 1500))]);
        if (race === 'slow') continue;
        if (race.done) break;
        race.value.close(); n++;
      }
      const st = t.getSettings(); t.stop();
      return { gum: 'ok', frames4s: n, w: st.width, h: st.height };
    } catch (e) { return { gum: `${e.name}: ${e.message}` }; }
  })(),
  new Promise((r) => setTimeout(() => r({ gum: 'WEDGED: no resolve in 12s' }), 12000)),
]));
console.log('camera:', JSON.stringify(res));
await p.close().catch(() => {});
process.exit(0);
