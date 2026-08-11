// ui-call.mjs — task #28 matrix: self-view lobby + zero-stats + aspect ratios.
//
// For each of 5 viewport shapes (16:9, 9:19.5 portrait, 21:9, 4:3, square):
//   1. pre-join lobby: self view (preview) covers the viewport, mirrored,
//      object-fit cover, camera aspect preserved, no overflow-x, no stats.
//   2. waiting state (A joined, B not yet): #selfFull covers the viewport,
//      mirrored, cover; waiting overlay up; no stats; no overflow-x.
//   3. in-call (both joined, lane 2 + PCM): #selfFull hidden, remote wrap and
//      media (canvas or video) cover the viewport, corner PiP visible and
//      fully on-screen with camera aspect, no stats, no overflow-x.
//   4. (last ratio) B leaves → A returns to the self-view lobby.
//
// Named ui-call.mjs so the machine-wide heavy-run mutex (pgrep -f "call\.mjs")
// sees it. Screenshots go to the scratchpad ui-shots dir.
//
// Run: node testbed/ui-call.mjs [--shots=/path/to/dir]

import { chromium } from 'playwright-core';
import { mkdirSync } from 'node:fs';

const CHROME =
  process.env.TESTBED_CHROME ?? (process.env.HOME + '/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
// Live-only law: prod is the default; the old local default hid behind a dead port.
const BASE = process.env.TESTBED_BASE ?? 'https://room.tokkah.com';
const Q = 'tape=2&pcmaudio=1';
const SHOTS = process.argv.find((a) => a.startsWith('--shots='))?.slice(8)
  ?? '/private/tmp/claude-501/-Users-earningsgpt/a109f52c-5d0e-4a3b-86b5-31ee4739e8ef/scratchpad/ui-shots';
mkdirSync(SHOTS, { recursive: true });

const RATIOS = [
  { name: 'desktop-16x9', w: 1600, h: 900 },
  { name: 'phone-9x19.5', w: 390, h: 844 },
  { name: 'ultrawide-21x9', w: 2100, h: 900 },
  { name: 'tablet-4x3', w: 1024, h: 768 },
  { name: 'square', w: 800, h: 800 },
];
const ARGS = [
  '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
  '--use-file-for-fake-video-capture=/Users/deveshpatel/Downloads/video calling/testbed/media/cam1080.mjpeg',
  '--use-file-for-fake-audio-capture=/Users/deveshpatel/Downloads/video calling/testbed/media/conv/A.wav',
  '--autoplay-policy=no-user-gesture-required',
];
const CAM_ASPECT = 1920 / 1080;

let failures = 0;
const fail = (msg) => { failures++; console.log(`  FAIL ${msg}`); };
const ok = (msg) => console.log(`  ok   ${msg}`);

// DOM scan: no stat-like visible text anywhere in lobby or call UI.
const statsScan = () => {
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (!r.width && !r.height) return false;
    const cs = getComputedStyle(el);
    return cs.display !== 'none' && cs.visibility !== 'hidden' && +cs.opacity > 0;
  };
  const re = /Mbps|kbps|\bfps\b|bitrate|latency|\d+\s?[×x]\s?\d+|\b\d+(\.\d+)?\s?ms\b/i;
  const bad = [];
  for (const el of document.querySelectorAll('#call *, #lobby *')) {
    if (!el.children.length && el.textContent.trim() && visible(el) && re.test(el.textContent)) {
      bad.push(`${el.id || el.className || el.tagName}:"${el.textContent.trim().slice(0, 60)}"`);
    }
  }
  const hud = document.querySelector('#hud');
  if (hud?.classList.contains('on')) bad.push('#hud has .on');
  const chip = document.querySelector('#c-hud');
  if (chip && visible(chip)) bad.push('#c-hud chip visible without ?stats=1');
  return bad;
};

const commonAsserts = (m, label) => {
  if (m.scrollW > m.win.w + 1) fail(`${label}: horizontal overflow scrollW=${m.scrollW} > ${m.win.w}`);
  else ok(`${label}: no overflow-x`);
  if (m.stats.length) fail(`${label}: stats visible → ${m.stats.join(' | ')}`);
  else ok(`${label}: zero stats visible`);
};

// rect covers viewport exactly; media aspect ≈ camera aspect; mirror expected.
// `fit` is 'cover' for self views (a mirror may crop — it is not the subject)
// and 'contain' for the remote, where task #38 §5 forbids cropping the other
// person on either device.
function checkFull(m, label, { mirror, fit = 'cover' }) {
  const covers = Math.abs(m.rect.x) < 1 && Math.abs(m.rect.y) < 1
    && Math.abs(m.rect.w - m.win.w) < 1 && Math.abs(m.rect.h - m.win.h) < 1;
  if (!covers) fail(`${label}: does not cover viewport — rect ${JSON.stringify(m.rect)} vs ${JSON.stringify(m.win)}`);
  else ok(`${label}: covers viewport ${m.win.w}x${m.win.h}`);
  if (m.objectFit !== fit) fail(`${label}: object-fit is ${m.objectFit}, not ${fit}`);
  // The no-crop proof: under contain, the whole captured frame scales to fit
  // INSIDE the viewport, so every pixel the sender produced is on screen.
  if (fit === 'contain' && m.intrinsic?.[0]) {
    const s = Math.min(m.win.w / m.intrinsic[0], m.win.h / m.intrinsic[1]);
    const cw = m.intrinsic[0] * s;
    const ch = m.intrinsic[1] * s;
    if (cw > m.win.w + 1 || ch > m.win.h + 1) fail(`${label}: rendered ${Math.round(cw)}x${Math.round(ch)} overflows viewport — cropped`);
    else ok(`${label}: zero crop (${Math.round(cw)}x${Math.round(ch)} inside ${m.win.w}x${m.win.h})`);
    // Contain means empty space beside the frame, and that space is the wash's
    // whole job. Prove the wash is actually filling it: box covers the viewport
    // AND it is painting cover, not contain. (A 32×18 canvas set to contain
    // letterboxes itself and reinstates the black bars.)
    if (m.fill && !m.fill.flat) {
      // Not equality: the wash carries transform: scale(1.14) on purpose so its
      // own blurred edge never lands inside the frame, and getBoundingClientRect
      // reports the transformed box. The property is "no gap at any edge".
      const fc = m.fill.rect.x <= 1 && m.fill.rect.y <= 1
        && m.fill.rect.x + m.fill.rect.w >= m.win.w - 1
        && m.fill.rect.y + m.fill.rect.h >= m.win.h - 1;
      if (m.fill.display === 'none') fail(`${label}: letterbox wash not displayed under contain`);
      else if (m.fill.fit !== 'cover') fail(`${label}: wash object-fit is ${m.fill.fit}, not cover — it will letterbox itself`);
      else if (!fc) fail(`${label}: wash box ${JSON.stringify(m.fill.rect)} does not cover ${JSON.stringify(m.win)}`);
      else ok(`${label}: letterbox wash fills the viewport`);
    }
  }
  if (m.intrinsic) {
    const a = m.intrinsic[0] / m.intrinsic[1];
    if (Math.abs(a - CAM_ASPECT) / CAM_ASPECT > 0.03) fail(`${label}: intrinsic aspect ${a.toFixed(3)} != camera ${CAM_ASPECT.toFixed(3)}`);
    else ok(`${label}: aspect preserved (${m.intrinsic[0]}x${m.intrinsic[1]})`);
  } else fail(`${label}: no intrinsic size (media not flowing)`);
  const mirrored = m.transform.includes('matrix(-1');
  if (mirror && !mirrored) fail(`${label}: not mirror-flipped (transform=${m.transform})`);
  if (!mirror && mirrored) fail(`${label}: unexpectedly mirrored`);
  if (mirror && mirrored) ok(`${label}: mirrored self view`);
}

for (const [i, r] of RATIOS.entries()) {
  console.log(`\n=== ${r.name} (${r.w}x${r.h}) ===`);
  const room = 'ui' + Math.random().toString(36).slice(2, 8);
  const ctxA = await chromium.launchPersistentContext('', { executablePath: CHROME, headless: true, args: ARGS, viewport: { width: r.w, height: r.h } });
  const ctxB = await chromium.launchPersistentContext('', { executablePath: CHROME, headless: true, args: ARGS, viewport: { width: r.w, height: r.h } });
  const a = await ctxA.newPage(), b = await ctxB.newPage();
  try {
    for (const [p, name] of [[a, 'A'], [b, 'B']]) {
      p.on('pageerror', (e) => console.log(`  ${name} pageerror:`, String(e).slice(0, 140)));
      await p.goto(`${BASE}/?r=${room}&${Q}`, { waitUntil: 'domcontentloaded' });
    }

    // ── 1. pre-join lobby (A) ──────────────────────────────────────────────
    await a.waitForFunction(() => document.querySelector('#preview')?.videoWidth > 0, null, { timeout: 15000 });
    const lob = await a.evaluate((scanSrc) => {
      const v = document.querySelector('#preview');
      const w = document.querySelector('#previewWrap').getBoundingClientRect();
      const vr = v.getBoundingClientRect();
      return {
        rect: { x: w.x, y: w.y, w: w.width, h: w.height },
        vrect: { x: vr.x, y: vr.y, w: vr.width, h: vr.height },
        win: { w: innerWidth, h: innerHeight },
        scrollW: document.documentElement.scrollWidth,
        objectFit: getComputedStyle(v).objectFit,
        transform: getComputedStyle(v).transform,
        intrinsic: [v.videoWidth, v.videoHeight],
        badge: document.querySelector('#previewBadge').textContent,
        stats: eval(`(${scanSrc})`)(),
      };
    }, statsScan.toString());
    checkFull({ ...lob, rect: lob.vrect }, 'A lobby preview', { mirror: true });
    if (/\d/.test(lob.badge) && /×|@|fps/i.test(lob.badge)) fail(`A lobby: badge carries stats "${lob.badge}"`);
    else ok(`A lobby: badge is stat-free ("${lob.badge}")`);
    commonAsserts(lob, 'A lobby');
    await a.screenshot({ path: `${SHOTS}/${r.name}-1-lobby.png` });

    // ── 2. waiting state (A joined, B not) ─────────────────────────────────
    await a.click('#join');
    await a.waitForFunction(() => document.querySelector('#selfFull')?.classList.contains('on'), null, { timeout: 15000 });
    await a.waitForFunction(() => document.querySelector('#selfFull')?.videoWidth > 0, null, { timeout: 15000 });
    const wait = await a.evaluate((scanSrc) => {
      const v = document.querySelector('#selfFull');
      const r2 = v.getBoundingClientRect();
      return {
        rect: { x: r2.x, y: r2.y, w: r2.width, h: r2.height },
        win: { w: innerWidth, h: innerHeight },
        scrollW: document.documentElement.scrollWidth,
        objectFit: getComputedStyle(v).objectFit,
        transform: getComputedStyle(v).transform,
        intrinsic: [v.videoWidth, v.videoHeight],
        waitingUp: !document.querySelector('#waiting').classList.contains('gone'),
        stats: eval(`(${scanSrc})`)(),
      };
    }, statsScan.toString());
    checkFull(wait, 'A waiting selfFull', { mirror: true });
    if (!wait.waitingUp) fail('A waiting: overlay not shown while alone');
    else ok('A waiting: overlay + share link shown');
    commonAsserts(wait, 'A waiting');
    await a.screenshot({ path: `${SHOTS}/${r.name}-2-waiting.png` });

    // ── 3. in-call (B joins) ───────────────────────────────────────────────
    await b.click('#join');
    for (const [p, name] of [[a, 'A'], [b, 'B']]) {
      await p.waitForFunction(() => document.querySelector('#status')?.textContent === 'connected', null, { timeout: 25000 })
        .catch(() => fail(`${name}: never reached "connected"`));
    }
    await a.waitForTimeout(3000); // let first frames paint + layout settle

    for (const [p, name] of [[a, 'A'], [b, 'B']]) {
      const inc = await p.evaluate((scanSrc) => {
        const wrap = document.querySelector('#remoteWrap').getBoundingClientRect();
        const c = document.querySelector('#remoteCanvas');
        const v = document.querySelector('#remote');
        const media = c ?? v;
        const mr = media.getBoundingClientRect();
        return {
          wrap: { x: wrap.x, y: wrap.y, w: wrap.width, h: wrap.height },
          rect: { x: mr.x, y: mr.y, w: mr.width, h: mr.height },
          win: { w: innerWidth, h: innerHeight },
          scrollW: document.documentElement.scrollWidth,
          objectFit: getComputedStyle(media).objectFit,
          transform: getComputedStyle(media).transform,
          intrinsic: c ? [c.width, c.height] : [v.videoWidth, v.videoHeight],
          showing: c ? 'canvas' : 'video',
          selfFullOn: document.querySelector('#selfFull').classList.contains('on'),
          // The letterbox wash. It is a 32×18 canvas, so if anything forces it
          // to object-fit:contain it letterboxes ITSELF and the "no black bars"
          // promise silently becomes black bars. Capture the computed value.
          fill: (() => {
            const f = document.querySelector('#remoteFill');
            const fr = f.getBoundingClientRect();
            const fs = getComputedStyle(f);
            return {
              fit: fs.objectFit, display: fs.display,
              flat: document.querySelector('#call').classList.contains('flat'),
              contain: document.querySelector('#call').classList.contains('contain'),
              rect: { x: fr.x, y: fr.y, w: fr.width, h: fr.height },
            };
          })(),
          floorHintUp: getComputedStyle(document.querySelector('#floorHint')).display !== 'none',
          pip: !!document.querySelector('#selfWrap'), // must be null — feature removed 2026-08-04
          stats: eval(`(${scanSrc})`)(),
        };
      }, statsScan.toString());
      if (inc.selfFullOn) fail(`${name} in-call: #selfFull still on after peer joined`);
      else ok(`${name} in-call: selfFull handed off`);
      checkFull(inc, `${name} in-call remote (${inc.showing})`, { mirror: false, fit: 'contain' });
      const wcovers = Math.abs(inc.wrap.x) < 1 && Math.abs(inc.wrap.y) < 1
        && Math.abs(inc.wrap.w - inc.win.w) < 1 && Math.abs(inc.wrap.h - inc.win.h) < 1;
      if (!wcovers) fail(`${name} in-call: remoteWrap not viewport-sized ${JSON.stringify(inc.wrap)}`);
      // §B.9 taken to its end state (2026-08-04, user directive): the in-call
      // mirror is REMOVED, not merely off — the element must not exist at all.
      if (inc.pip) fail(`${name} in-call: #selfWrap still in the DOM (self-view PiP was removed)`);
      else ok(`${name} in-call: no self-view PiP in the DOM`);
      if (inc.floorHintUp) fail(`${name} in-call: floor sentence banner is up by default (must be an icon — §6)`);
      else ok(`${name} in-call: no loud-room banner across the face`);
      commonAsserts(inc, `${name} in-call`);
      await p.screenshot({ path: `${SHOTS}/${r.name}-3-incall-${name}.png` });
    }

    // ── 3b. the new interaction gates, on A ────────────────────────────────
    {
      const win = await a.evaluate(() => ({ w: innerWidth, h: innerHeight }));
      // Mouse movement reveals the chrome (touch taps toggle it; that path is
      // separate by design so a stray pointermove can't fight a tap).
      await a.mouse.move(win.w / 2, win.h / 2);
      await a.waitForTimeout(120);
      const barUp = await a.evaluate(() => document.querySelector('#bar').classList.contains('show'));
      if (!barUp) fail('A chrome: bar did not reveal on pointer movement');
      else ok('A chrome: bar reveals on pointer movement');

      // Every visible control clears the 44 pt / 48 dp floor.
      const targets = await a.evaluate(() =>
        [...document.querySelectorAll('#bar .icon-btn')]
          .filter((el) => getComputedStyle(el).display !== 'none')
          .map((el) => {
            const r2 = el.getBoundingClientRect();
            return { id: el.id, w: Math.round(r2.width), h: Math.round(r2.height), right: Math.round(r2.right), bottom: Math.round(r2.bottom), left: Math.round(r2.left) };
          }));
      const small = targets.filter((t) => t.w < 44 || t.h < 44);
      if (small.length) fail(`A targets: below 44 px → ${small.map((t) => `${t.id} ${t.w}x${t.h}`).join(', ')}`);
      else ok(`A targets: ${targets.length} controls all ≥ 44 px`);
      const off = targets.filter((t) => t.left < 0 || t.right > win.w + 1 || t.bottom > win.h + 1);
      if (off.length) fail(`A targets: off-viewport → ${off.map((t) => t.id).join(', ')}`);
      else ok('A targets: whole bar on-screen');
      const lowest = Math.min(...targets.map((t) => t.bottom - t.h));
      if (lowest < win.h * 0.45) fail(`A targets: controls reach into the top ${Math.round((1 - lowest / win.h) * 100)}% — out of the thumb arc`);
      else ok('A targets: controls sit in the bottom half (one-handed reach)');

      // 44 px is the floor only where the CSS actually promises 44. The
      // `@media (max-width: 380px)` block in index.html is the single place the
      // circles shrink to the HIG minimum; everywhere wider the rule is 48 px.
      // Asserting 44 on a 1600 px desktop lets a 45 px regression ship on every
      // screen but the narrowest phone — controls that read as tappable and
      // then need a second, more careful jab.
      const floor = win.w > 380 ? 48 : 44;
      const under = targets.filter((t) => t.w < floor || t.h < floor);
      if (under.length) fail(`A targets: below the ${floor} px this ${win.w} px viewport promises → ${under.map((t) => `${t.id} ${t.w}x${t.h}`).join(', ')}`);
      else ok(`A targets: ${targets.length} controls all ≥ ${floor} px`);

      // Safe-area padding read as a number, not inferred from where the pixels
      // landed. env(safe-area-inset-bottom) resolves to 0 in every headless
      // viewport, so a regression to `padding-bottom: 0` renders here exactly
      // like the correct `max(14px, env(...))` — and ships a leave button under
      // the iPhone home indicator, where the swipe that dismisses the app and
      // the tap that ends the call live on the same 14 px strip. Assert the
      // floor of the max(), then assert the gap it is supposed to buy.
      const barPad = await a.evaluate(() => parseFloat(getComputedStyle(document.querySelector('#bar')).paddingBottom));
      if (!(barPad >= 14)) fail(`A chrome: #bar padding-bottom is ${barPad} px — the max(14px, env(safe-area-inset-bottom)) floor is gone`);
      else ok(`A chrome: bar keeps its ${barPad} px safe-area floor`);
      const edgeGap = win.h - Math.max(...targets.map((t) => t.bottom));
      if (edgeGap < 14) fail(`A targets: lowest control stops ${edgeGap} px short of the bottom edge — inside the home-bar strip`);
      else ok(`A targets: lowest control clears the bottom edge by ${edgeGap} px`);

      // The resting row is the NARROWEST the bar ever gets, so measuring only
      // it proves nothing. Two states make it wider and both used to clip:
      // #flip (invisible here because the fake camera exposes one device, but
      // present on every real phone) and the 150 px leave-confirm pill.
      const rowFits = async (label) => {
        const m = await a.evaluate(() => {
          const bar = document.querySelector('#bar');
          // A "target" is what a finger can actually hit. A control that is
          // collapsed and pointer-events:none (the confirm state) is not a
          // small target, it is not a target — measuring it against 44 px
          // would report a failure that no user can experience.
          const kids = [...bar.querySelectorAll('.icon-btn')]
            .filter((el) => {
              const cs = getComputedStyle(el);
              return cs.display !== 'none' && cs.pointerEvents !== 'none'
                && +cs.opacity > 0 && el.getBoundingClientRect().width > 0;
            })
            .map((el) => { const q = el.getBoundingClientRect(); return { id: el.id, l: Math.round(q.left), r: Math.round(q.right), w: Math.round(q.width) }; });
          return { kids, over: bar.scrollWidth - bar.clientWidth, w: innerWidth };
        });
        const clipped = m.kids.filter((t) => t.l < 0 || t.r > m.w + 1);
        if (clipped.length) fail(`A targets (${label}): clipped → ${clipped.map((t) => `${t.id} ${t.l}..${t.r} of ${m.w}`).join(', ')}`);
        else if (m.over > 1) fail(`A targets (${label}): row overflows its bar by ${m.over} px`);
        else ok(`A targets (${label}): ${m.kids.length} controls fit in ${m.w} px`);
        const tooSmall = m.kids.filter((t) => t.w < 44);
        if (tooSmall.length) fail(`A targets (${label}): below 44 px → ${tooSmall.map((t) => `${t.id} ${t.w}`).join(', ')}`);
      };
      await a.evaluate(() => { document.querySelector('#flip').style.display = ''; });
      await a.waitForTimeout(80);
      await rowFits('two-camera phone');
      await a.click('#leave');
      await a.waitForTimeout(320);
      await rowFits('leave armed');
      // The safety property of the confirm state: nothing else is hittable, so
      // a finger already moving toward "leave" cannot land on mute instead.
      const live = await a.evaluate(() =>
        [...document.querySelectorAll('#bar .icon-btn')]
          .filter((el) => { const cs = getComputedStyle(el); return cs.display !== 'none' && cs.pointerEvents !== 'none' && +cs.opacity > 0; })
          .map((el) => el.id));
      if (live.length !== 1 || live[0] !== 'leave') fail(`A leave: ${live.length} controls still hittable while armed → ${live.join(', ')}`);
      else ok('A leave: confirm state leaves only the pill hittable');
      const pill = await a.evaluate(() => {
        const q = document.querySelector('#leave').getBoundingClientRect();
        return { w: Math.round(q.width), text: !!document.querySelector('#leave .lbl')?.offsetWidth };
      });
      if (!pill.text || pill.w < 120) fail(`A targets: confirm pill did not expand (${pill.w} px, label ${pill.text})`);
      else ok(`A targets: confirm pill reads its label at ${pill.w} px`);
      await a.keyboard.press('Escape');
      await a.waitForTimeout(320);
      await a.evaluate(() => { document.querySelector('#flip').style.display = 'none'; });
      await a.waitForTimeout(80);

      // Dormant features stay dead (2026-08-04, user directive): no self-view
      // pin, no life size, no eye-line alignment anywhere in the sheet.
      await a.click('#more');
      await a.waitForTimeout(250);
      const dormant = await a.evaluate(() =>
        ['c-selfview', 'c-lifesize', 'c-gaze', 'calDetails', 'selfWrap']
          .filter((id) => document.getElementById(id)));
      if (dormant.length) fail(`A dormant: removed features back in the DOM → ${dormant.join(', ')}`);
      else ok('A dormant: self-view pin / life size / eye-line / calibration all absent');
      await a.screenshot({ path: `${SHOTS}/${r.name}-5-sheet.png` });
      await a.keyboard.press('Escape');
      await a.waitForTimeout(300);

      // ── Pinned mirror: bar × PiP × badges measured against each other ──────
      // Every geometry assertion above measures one thing on its own, and the
      // collisions a person actually hits are between things: a 132 px mirror
      // parked over the leave button, a mute badge sitting under the mic
      // circle. Only the pinned state puts all of them on screen at once, and
      // until now nothing in this file ever pinned — so the whole cross-product
      // was enumerated in UI-SPEC §20 and never gated.
      //
      // Measured against the BUTTONS, deliberately, not #bar's own box: the bar
      // is ~88 px tall because 26 px of it is the gradient that fades the video
      // out, and that gradient is meant to slide under the PiP by a pixel or
      // two. Intersecting #bar would report a collision that is soft gradient
      // behind a rounded corner — a failure no finger and no eye can find.
      const chromeBoxes = () => a.evaluate(() => {
        const boxes = [];
        const add = (el, name) => {
          if (!el) return;
          const cs = getComputedStyle(el);
          if (cs.display === 'none' || cs.visibility === 'hidden' || +cs.opacity === 0) return;
          const q = el.getBoundingClientRect();
          if (q.width < 1 || q.height < 1) return;
          boxes.push({ name, x: q.x, y: q.y, w: q.width, h: q.height });
        };
        for (const el of document.querySelectorAll('#bar .icon-btn')) add(el, el.id);
        add(document.querySelector('#more'), 'more');
        add(document.querySelector('#floorIcon'), 'floorIcon');
        return { boxes, barShown: document.querySelector('#bar').classList.contains('show') };
      });
      const noCollisions = (m, label, expect) => {
        // A no-overlap check over an empty screen passes for the wrong reason,
        // so name what has to be up for the state to mean anything.
        const names = m.boxes.map((q) => q.name);
        const missing = expect.filter((n) => !names.includes(n));
        if (!m.barShown || missing.length) {
          fail(`A overlap (${label}): state never materialised — bar ${m.barShown ? 'up' : 'hidden'}, missing ${missing.join(', ') || 'nothing'}`);
          return;
        }
        const hits = [];
        for (let x = 0; x < m.boxes.length; x++) {
          for (let y = x + 1; y < m.boxes.length; y++) {
            const p = m.boxes[x], q = m.boxes[y];
            // Half a pixel of slack: fractional video heights and rounded
            // corners put exact adjacency on .999 often enough that a strict
            // > 0 would flag geometry that is visibly clear.
            const ow = Math.min(p.x + p.w, q.x + q.w) - Math.max(p.x, q.x);
            const oh = Math.min(p.y + p.h, q.y + q.h) - Math.max(p.y, q.y);
            if (ow > 0.5 && oh > 0.5) hits.push(`${p.name}×${q.name} by ${Math.round(ow)}×${Math.round(oh)} px`);
          }
        }
        if (hits.length) fail(`A overlap (${label}): ${hits.join(', ')}`);
        else ok(`A overlap (${label}): ${m.boxes.length} chrome boxes, none intersecting`);
      };
      const showChrome = async () => {
        await a.mouse.move(win.w / 2, win.h / 2);
        await a.mouse.move(win.w / 2 + 4, win.h / 2 + 4);
        await a.waitForFunction(() => document.querySelector('#bar').classList.contains('show'), null, { timeout: 4000 })
          .catch(() => fail('A chrome: bar would not come back for the overlap measurement'));
      };
      await showChrome();
      noCollisions(await chromeBoxes(), 'bar out', ['leave']);

      // Mute: the mic circle is the whole state now (badge and speaking dots
      // removed 2026-08-04, user directive) — assert the two removed elements
      // stay gone, then that the circle and the track agree.
      const ghosts = await a.evaluate(() =>
        ['muteBadge', 'dots'].filter((id) => document.getElementById(id)));
      if (ghosts.length) fail(`A removed chrome back in the DOM → ${ghosts.join(', ')}`);
      else ok('A dormant: mute badge / speaking dots absent');
      await a.click('#mic');
      const muted = await a.evaluate(() => ({
        off: document.querySelector('#mic').dataset.off,
        // Under ?pcmaudio=1 the mic is off the peer connection entirely, so
        // getSenders cannot see it — the app's own getter is the instrument.
        track: window.__tape?.micEnabled,
      }));
      if (muted.off !== '1') fail(`A mute: mic circle state wrong ${JSON.stringify(muted)}`);
      else ok('A mute: icon reds out');
      if (muted.track !== false) fail(`A mute: mic track still enabled (${muted.track})`);
      else ok('A mute: outbound audio actually muted');
      // Auto-hide has two halves and both are load-bearing: the controls stay
      // pinned for the first 10 s so the icon vocabulary can be learned, and
      // then they get out of the face. Assert BOTH — a bar that hides early
      // fails discoverability, one that never hides fails the whole thesis.
      await a.mouse.move(1, 1);
      const pinLeft = await a.evaluate(() => window.__tape.chrome.pinnedForMs);
      if (pinLeft > 400) {
        await a.waitForTimeout(Math.min(pinLeft - 300, 3000));
        const early = await a.evaluate(() => document.querySelector('#bar').classList.contains('show'));
        if (!early) fail('A chrome: bar hid while still inside the 10 s intro pin');
        else ok('A chrome: bar stays pinned through the intro window');
      }
      await a.waitForFunction(() => !document.querySelector('#bar').classList.contains('show'), null, { timeout: pinLeft + 5000 })
        .then(() => ok('A chrome: bar auto-hid once idle'))
        .catch(() => fail(`A chrome: bar never auto-hid (pin had ${pinLeft} ms left)`));
      await a.click('#mic', { force: true });

      // Leave takes two deliberate taps (§B.11).
      await a.mouse.move(win.w / 2, win.h / 2);
      await a.waitForTimeout(120);
      await a.click('#leave');
      const armed = await a.evaluate(() => ({
        confirming: document.querySelector('#leave').classList.contains('confirming'),
        stillInCall: getComputedStyle(document.querySelector('#call')).display !== 'none',
      }));
      if (!armed.confirming || !armed.stillInCall) fail(`A leave: first tap did not arm-and-hold ${JSON.stringify(armed)}`);
      else ok('A leave: first tap arms a confirm, call still up');
      await a.keyboard.press('Escape');
      const disarmed = await a.evaluate(() => document.querySelector('#leave').classList.contains('confirming'));
      if (disarmed) fail('A leave: Escape did not cancel the confirm');
      else ok('A leave: Escape cancels');
    }

    // ── 3c. two tiles (§6 phase 5, `#call.three`) ──────────────────────────
    // Three people means two remote tiles, and the geometry that has to hold is
    // NOT the geometry a 1:1 call is gated on: a full-bleed picture with chrome
    // floating over it is right for one connection and wrong for two, because
    // the bar would then sit over one person's tile and read as belonging to
    // them. So this section drives the real class onto the real markup and
    // measures the split against the same instruments section 3b uses.
    //
    // The class plus a picture in the second tile is the whole precondition —
    // `window.__tape.startVideoPair()` builds a real second pc but needs a real
    // third occupant, which is phase 6's rig, not this one. Nothing about the
    // LAYOUT can tell the difference: the tiles are sized by CSS off `.three`,
    // and the state lines are set through the shipped `setTileState` rather
    // than by poking textContent (which would prove only that textContent
    // exists).
    {
      const win = await a.evaluate(() => ({ w: innerWidth, h: innerHeight }));
      await a.evaluate(() => {
        const src = document.querySelector('#remote').srcObject
          ?? document.querySelector('#selfFull').srcObject;
        const v = document.querySelector('#remote2');
        if (src) { v.srcObject = src; v.play?.().catch(() => {}); }
        document.querySelector('#call').classList.add('three');
        // Both state lines up at once: they are the thing most likely to be
        // measured only in isolation and to collide in practice.
        window.__tape.tileState(0, 'held');
        window.__tape.tileState(1, 'paused');
      });
      // Chrome has to be UP for the tile × bar measurement to mean anything.
      await a.mouse.move(win.w / 2, win.h / 2);
      await a.mouse.move(win.w / 2 + 4, win.h / 2 + 4);
      await a.waitForFunction(() => document.querySelector('#bar').classList.contains('show'), null, { timeout: 4000 })
        .catch(() => fail('A three: bar would not come up for the two-tile measurement'));
      await a.waitForTimeout(300);

      const three = await a.evaluate((scanSrc) => {
        const box = (el) => { const q = el.getBoundingClientRect(); return { x: q.x, y: q.y, w: q.width, h: q.height }; };
        const tile = (sfx) => {
          const wrap = document.querySelector(`#remoteWrap${sfx}`);
          const media = document.querySelector(`#remoteCanvas${sfx}`) ?? document.querySelector(`#remote${sfx}`);
          const fill = document.querySelector(`#remoteFill${sfx}`);
          const line = document.querySelector(`#tileState${sfx}`);
          const fs = getComputedStyle(fill);
          const ls = getComputedStyle(line);
          return {
            wrap: box(wrap), wrapDisplay: getComputedStyle(wrap).display,
            mediaFit: getComputedStyle(media).objectFit, showing: media.tagName.toLowerCase(),
            fill: { rect: box(fill), fit: fs.objectFit, display: fs.display },
            line: { rect: box(line), display: ls.display, text: line.textContent },
          };
        };
        return {
          t1: tile(''), t2: tile('2'),
          bar: [...document.querySelectorAll('#bar .icon-btn')]
            .filter((el) => { const cs = getComputedStyle(el); return cs.display !== 'none' && +cs.opacity > 0 && el.getBoundingClientRect().width > 1; })
            .map((el) => ({ id: el.id, ...box(el) })),
          barShown: document.querySelector('#bar').classList.contains('show'),
          barPad: parseFloat(getComputedStyle(document.querySelector('#bar')).paddingBottom),
          contain: document.querySelector('#call').classList.contains('contain'),
          flat: document.querySelector('#call').classList.contains('flat'),
          win: { w: innerWidth, h: innerHeight },
          scrollW: document.documentElement.scrollWidth,
          pip: !!document.querySelector('#selfWrap'),
          stats: eval(`(${scanSrc})`)(),
        };
      }, statsScan.toString());

      const tiles = [['tile 1', three.t1], ['tile 2', three.t2]];
      // The overlap primitive the whole section shares. Same 0.5 px slack as
      // the chrome cross-product above, for the same fractional-pixel reason.
      const over = (p, q) => {
        const ow = Math.min(p.x + p.w, q.x + q.w) - Math.max(p.x, q.x);
        const oh = Math.min(p.y + p.h, q.y + q.h) - Math.max(p.y, q.y);
        return (ow > 0.5 && oh > 0.5) ? `${Math.round(ow)}×${Math.round(oh)} px` : null;
      };

      // Both tiles exist and are actually rendered.
      for (const [name, t] of tiles) {
        if (t.wrapDisplay === 'none' || t.wrap.w < 2 || t.wrap.h < 2) fail(`A three ${name}: not rendered (display ${t.wrapDisplay}, box ${JSON.stringify(t.wrap)})`);
        else ok(`A three ${name}: rendered ${Math.round(t.wrap.w)}x${Math.round(t.wrap.h)}`);
      }

      // Fully on-screen. A tile that runs off the edge is a person with their
      // head cropped by the device, which is the exact thing §5 forbids.
      for (const [name, t] of tiles) {
        const onscreen = t.wrap.x >= -1 && t.wrap.y >= -1
          && t.wrap.x + t.wrap.w <= three.win.w + 1 && t.wrap.y + t.wrap.h <= three.win.h + 1;
        if (!onscreen) fail(`A three ${name}: off-screen — ${JSON.stringify(t.wrap)} in ${three.win.w}x${three.win.h}`);
        else ok(`A three ${name}: fully on-screen`);
      }

      // Side by side on landscape, stacked on portrait — and equal on whichever
      // axis is being split, within a pixel. Not "roughly half": two tiles of
      // visibly different size is a spotlight, and there is no spotlight here.
      const sideBySide = three.t2.wrap.x >= three.t1.wrap.x + three.t1.wrap.w - 1;
      const wantSide = three.win.w > three.win.h;
      if (sideBySide !== wantSide) fail(`A three: ${sideBySide ? 'side-by-side' : 'stacked'} on a ${three.win.w}x${three.win.h} viewport — expected ${wantSide ? 'side-by-side' : 'stacked'}`);
      else ok(`A three: ${wantSide ? 'side by side (landscape)' : 'stacked (portrait)'}`);
      const axis = sideBySide ? 'w' : 'h';
      const d = Math.abs(three.t1.wrap[axis] - three.t2.wrap[axis]);
      if (d > 1) fail(`A three: tiles unequal on the split axis — ${three.t1.wrap[axis].toFixed(1)} vs ${three.t2.wrap[axis].toFixed(1)} (${d.toFixed(1)} px apart)`);
      else ok(`A three: tiles equal on the split axis (${three.t1.wrap[axis].toFixed(1)} px, Δ${d.toFixed(2)})`);
      const tt = over(three.t1.wrap, three.t2.wrap);
      if (tt) fail(`A three: the two tiles overlap by ${tt}`);
      else ok('A three: tiles do not overlap each other');

      // NEITHER tile runs under the bar. Measured against the BUTTONS, exactly
      // as the chrome cross-product is: #bar's own box is ~88 px tall because
      // 26 px of it is the gradient that fades the video out, and that gradient
      // is meant to lie over the picture.
      if (!three.barShown || !three.bar.length) {
        fail(`A three: bar never materialised for the tile × bar measurement (shown ${three.barShown}, ${three.bar.length} buttons)`);
      } else {
        const hits = [];
        for (const [name, t] of tiles) {
          for (const btn of three.bar) {
            const o = over(t.wrap, btn);
            if (o) hits.push(`${name}×${btn.id} by ${o}`);
          }
        }
        if (hits.length) fail(`A three: tiles overlap the control bar → ${hits.join(', ')}`);
        else ok(`A three: neither tile reaches the bar (${three.bar.length} buttons clear)`);
      }
      if (!(three.barPad >= 14)) fail(`A three: #bar padding-bottom is ${three.barPad} px — safe-area floor gone in two-tile mode`);
      else ok(`A three: bar keeps its ${three.barPad} px safe-area floor`);

      // Each tile's OWN wash covers its OWN tile with no gap at any edge, and
      // is still painting `cover`. This is the selector-collision gate: a rule
      // wide enough to span both tiles makes a 32×18 wash canvas letterbox
      // itself and quietly reinstates the black bars the policy removed.
      for (const [name, t] of tiles) {
        if (!three.contain || three.flat) { ok(`A three ${name}: wash not expected (contain=${three.contain}, flat=${three.flat})`); continue; }
        const f = t.fill.rect;
        const covers = f.x <= t.wrap.x + 1 && f.y <= t.wrap.y + 1
          && f.x + f.w >= t.wrap.x + t.wrap.w - 1 && f.y + f.h >= t.wrap.y + t.wrap.h - 1;
        if (t.fill.display === 'none') fail(`A three ${name}: letterbox wash not displayed under contain`);
        else if (t.fill.fit !== 'cover') fail(`A three ${name}: wash object-fit is ${t.fill.fit}, not cover — it will letterbox itself`);
        else if (!covers) fail(`A three ${name}: wash ${JSON.stringify(f)} leaves a gap in tile ${JSON.stringify(t.wrap)}`);
        else ok(`A three ${name}: wash fills its own tile, no gap at any edge`);
        if (t.mediaFit !== 'contain') fail(`A three ${name}: media object-fit is ${t.mediaFit}, not contain — the other person is being cropped`);
        else ok(`A three ${name}: contain-fit (${t.showing}), zero crop`);
      }

      // Each tile carries its own state line, inside its own tile, clear of the
      // bar. Two lines up at once is the state that has to hold: one sentence
      // over the middle of a split screen names neither person.
      for (const [name, t, want] of [['tile 1', three.t1, 'holding · audio live'], ['tile 2', three.t2, 'connection paused']]) {
        if (t.line.display === 'none' || t.line.rect.w < 2) { fail(`A three ${name}: state line not rendered`); continue; }
        if (t.line.text !== want) fail(`A three ${name}: state line reads "${t.line.text}", expected "${want}"`);
        else ok(`A three ${name}: state line reads "${t.line.text}"`);
        const inside = t.line.rect.x >= t.wrap.x - 1 && t.line.rect.y >= t.wrap.y - 1
          && t.line.rect.x + t.line.rect.w <= t.wrap.x + t.wrap.w + 1
          && t.line.rect.y + t.line.rect.h <= t.wrap.y + t.wrap.h + 1;
        if (!inside) fail(`A three ${name}: state line ${JSON.stringify(t.line.rect)} escapes its tile ${JSON.stringify(t.wrap)}`);
        else ok(`A three ${name}: state line sits inside its own tile`);
        const clash = three.bar.map((btn) => over(t.line.rect, btn) && `${btn.id}`).filter(Boolean);
        if (clash.length) fail(`A three ${name}: state line collides with ${clash.join(', ')}`);
      }

      // The 1:1 gates that must survive the split, re-measured here rather than
      // assumed: a two-tile screen is still a screen with no stats on it, no
      // horizontal overflow, no self-view PiP, and controls at their promised
      // size and fully on-screen.
      commonAsserts(three, 'A three');
      if (three.pip) fail('A three: #selfWrap back in the DOM (self-view PiP was removed)');
      else ok('A three: no self-view PiP in the DOM');
      const floor3 = three.win.w > 380 ? 48 : 44;
      const under3 = three.bar.filter((t) => t.w < floor3 || t.h < floor3);
      if (under3.length) fail(`A three: controls below the ${floor3} px this ${three.win.w} px viewport promises → ${under3.map((t) => `${t.id} ${Math.round(t.w)}x${Math.round(t.h)}`).join(', ')}`);
      else ok(`A three: ${three.bar.length} controls all ≥ ${floor3} px`);
      const off3 = three.bar.filter((t) => t.x < -1 || t.x + t.w > three.win.w + 1 || t.y + t.h > three.win.h + 1);
      if (off3.length) fail(`A three: controls off-viewport → ${off3.map((t) => t.id).join(', ')}`);
      else ok('A three: whole bar on-screen in two-tile mode');
      await a.screenshot({ path: `${SHOTS}/${r.name}-6-three.png` });

      // Back to 1:1 for section 4 — and the flag-off gate itself: with `.three`
      // gone the second tile and both state lines must be unrenderable again.
      await a.evaluate(() => {
        window.__tape.tileState(0, null);
        window.__tape.tileState(1, null);
        document.querySelector('#call').classList.remove('three');
        document.querySelector('#remote2').srcObject = null;
      });
      await a.waitForTimeout(200);
      const back = await a.evaluate(() => {
        const wrap = document.querySelector('#remoteWrap');
        const q = wrap.getBoundingClientRect();
        return {
          wrap: { x: q.x, y: q.y, w: q.width, h: q.height },
          win: { w: innerWidth, h: innerHeight },
          tile2: getComputedStyle(document.querySelector('#remoteWrap2')).display,
          lines: ['tileState', 'tileState2']
            .map((id) => getComputedStyle(document.querySelector(`#${id}`)).display)
            .filter((dsp) => dsp !== 'none'),
        };
      });
      const full = Math.abs(back.wrap.x) < 1 && Math.abs(back.wrap.y) < 1
        && Math.abs(back.wrap.w - back.win.w) < 1 && Math.abs(back.wrap.h - back.win.h) < 1;
      if (!full) fail(`A three→1:1: first tile did not return to full-bleed ${JSON.stringify(back.wrap)}`);
      else ok('A three→1:1: first tile back to full-bleed');
      if (back.tile2 !== 'none') fail(`A three→1:1: second tile still rendering (display ${back.tile2})`);
      else ok('A three→1:1: second tile inert again');
      if (back.lines.length) fail(`A three→1:1: a tile state line still renders without .three (${back.lines.join(', ')})`);
      else ok('A three→1:1: no tile state line can render without .three');
    }

    // ── 4. peer-left returns to the self-view lobby (last ratio only) ───────
    if (i === RATIOS.length - 1) {
      await b.close();
      await a.waitForFunction(
        () => !document.querySelector('#waiting').classList.contains('gone')
          && document.querySelector('#selfFull').classList.contains('on'),
        null, { timeout: 10000 },
      ).then(() => ok('A after peer-left: back to self-view lobby'))
        .catch(() => fail('A after peer-left: did not return to self-view lobby'));
      await a.screenshot({ path: `${SHOTS}/${r.name}-4-peerleft-A.png` });
    }
  } finally {
    await ctxA.close().catch(() => {});
    await ctxB.close().catch(() => {});
  }
}

console.log(`\n${failures ? `${failures} FAILURES` : 'ALL PASS'}`);
process.exit(failures ? 1 : 0);
