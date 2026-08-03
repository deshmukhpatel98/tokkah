// Diagnostic: wrap getUserMedia BEFORE the app loads, then join and dump every
// call the app made with its constraints and its outcome. The direct-probe run
// proved the camera opens; this asks what the APP does differently.
import { chromium } from 'playwright-core';

const BASE = 'http://127.0.0.1:8794';
const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
const ctx = b.contexts()[0];

for (const p of ctx.pages()) {
  if (!p.isClosed() && p.url().startsWith(BASE)) await p.close().catch(() => {});
}
await ctx.grantPermissions(['camera', 'microphone'], { origin: BASE });

await ctx.addInitScript(() => {
  window.__gumTrace = [];
  const md = navigator.mediaDevices;
  const real = md.getUserMedia.bind(md);
  md.getUserMedia = async (c) => {
    const rec = { at: Math.round(performance.now()), ask: JSON.parse(JSON.stringify(c ?? {})) };
    window.__gumTrace.push(rec);
    try {
      const s = await real(c);
      rec.ok = true;
      rec.tracks = s.getTracks().map((t) => ({ kind: t.kind, label: t.label, rs: t.readyState }));
      rec.vsettings = s.getVideoTracks()[0]?.getSettings?.() ?? null;
      return s;
    } catch (e) {
      rec.ok = false;
      rec.err = e.name;
      rec.msg = String(e.message).slice(0, 200);
      rec.constraint = e.constraint ?? null;
      throw e;
    }
  };
});

const page = await ctx.newPage();
page.on('pageerror', (e) => console.log('  [pageerror]', String(e).slice(0, 200)));
page.on('console', (m) => {
  if (m.type() === 'error' && !/503/.test(m.text())) console.log('  [console]', m.text().slice(0, 200));
});

const url = `${BASE}/?room=gumtrace&tape=2&name=probe`;
console.log('goto', url);
await page.goto(url, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(1500);

// What state is the lobby preview's track in at the moment join is clicked?
// `getMedia` reuses it only if readyState === 'live'; if it doesn't, it opens
// the camera a SECOND time while the preview still holds it.
const pre = await page.evaluate(() => {
  const v = document.querySelector('#preview');
  const t = v?.srcObject?.getVideoTracks?.()[0];
  window.__previewProbe = { has: !!v?.srcObject, t: t ? { rs: t.readyState, enabled: t.enabled, muted: t.muted, label: t.label } : null };
  return window.__previewProbe;
});
console.log('preview-at-join', JSON.stringify(pre));

// Join the way the driver does.
const joined = await page.evaluate(async () => {
  const btn = document.querySelector('#join') || [...document.querySelectorAll('button')].find((b) => /join|start/i.test(b.textContent));
  if (!btn) return { clicked: false, buttons: [...document.querySelectorAll('button')].map((b) => b.id + ':' + b.textContent.trim().slice(0, 20)) };
  btn.click();
  return { clicked: true, id: btn.id };
});
console.log('join', JSON.stringify(joined));

await page.waitForTimeout(12000);

const dump = await page.evaluate(() => ({
  gumSummary: window.__gumTrace.map(
    (r) => `${r.at}ms ${r.ask.video ? 'V' : ''}${r.ask.audio ? 'A' : ''} -> ${r.ok ? 'ok ' + (r.tracks || []).map((t) => t.kind).join('+') : r.err + ' ' + r.msg}`,
  ),
  preview: window.__previewProbe ?? null,
  tape: window.__tape
    ? {
        srcprobe: window.__tape.srcprobe,
        devTier: window.__tape.devTier,
        tapeMode: window.__tape.tapeMode,
        lowlight: window.__tape.lowlight,
        luma: window.__tape.luma,
      }
    : null,
  videos: [...document.querySelectorAll('video')].map((v) => ({
    id: v.id,
    has: !!v.srcObject,
    v: v.srcObject?.getVideoTracks?.().length ?? 0,
    a: v.srcObject?.getAudioTracks?.().length ?? 0,
    vw: v.videoWidth,
  })),
  banner: document.querySelector('#err, .error, #status')?.textContent?.trim().slice(0, 200) ?? null,
  bodyClass: document.body.className,
}));
console.log(JSON.stringify(dump, null, 2));
await page.close().catch(() => {});
await b.close();
