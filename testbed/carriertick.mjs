/**
 * What is the maximum tick rate of the lane-2 carrier canvas?
 *
 * Lane 2 substitutes our encoded frames into a carrier track's RTP packets, so ONE CARRIER
 * TICK CARRIES ONE FRAME. Parity frames spend ticks too, so a data rate of F fps at group
 * size G needs F * (G+1)/G ticks per second. 72 fps at G=3 needs 96.
 *
 * Three candidate ceilings, and the code currently has all three at once:
 *   1. the rate asked of captureStream()
 *   2. the rate the canvas is made DIRTY — captureStream only emits on a change, and the
 *      1 px flicker runs on setInterval(16), i.e. 62.5 Hz
 *   3. the compositor, which cannot paint faster than the display refreshes
 *
 * (3) would be a hard physical limit worth knowing: on a 60 Hz display no canvas carrier can
 * exceed 60 ticks/s, capping lane-2 data at 45 fps at G=3 no matter what we ask for.
 *
 * Measures the real Brave on the real display, because a headless compositor's timing is not
 * evidence about a real one (rAF in headless reads 78 Hz on a 60 Hz panel).
 *
 *   node testbed/carriertick.mjs
 */
import { chromium } from '/Users/earningsgpt/video calling/testbed/node_modules/playwright-core/index.mjs';

const CASES = [
  ['setInterval(16) + captureStream(60)', 'interval', 16, 60],
  ['setInterval(16) + captureStream(120)', 'interval', 16, 120],
  ['setInterval(4)  + captureStream(120)', 'interval', 4, 120],
  ['rAF flicker     + captureStream(60)', 'raf', 0, 60],
  ['rAF flicker     + captureStream(120)', 'raf', 0, 120],
  ['rAF flicker     + captureStream(0)', 'raf', 0, 0],
  ['no flicker      + captureStream(120)', 'none', 0, 120],
];

const b = await chromium.connectOverCDP('http://127.0.0.1:9333');
const ctx = b.contexts()[0];
const page = await ctx.newPage();
await ctx.route('https://cam.test/**', (r) =>
  r.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>tick</title>' }));
await page.goto('https://cam.test/');

const hz = await page.evaluate(async () => {
  const t = []; await new Promise((res) => { const f = (ts) => { t.push(ts); t.length < 200 ? requestAnimationFrame(f) : res(); }; requestAnimationFrame(f); });
  const d = t.slice(1).map((x, i) => x - t[i]).sort((a, z) => a - z);
  return +(1000 / d[d.length >> 1]).toFixed(1);
});
console.log(`\nreal display: ${hz} Hz  ->  a canvas carrier cannot tick faster than this`);
console.log(`ticks needed for 72 fps data at G=3: 96/s   (at G=7: 82/s)\n`);
console.log(`  configuration                            asked   ticks/s   data fps @G=3   verdict`);

for (const [name, flick, ms, asked] of CASES) {
  const r = await page.evaluate(async ([flick, ms, asked]) => {
    const c = document.createElement('canvas');
    c.width = 320; c.height = 180;
    const g = c.getContext('2d');
    g.fillStyle = '#000'; g.fillRect(0, 0, 320, 180);
    let on = false, stop = false;
    const paint = () => { on = !on; g.fillStyle = on ? '#000' : '#101010'; g.fillRect(0, 0, 1, 1); };
    let timer = null;
    if (flick === 'interval') timer = setInterval(paint, ms);
    else if (flick === 'raf') { const f = () => { if (stop) return; paint(); requestAnimationFrame(f); }; requestAnimationFrame(f); }
    // captureStream(0) means "only on demand"; anything else is a requested rate.
    const st = asked === 0 ? c.captureStream() : c.captureStream(asked);
    const track = st.getVideoTracks()[0];
    // Count PRESENTED frames the same way the wire would see them: a hidden <video> plus
    // requestVideoFrameCallback fires once per frame actually delivered by the track.
    const v = document.createElement('video');
    v.srcObject = st; v.muted = true; v.autoplay = true; v.playsInline = true;
    v.style.cssText = 'position:fixed;left:-9999px;top:0;width:2px;height:2px;opacity:0';
    document.body.appendChild(v);
    await v.play().catch(() => {});
    let n = 0; const t0 = performance.now();
    await new Promise((res) => { const f = () => { n++; v.requestVideoFrameCallback(f); }; v.requestVideoFrameCallback(f); setTimeout(res, 3000); });
    const secs = (performance.now() - t0) / 1000;
    stop = true; if (timer) clearInterval(timer);
    const settings = track.getSettings();
    track.stop(); v.srcObject = null; v.remove();
    return { ticks: +(n / secs).toFixed(1), declared: settings.frameRate ?? null };
  }, [flick, ms, asked]);
  const data = +(r.ticks * 3 / 4).toFixed(1);
  const ok = data >= 72 ? 'CARRIES 72' : data >= 60 ? 'carries 60' : data >= 45 ? 'carries 45' : 'TOO SLOW';
  console.log(`  ${name.padEnd(40)} ${String(asked || '-').padEnd(7)} ${String(r.ticks).padEnd(9)} ${String(data).padEnd(15)} ${ok}`);
}
await page.close();
await b.close();
