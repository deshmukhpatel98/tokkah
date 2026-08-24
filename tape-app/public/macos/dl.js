// ── The file that lands in ~/Downloads carries its version ───────────────────
//
// There is no content-disposition on /macos/dl/*, so the browser names the saved
// file after the last path segment. `Kin.dmg` therefore lands as an anonymous
// `Kin.dmg` that tells you nothing a week later, and a second download collides
// with the first as `Kin-1.dmg`. `Kin-0.46.0.dmg` names itself.
//
// The HTML ships with the current versioned URL baked in, so this page works with
// JavaScript off and the link is never dead. This only moves it FORWARD to
// whatever the signed manifest -- the same one the app's own updater reads --
// currently advertises, so a release can never leave a stale version here.
//
// (External file because the worker's CSP is script-src 'self' -- no inline JS.)
(async () => {
  const links = document.querySelectorAll('a[data-dl]');
  if (!links.length) return;
  try {
    const r = await fetch('/macos/manifest.json', { cache: 'no-cache' });
    if (!r.ok) return;
    const m = await r.json();
    if (!m.dmg) return;
    // Same-origin and relative on purpose: this page is served from both
    // room.tokkah.com and kin.tokkah.com, and the manifest names an absolute
    // room.tokkah.com URL. Taking only the path keeps the download on whichever
    // host the visitor is already on.
    const path = new URL(m.dmg, location.origin).pathname;
    const file = path.split('/').pop();
    if (!/^Kin-\d+\.\d+\.\d+\.dmg$/.test(file)) return;  // never point at a shape we did not expect
    for (const a of links) {
      a.href = path;
      const label = a.querySelector('b');
      if (label && /\.dmg$/.test(label.textContent)) label.textContent = 'Download ' + file;
    }
  } catch { /* offline or mid-deploy: the baked-in versioned link stands */ }
})();
