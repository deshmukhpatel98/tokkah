// ── kin.tokkah.com, the front door ───────────────────────────────────────────
//
// One job: the version and size on the page come from the same signed manifest
// the app's updater reads, so a release can never leave a stale number here.
// The HTML ships with the last-known values baked in; if this fetch fails the
// page is merely a release behind, never blank.
//
// (External file because the worker's CSP is script-src 'self' -- no inline JS.)
(async () => {
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
