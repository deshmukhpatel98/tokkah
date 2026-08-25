// ── The invite funnel's behaviour ────────────────────────────────────────────
//
// Kin is the only way into a call. This file does three things in order:
//
//   1. read the room out of the link the sender actually pasted,
//   2. hand it to the app over the URL scheme,
//   3. if nothing takes it, show the download -- and either way leave the room
//      name on screen so a person is never stranded.
//
// External file, not inline: the worker's CSP is `script-src 'self'` and an
// inline <script> is silently dropped (that cost a release once already).
(() => {
  'use strict';

  // ── THE ROOM, read the same way the worker read it ─────────────────────────
  //
  // Two invite shapes, both minted by the Mac app's roomURL() (main.swift):
  //   kin.tokkah.com/<abc-defg-hij>   -- a minted 3-4-3 code, the path IS the room
  //   kin.tokkah.com/?r=<name>        -- any named room, hyphens and all
  // The worker routes both here without rewriting the address bar, so the link
  // the sender pasted is still the URL and this parse sees exactly what they
  // shared. Anything not matching is not a fatal error: the page degrades to
  // "ask them for the room name".
  const MEET_RE = /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/;
  // The app's own rule, verbatim from Launcher.swift's URL handler:
  //   name.count <= 64 && name.allSatisfy { isLetter || isNumber || "-" || "_" }
  // A room that fails this here would be refused by the app anyway, so refusing
  // it now is the honest thing -- the alternative is a link that opens the app
  // and then does nothing.
  const OK_RE = /^[A-Za-z0-9_-]{1,64}$/;

  const q = new URLSearchParams(location.search);
  const fromPath = location.pathname.replace(/^\/+/, '').replace(/\/+$/, '');
  const raw = (q.get('r') || (MEET_RE.test(fromPath) ? fromPath : '')).trim();
  const room = OK_RE.test(raw) ? raw : '';

  const el = (id) => document.getElementById(id);
  const roomEl = el('room');
  const stateEl = el('state');

  // textContent, never innerHTML: this string came out of a URL a stranger wrote.
  if (room) {
    roomEl.textContent = room;
    document.title = 'Join "' + room + '" on Kin';
  } else {
    roomEl.textContent = 'ask them for the room name';
    roomEl.style.font = '500 15px/1.5 var(--sans)';
    roomEl.style.color = 'var(--muted)';
  }

  // ── Mac or not ────────────────────────────────────────────────────────────
  //
  // Kin is Mac-only today, and saying so plainly beats a download button that
  // cannot help. userAgentData is the modern answer, navigator.platform the one
  // that still works everywhere; an iPad reports MacIntel with touch points, and
  // it cannot run this app either, so touch rules it out.
  const uaPlat = (navigator.userAgentData && navigator.userAgentData.platform) || '';
  const plat = uaPlat || navigator.platform || '';
  const looksMac = /mac/i.test(plat) || /Macintosh/.test(navigator.userAgent || '');
  const isTouch = (navigator.maxTouchPoints || 0) > 1;
  const isMac = looksMac && !isTouch;

  if (!isMac) {
    stateEl.hidden = true;
    el('notmac').hidden = false;
    el('lede').textContent =
      'Kin is a Mac app. This link opens a call on macOS — there is no browser call.';
    return;
  }

  // ── THE HANDOFF ───────────────────────────────────────────────────────────
  //
  // `tokkah://join/<room>`, and the scheme is not a style choice. The app's URL
  // handler (mac/Sources/tk/Launcher.swift) opens with
  //
  //     guard let s = ..., let u = URL(string: s), u.scheme == "tokkah" else { return }
  //
  // so `tokkah` is the ONLY scheme any shipped build will act on, even though
  // Info.plist registers `kin` alongside it -- a kin:// link launches the app and
  // is then dropped on the floor. Emitting kin:// today would look right and join
  // nothing. Once that guard accepts both, flip SCHEME here and the DMG on the
  // page will already be a build that understands it.
  //
  // The `join/` prefix is the documented shape and the app takes either form:
  //   "tokkah://join/<room> and tokkah://<room> both work"  -- Launcher.swift
  // It parses u.path first (`/<room>` -> `<room>`) and falls back to u.host, so
  // with `join/` the room arrives in the path and the 64-char/charset check runs
  // on the room itself.
  const SCHEME = 'tokkah';
  const deepLink = room
    ? SCHEME + '://join/' + encodeURIComponent(room)
    : null;

  // A top-level navigation, never an iframe: `frame-src` inherits `default-src
  // 'self'`, so <iframe src="tokkah://..."> is blocked by our own CSP. Assigning
  // location.href to an unhandled scheme is a no-op in every current browser --
  // no error page, no history entry -- which is exactly the failure mode this
  // page is built to survive.
  const fire = () => { if (deepLink) location.href = deepLink; };

  // ── Did the app take it? ──────────────────────────────────────────────────
  //
  // There is no callback and there never will be. The only evidence a browser
  // gets is that it stopped being the frontmost thing: macOS activates the app,
  // the tab goes hidden or the window loses focus. So: wait, and if the page is
  // still sitting here in the foreground, assume nothing answered and show the
  // download. Getting this wrong is cheap in one direction only -- a spurious
  // download button under a call that already opened is invisible (the user is
  // in the app), while a missing one strands somebody. Hence a short wait.
  let handed = false;
  const noteHandoff = () => { handed = true; };
  addEventListener('blur', noteHandoff);
  addEventListener('pagehide', noteHandoff);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) noteHandoff();
  });

  const WAIT_MS = 1500;
  let timer = 0;

  function attempt() {
    if (!deepLink) { reveal(); return; }
    handed = false;
    stateEl.hidden = false;
    stateEl.innerHTML = '';
    const dot = document.createElement('i');
    dot.className = 'dot';
    stateEl.appendChild(dot);
    stateEl.appendChild(document.createTextNode('opening Kin…'));
    el('get').hidden = true;
    fire();
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (handed || document.hidden) {
        stateEl.textContent = 'Kin has the call. You can close this tab.';
        return;
      }
      reveal();
    }, WAIT_MS);
  }

  function reveal() {
    stateEl.textContent = room
      ? 'Kin does not seem to be installed on this Mac.'
      : 'This link is missing its room name.';
    el('get').hidden = false;
    if (!room) el('byhand').hidden = true;
  }

  el('retry').addEventListener('click', attempt);

  // Autofire on load. Safari and Chrome both allow a scheme navigation without a
  // click for a same-page load like this one; if a future browser demands a
  // gesture the timeout simply expires and "Try the link again" is a real button.
  attempt();

  // ── The numbers on the download ───────────────────────────────────────────
  //
  // Same source as the front door and the app's own updater: the signed
  // manifest. The HTML ships with the last-known values baked in, so a failed
  // fetch leaves the page a release behind, never blank.
  (async () => {
    try {
      const r = await fetch('/macos/manifest.json', { cache: 'no-cache' });
      if (!r.ok) return;
      const m = await r.json();
      if (m.version) el('ver').textContent = 'v' + m.version;
      // The button points at the VERSIONED dmg: there is no content-disposition
      // on /macos/dl/*, so the browser names the saved file after the last path
      // segment. `Kin.dmg` lands as an anonymous `Kin.dmg`; `Kin-0.46.0.dmg`
      // names itself. Relative, so it stays on whichever host we are on.
      let dl = '/macos/dl/Kin.dmg';
      if (m.dmg) {
        const path = new URL(m.dmg, location.origin).pathname;
        if (/^Kin-\d+\.\d+\.\d+\.dmg$/.test(path.split('/').pop())) {
          dl = path;
          for (const a of document.querySelectorAll('a[data-dl]')) a.href = dl;
        }
      }
      const head = await fetch(dl, { method: 'HEAD' });
      const bytes = head.ok ? Number(head.headers.get('content-length')) : 0;
      if (bytes > 500e3) el('size').textContent = (bytes / 1e6).toFixed(1) + ' MB';
    } catch { /* offline or mid-deploy: the baked numbers stand */ }
  })();
})();
