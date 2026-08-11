/**
 * Tokkah embed — one line to put a call in any page.
 *
 *   <script src="https://room.tokkah.com/embed.js" data-room="standup"></script>
 *
 * That's the whole integration: the script replaces itself with an <iframe>
 * running the call, camera/mic permissions delegated. Attributes (all
 * optional):
 *   data-room     room id. Omit it and a cryptographically random room is
 *                 minted — share the iframe's URL (or call Tokkah.link())
 *                 to invite the other side. Room ids are capability URLs:
 *                 anyone with the id can join, so treat them like a meeting
 *                 link, not a password-protected door (see SECURITY.md).
 *   data-width    CSS width  (default 100%)
 *   data-height   CSS height (default 560px)
 *   data-base     self-hosted origin (default: the origin this script
 *                 loaded from — so a fork's embed.js points at the fork)
 *
 * Programmatic form, same one line spirit:
 *
 *   const call = Tokkah.join({ room: 'standup', container: el });
 *   call.url      // shareable invite link
 *   call.leave()  // removes the iframe
 *
 * No SDK, no build step, no dependencies, no account. The iframe IS the app.
 */
(() => {
  'use strict';

  const OWN = document.currentScript;
  const DEFAULT_BASE = (() => {
    try { return new URL(OWN?.src || location.href).origin; }
    catch { return location.origin; }
  })();

  const randomRoom = () => {
    // Meet-shaped xxx-xxxx-xxx, same mint as the app's own — so embed-created
    // rooms get the short path-form link too.
    const b = new Uint8Array(10);
    crypto.getRandomValues(b);
    const c = Array.from(b, (x) => String.fromCharCode(97 + (x % 26))).join('');
    return `${c.slice(0, 3)}-${c.slice(3, 7)}-${c.slice(7)}`;
  };

  const build = (opts = {}) => {
    const base = (opts.base || DEFAULT_BASE).replace(/\/+$/, '');
    const room = opts.room || randomRoom();
    let url = /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/.test(room)
      ? `${base}/${room}`
      : `${base}/?r=${encodeURIComponent(room)}`;
    // data-translate="es" (or any primary language subtag): the embedded call
    // opens with the live interpreter listening in that language — the whole
    // "add an interpreter to any website" integration is this one attribute.
    // The app's ?xlate= hook does the rest; the room's daily budget is
    // enforced server-side (worker.ts xlateMeter), so a hostile page cannot
    // spend more than the room's cap.
    if (opts.translate) {
      url += (url.includes('?') ? '&' : '?') + 'xlate=' + encodeURIComponent(String(opts.translate).slice(0, 8));
    }
    const f = document.createElement('iframe');
    f.src = url;
    // The call needs the camera and mic INSIDE the frame; fullscreen and PiP
    // are quality-of-life. `display-capture` is deliberately absent.
    f.allow = 'camera; microphone; autoplay; fullscreen; picture-in-picture';
    f.style.cssText =
      `width:${opts.width || '100%'};height:${opts.height || '560px'};` +
      'border:0;border-radius:12px;background:#000;display:block;max-width:100%;';
    f.title = 'Tokkah call';
    return { frame: f, url, room };
  };

  const api = {
    join(opts = {}) {
      const { frame, url, room } = build(opts);
      (opts.container || document.body).appendChild(frame);
      return { frame, url, room, leave: () => frame.remove() };
    },
    link(opts = {}) { return build(opts).url; },
  };

  // Script-tag form: replace the <script> with the iframe, in place.
  if (OWN && OWN.dataset && !OWN.dataset.manual) {
    const { frame } = build({
      room: OWN.dataset.room,
      width: OWN.dataset.width,
      height: OWN.dataset.height,
      base: OWN.dataset.base,
      translate: OWN.dataset.translate,
    });
    OWN.parentNode.insertBefore(frame, OWN);
  }

  window.Tokkah = window.Tokkah || api;
})();
