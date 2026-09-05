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

  if (filmCtrlBtn && filmIframe) {
    filmCtrlBtn.addEventListener('click', () => {
      filmIframe.src = '/ad/kin-ad?autoplay=1';
      if (filmCtrlText) {
        filmCtrlText.textContent = 'Restart with sound';
      }
    });
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
