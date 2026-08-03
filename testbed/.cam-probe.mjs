import { chromium } from 'playwright-core';
const b = await chromium.connectOverCDP('http://127.0.0.1:9222');
const ctx = b.contexts()[0];
const p = ctx.pages().find((x) => !x.isClosed()) ?? (await ctx.newPage());
await p.goto('http://127.0.0.1:8794/', { waitUntil: 'domcontentloaded' });
const out = await p.evaluate(async () => {
  const r = { secure: window.isSecureContext, hasMSTP: 'MediaStreamTrackProcessor' in window, perms: null, devices: null, gum: null };
  try { r.perms = (await navigator.permissions.query({ name: 'camera' })).state; } catch (e) { r.perms = 'query-failed:' + e.name; }
  try {
    const ds = await navigator.mediaDevices.enumerateDevices();
    r.devices = ds.filter((d) => d.kind === 'videoinput').map((d) => d.label || '(no label)');
  } catch (e) { r.devices = 'enum-failed:' + e.name; }
  try {
    const s = await navigator.mediaDevices.getUserMedia({ video: { width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 30 } } });
    const t = s.getVideoTracks()[0];
    r.gum = { ok: true, label: t.label, settings: t.getSettings() };
    t.stop();
  } catch (e) { r.gum = { ok: false, name: e.name, msg: String(e.message).slice(0, 200) }; }
  return r;
});
console.log(JSON.stringify(out, null, 1));
await b.close();
