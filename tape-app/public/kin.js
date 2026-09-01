// ── kin.tokkah.com, the front door ───────────────────────────────────────────
//
// One job: the version and size on the page come from the same signed manifest
// the app's updater reads, so a release can never leave a stale number here.
// The HTML ships with the last-known values baked in; if this fetch fails the
// page is merely a release behind, never blank.
//
// (External file because the worker's CSP is script-src 'self' -- no inline JS.)
(async () => {
  // ── WHICH APP THIS VISITOR CAN ACTUALLY RUN ────────────────────────────────
  //
  // One front door, two apps. A person on a phone offered a disk image has been
  // handed a file their device cannot open, and the commonest thing they will do
  // about it is leave. So the button asks what they are holding first, and the
  // Mac path below is left exactly as it was for everybody else.
  //
  // On the user agent, not on screen width: a narrow window on a Mac is still a
  // Mac, and a tablet in landscape is still Android.
  if (/Android/i.test(navigator.userAgent)) {
    try {
      const r = await fetch('/android/manifest.json', { cache: 'no-cache' });
      if (r.ok) {
        const m = await r.json();
        const path = m.url ? new URL(m.url, location.origin).pathname : '';
        if (/^\/android\/dl\/[A-Za-z0-9._-]+\.apk$/.test(path)) {
          for (const a of document.querySelectorAll('a[data-dl]')) {
            a.href = path;
            const label = a.querySelector('span,b') || a;
            if (a.lastChild && a.lastChild.nodeType === 3) a.lastChild.textContent = ' Download for Android';
          }
          const ver = document.getElementById('ver');
          if (ver && m.version) ver.textContent = 'v' + m.version;
          const size = document.getElementById('size');
          if (size && m.size > 500e3) size.textContent = (m.size / 1e6).toFixed(1) + ' MB';
          const meta = document.querySelector('p.meta');
          if (meta) {
            const spans = meta.querySelectorAll('span');
            if (spans[2]) spans[2].textContent = 'Android 10+';
            if (spans[3]) spans[3].textContent = 'phone or tablet';
          }
          const steps = document.querySelector('p.steps');
          if (steps) {
            steps.textContent = 'Open the downloaded .apk. Android asks once, because this '
              + 'comes from us rather than from Play: tap Settings and allow your browser to '
              + 'install apps. That is the only step.';
          }
          return;
        }
      }
    } catch { /* fall through to the Mac copy rather than showing nothing */ }
  }

  try {
    const r = await fetch('/macos/manifest.json', { cache: 'no-cache' });
    if (!r.ok) return;
    const m = await r.json();
    if (m.version) document.getElementById('ver').textContent = 'v' + m.version;

    // The button points at the VERSIONED dmg, because there is no
    // content-disposition on /macos/dl/* -- the browser names the saved file after
    // the last path segment, so `Kin.dmg` lands as an anonymous `Kin.dmg` and a
    // second download collides with the first. `Kin-0.46.0.dmg` names itself.
    // Relative on purpose: the manifest gives an absolute room.tokkah.com URL and
    // this page is also served from kin.tokkah.com.
    let dl = '/macos/dl/Kin.dmg';
    if (m.dmg) {
      const path = new URL(m.dmg, location.origin).pathname;
      if (/^Kin-\d+\.\d+\.\d+\.dmg$/.test(path.split('/').pop())) {
        dl = path;
        for (const a of document.querySelectorAll('a[data-dl]')) a.href = dl;
      }
    }

    // Size of the thing the button hands over, asked of the thing that hands it
    // over. A 404 body has a content-length too, so only megabytes count.
    const head = await fetch(dl, { method: 'HEAD' });
    const bytes = head.ok ? Number(head.headers.get('content-length')) : 0;
    if (bytes > 500e3) {
      document.getElementById('size').textContent = (bytes / 1e6).toFixed(1) + ' MB';
    }
  } catch { /* offline or mid-deploy: the baked numbers stand */ }
})();
