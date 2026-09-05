# The browser era, and what happened to it

Part of [Kin](../README.md). Moved from the main README.

This repository began on 2026-08-04 as a browser product: a WebRTC call with a
lossless-PCM audio lane over datachannels, embeddable in any page with one
`<script>` tag. It worked, and it produced real results — sliding-window FEC
repairing a lost packet at a p50 of 8 ms where a block code needed 80 ms+,
VMAF 99.7 video, and a **127 ms mouth-to-ear on a genuine cross-planet call**
between Delhi and the Netherlands, which is the one long-distance media
measurement this project has ever taken on real machines in real places
([../LATENCY-150.md](../LATENCY-150.md)). Those measurements are all still in
[../MEASURED.md](../MEASURED.md), failures included.

The native macOS work starts on 2026-08-23; the app was renamed **Kin** at
0.56.0 on 2026-08-25. None of the browser-era numbers carry over — different
transport, different codec, different measurements — which is why the table
above shares none of them.

**An invite link is no longer a browser call.** Following a link that somebody
sent you now opens Kin, or offers the download. That was deliberate, and it is
what "open it in two tabs, that's a call" no longer describes.

**The embed still works — but it was broken, silently, and this audit is what
found it.** Worth writing down because of the shape of the failure rather than
the size of the fix:

- `embed.js` builds an iframe pointing at the room. The invite funnel above
  could not tell that iframe apart from a person following a link, so it sent
  the frame to the download page. The page did not error. It rendered a
  plausible "Join on Kin" panel where a call should have been, and returned
  HTTP 200 doing it. Nothing anywhere said anything was wrong.
- The fix is one parameter: `web=1`, the escape hatch `tape-app/src/worker.ts`
  already documented and already served. It belongs on the frame and not on the
  shareable link — a person sent a link may genuinely want the app; a page that
  embedded a call has already decided.
- Verified, in this order: the real `build()` run under Node emits
  `…/?r=standup&web=1`; that URL returns `<title>Kin</title>` on production
  where the one without it returns `<title>Join on Kin</title>`; and a real
  browser loading it renders the call surface — "Join call", camera state and
  all — rather than a download page.

So the one-line integration is true again — **once the Worker is redeployed.**
The fix is a static asset, so `https://room.tokkah.com/embed.js` still serves the
broken build until then (`curl -s …/embed.js | grep -c web=1` → `0`):

```html
<script src="https://room.tokkah.com/embed.js" data-room="standup"></script>
```

with the honest caveat that it embeds the **browser** client, which is not where
the work goes.

The browser client source is still in `tape-app/public/` and is still AGPL, so
nothing is lost if you want it — but **it is not where the work goes**, and it
is not maintained. Every commit since the pivot has been in `mac/`.
