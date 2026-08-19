import { chromium } from 'playwright-core';
const ROOM = process.argv[2];
const CHROME = process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
const SIL = '/Users/deveshpatel/Downloads/video calling/testbed/media/probe/silence.wav';
const b = await chromium.launch({ executablePath: CHROME, headless: true,
  args: ['--use-fake-ui-for-media-stream','--use-fake-device-for-media-stream',
         `--use-file-for-fake-audio-capture=${SIL}`,'--autoplay-policy=no-user-gesture-required','--mute-audio'] });
const pg = await b.newPage();
// Capture the telemetry the app POSTs: those payloads carry the REAL peers'
// snapshots, including their own wastedShift / bPerFrame from real microphones.
const posts = [];
await pg.route('**/log', async (route, req) => {
  if (req.method() === 'POST') { try { posts.push(req.postData() ?? ''); } catch {} }
  await route.continue();
});
await pg.goto('https://room.tokkah.com/' + ROOM, { waitUntil: 'domcontentloaded' });
await pg.waitForSelector('#join', { timeout: 20000 });
await pg.click('#join');
await new Promise(r => setTimeout(r, 30000));
const found = await pg.evaluate(() => {
  const hits = {}; const seen = new Set();
  const walk = (o, path, d) => {
    if (!o || d > 4 || seen.has(o) || typeof o !== 'object') return;
    seen.add(o);
    for (const k of Object.keys(o)) {
      let v; try { v = o[k]; } catch { continue; }
      if (/^(rxWastedShift|wastedShift|bPerFrame|shift8Pct|fit32767Pct|mouthToEarMs|sampleRate)$/.test(k)) hits[path + '.' + k] = v;
      if (v && typeof v === 'object') walk(v, path + '.' + k, d + 1);
    }
  };
  try { walk(window.__tape, '__tape', 0); } catch {}
  return { hits, tapeKeys: Object.keys(window.__tape ?? {}) };
}).catch(e => ({ err: String(e) }));
await b.close();
console.log('telemetry POSTs captured:', posts.length);
const j = posts.join('\n');
for (const f of ['wastedShift','bPerFrame','fit32767Pct','mouthToEarMs']) {
  const m = [...j.matchAll(new RegExp('"' + f + '":([^,}]+)','g'))].slice(0,6).map(x=>x[1]);
  if (m.length) console.log('  POST', f, '=', m.join(' '));
}
console.log(JSON.stringify(found, null, 1).slice(0, 1800));
