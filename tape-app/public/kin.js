// ── kin.tokkah.com, the front door ───────────────────────────────────────────
//
// Hero film controls, waitlist form enhancement, and live release manifest sync.
// Worker CSP: script-src 'self' 'wasm-unsafe-eval' -- no inline JS.
(async () => {
  // ── HERO FILM CONTROLS & POSTER DETECTION ──────────────────────────────────
  const filmIframe = document.getElementById('hero-film');
  const filmCtrlBtn = document.getElementById('film-ctrl-btn');
  const filmCtrlText = document.getElementById('film-ctrl-text');

  const prefersReducedMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const isNarrow = window.innerWidth < 720;

  if (isNarrow || prefersReducedMotion) {
    if (filmIframe) {
      filmIframe.src = '/ad/kin-ad?t=64.5';
    }
    if (filmCtrlText) {
      filmCtrlText.textContent = 'Play film';
    }
  }

  // "Watch with sound" used to reload the frame with ?autoplay=1. A freshly
  // loaded document has no user gesture of its own, so every browser kept its
  // AudioContext suspended and the film played silent -- the reported bug. Now
  // the click drives the film that is already running: the frame is same-origin,
  // so the gesture on this page counts inside it too, and the film creates and
  // resumes its audio in the same task. The reload stays only as the fallback
  // for a frame that has not finished loading.
  if (filmCtrlBtn && filmIframe) {
    filmCtrlBtn.addEventListener('click', () => {
      const film = filmIframe.contentWindow && filmIframe.contentWindow.kinAd;
      if (isNarrow) goBig();
      if (film && typeof film.playWithSound === 'function') {
        film.playWithSound();
      } else {
        filmIframe.src = '/ad/kin-ad?autoplay=1';
      }
      if (filmCtrlText) filmCtrlText.textContent = 'Restart with sound';
    });

    // Leaving full screen on a phone pauses the film rather than letting it
    // play on unseen in a 200 px box.
    document.addEventListener('fullscreenchange', () => {
      if (!document.fullscreenElement) {
        const film = filmIframe.contentWindow && filmIframe.contentWindow.kinAd;
        if (film && typeof film.pause === 'function') film.pause();
        if (filmCtrlText) filmCtrlText.textContent = 'Play film';
      }
    });
  }

  // On a phone the 16:9 film in a portrait page is a postage stamp, so playing
  // it asks for the whole screen and a landscape lock. Both are best effort:
  // iPhone Safari offers neither for a frame, and there the film plays in place.
  function goBig() {
    try {
      const box = filmIframe.parentElement || filmIframe;
      const req = box.requestFullscreen || box.webkitRequestFullscreen;
      if (!req) return;
      Promise.resolve(req.call(box)).then(() => {
        if (screen.orientation && screen.orientation.lock) screen.orientation.lock('landscape').catch(() => {});
      }).catch(() => {});
    } catch (e) { /* stays in place */ }
  }

  // ── WAITLIST ENHANCEMENT ──────────────────────────────────────────────────
  const waitlistForm = document.getElementById('waitlist-form');
  const waitlistMsg = document.getElementById('waitlist-msg');

  function showWaitlistSuccess() {
    if (waitlistForm) waitlistForm.style.display = 'none';
    if (waitlistMsg) {
      waitlistMsg.className = 'waitlist-msg success';
      waitlistMsg.textContent = "You're on the list.";
    }
  }

  function showWaitlistError(text) {
    if (waitlistMsg) {
      waitlistMsg.className = 'waitlist-msg error';
      waitlistMsg.textContent = text || "That address didn't look right.";
    }
  }

  try {
    const params = new URLSearchParams(window.location.search);
    if (params.get('joined') === '1') {
      showWaitlistSuccess();
    } else if (params.get('joined') === '0') {
      showWaitlistError("That address didn't look right.");
    }
  } catch { /* URLSearchParams unavailable or invalid */ }

  if (waitlistForm) {
    waitlistForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      if (waitlistMsg) {
        waitlistMsg.textContent = '';
        waitlistMsg.className = 'waitlist-msg';
      }
      const emailInput = waitlistForm.querySelector('input[name="email"]');
      const platformSelect = waitlistForm.querySelector('select[name="platform"]');
      const sourceInput = waitlistForm.querySelector('input[name="source"]');

      const email = emailInput ? emailInput.value.trim() : '';
      const platform = platformSelect ? platformSelect.value : undefined;
      const source = sourceInput ? sourceInput.value : 'kin-home';

      try {
        const res = await fetch('/api/waitlist', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ email, platform, source }),
        });

        if (res.ok) {
          const data = await res.json();
          if (data && data.ok) {
            showWaitlistSuccess();
            return;
          }
        }
        showWaitlistError("That address didn't look right.");
      } catch {
        showWaitlistError("That address didn't look right.");
      }
    });
  }

  // ── WHICH APP THIS VISITOR CAN ACTUALLY RUN ────────────────────────────────
  //
  // One front door, two apps. A person on a phone offered a disk image has been
  // handed a file their device cannot open, and the commonest thing they will do
  // about it is leave. So the button asks what they are holding first, and the
  // Mac path below is left exactly as it was for everybody else.
  // Both buttons are always on the page. On an Android phone the Android button
  // simply comes first (CSS order on body.on-android); the Mac button stays,
  // because people send this link to each other across devices.
  if (/Android/i.test(navigator.userAgent)) document.body.classList.add('on-android');

  // The Android button reads the same signed manifest the Android app's own
  // updater reads, so the version and size here can never be a release behind.
  try {
    const r = await fetch('/android/manifest.json', { cache: 'no-cache' });
    if (r.ok) {
      const m = await r.json();
      const path = m.url ? new URL(m.url, location.origin).pathname : '';
      if (/^\/android\/dl\/[A-Za-z0-9._-]+\.apk$/.test(path)) {
        for (const a of document.querySelectorAll('a[data-dl-android]')) a.href = path;
      }
      const ver = document.getElementById('ver-android');
      if (ver && m.version) ver.textContent = 'v' + m.version;
      const size = document.getElementById('size-android');
      if (size && m.size > 500e3) size.textContent = Math.round(m.size / 1e6) + ' MB';
    }
  } catch { /* the baked numbers stand */ }

  try {
    const r = await fetch('/macos/manifest.json', { cache: 'no-cache' });
    if (!r.ok) return;
    const m = await r.json();
    if (m.version) document.getElementById('ver').textContent = 'v' + m.version;

    // The button points at the VERSIONED dmg, because there is no
    // content-disposition on /macos/dl/* -- the browser names the saved file after
    // the last path segment, so `Kin.dmg` lands as an anonymous `Kin.dmg` and a
    // second download collides with the first. `Kin-0.46.0.dmg` names itself.
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
