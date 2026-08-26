/**
 * WHICH PAGE DOES A URL OPEN? (`fetch` in src/worker.ts)
 *
 * Kin, the Mac app, is the only way into a call. So every URL this origin
 * serves resolves to one of exactly three things, and the router decides which:
 *
 *   the landing page   /kin    "nobody invited me, I came to look"
 *   the funnel         /join   "somebody sent me a link" -- open the app, or download it
 *   the call shell     /       the browser-to-browser measurement rigs, and nothing else
 *
 * This file exists because those decisions have been silently wrong twice, and
 * neither showed up as an error anywhere:
 *
 *   - `far-away-lab` is a 3-4-3 code. The permanent cross-planet lab room
 *     matches the minted-invite pattern EXACTLY, so the funnel swallowed it and
 *     the human side of the rig became a download page. Five rig call sites all
 *     build `${BASE}/${ROOM}?hb=1`, so all five broke at once, and a rig that
 *     shows the wrong page still reports itself healthy.
 *
 *   - The bare root was scoped to one hostname, so typing the older one opened
 *     the retired browser call shell -- a call UI that can no longer place a
 *     call, presented as the front door.
 *
 * The stub below is the whole trick: ASSETS answers with the path it was ASKED
 * for. That is precisely the router's output, and it needs no real assets to
 * observe -- so this tests the decision, not the page.
 *
 * Every rule is asserted as a PAIR that must be ranked differently. A router
 * that sent everything to /join would pass any one-sided check here.
 */
import { build } from 'esbuild';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { unlinkSync, readFileSync } from 'node:fs';

const here = dirname(fileURLToPath(import.meta.url));
const bundle = join(tmpdir(), `worker-routing-${process.pid}.mjs`);
await build({
  entryPoints: [join(here, 'src/worker.ts')],
  bundle: true, format: 'esm', platform: 'neutral', outfile: bundle,
  logLevel: 'silent',
});
process.on('exit', () => { try { unlinkSync(bundle); } catch {} });

let failures = 0;
const sec = (s) => console.log(`\n──── ${s}`);
function eq(got, want, what) {
  const ok = got === want;
  if (!ok) failures++;
  console.log(`  ${ok ? ' ok ' : 'FAIL'}  ${what.padEnd(52)} ${String(got).padEnd(22)} want ${want}`);
}

const { Miniflare } = await import('miniflare');
// Miniflare 5 (hard-pinned by wrangler as a direct dependency) replaced the flat
// single-worker options with `workers: [{ config }]`: the script moved into
// `config.manifest`, every binding into `config.env`, and how a Durable Object
// stores into `config.exports`. See the long note over the same construction in
// contacts.test.mjs (k) for why each piece is shaped this way. Note
// `compatibilityDate` is camelCase here, unlike wrangler.jsonc.
const WORKER = 'tokkah-routing-test';
const mf = new Miniflare({
  workers: [{
    config: {
      name: WORKER,
      type: 'worker',
      compatibilityDate: '2026-05-01',
      manifest: {
        mainModule: 'worker.mjs',
        modules: { 'worker.mjs': { type: 'esm', contents: readFileSync(bundle, 'utf8') } },
      },
      env: {
        ROOM: { type: 'durable-object', workerName: WORKER, exportName: 'Room' },
        HEALTH: { type: 'durable-object', workerName: WORKER, exportName: 'Health' },
        MACREL: { type: 'r2', name: 'MACREL' },
        // ASSETS reports the path the router handed it. `x-served` survives the
        // header re-wrap the worker does on the way out; the body would too, but a
        // header cannot be mistaken for page content by a later reader of this file.
        // (A `fetcher` binding is what `serviceBindings` became.)
        ASSETS: {
          type: 'fetcher',
          handler: (req) => new Response('stub', {
            headers: { 'content-type': 'text/html;charset=utf-8', 'x-served': new URL(req.url).pathname },
          }),
        },
      },
      exports: {
        Room: { type: 'durable-object', storage: 'sqlite' },
        Health: { type: 'durable-object', storage: 'sqlite' },
      },
    },
  }],
});

/** The path ASSETS was asked for, i.e. the page this URL opens. */
async function served(url) {
  const r = await mf.dispatchFetch(url, { redirect: 'manual' });
  if (r.status >= 300 && r.status < 400) return `${r.status} -> ${r.headers.get('location')}`;
  return r.headers.get('x-served') ?? `${r.status} (no asset)`;
}

try {
  sec('(a) the bare root is the landing page on BOTH hostnames');
  eq(await served('https://kin.tokkah.com/'),  '/kin', 'kin.tokkah.com/');
  eq(await served('https://room.tokkah.com/'), '/kin', 'room.tokkah.com/  (was the call shell)');

  sec('(b) an invite opens the funnel, in both minted shapes, on both hosts');
  eq(await served('https://kin.tokkah.com/abc-defg-hij'),  '/join', 'kin.tokkah.com/<3-4-3>');
  eq(await served('https://room.tokkah.com/abc-defg-hij'), '/join', 'room.tokkah.com/<3-4-3>');
  eq(await served('https://room.tokkah.com/?r=standup'),   '/join', 'room.tokkah.com/?r=<name>');
  eq(await served('https://kin.tokkah.com/?r=standup'),    '/join', 'kin.tokkah.com/?r=<name>');

  sec('(c) THE LAB. far-away-lab is a 3-4-3 code, and the rigs must still call');
  // The five rig call sites, verbatim in shape: `${BASE}/${ROOM}?hb=1`.
  eq(await served('https://room.tokkah.com/far-away-lab?hb=1'), '/',
     'the rig URL every testbed script builds');
  eq(await served('https://room.tokkah.com/far-away-lab?hb=1&ice=relay'), '/',
     'and with EXTRA_QS after it');
  eq(await served('https://room.tokkah.com/far-away-lab?web=1'), '/',
     'the documented escape hatch, which the lab page now links');
  // The pair that makes the rule mean something: the SAME room without a rig
  // flag is an invite, because that is a link somebody was sent.
  eq(await served('https://room.tokkah.com/far-away-lab'), '/join',
     'the same room with no rig flag is still an invite');

  sec('(d) ?web=1 and ?hb=1 reach the shell from the root as well');
  eq(await served('https://room.tokkah.com/?web=1'), '/', 'root ?web=1');
  eq(await served('https://room.tokkah.com/?hb=1'),  '/', 'root ?hb=1');
  // And ?web=1 must not resurrect a browser call from an INVITE it was not
  // given -- the flag is an opt-in for a rig, not a bypass anyone can be sent.
  eq(await served('https://room.tokkah.com/?r=standup&web=1'), '/', 'an invite with ?web=1 is the rig opt-in');

  sec('(e) real assets are never shadowed by a room-shaped path');
  // /app.js is 9 chars and not 3-4-3, but the guard is worth pinning: a router
  // that widened the pattern would take the site apart quietly.
  eq(await served('https://room.tokkah.com/app.js'),   '/app.js',   'an asset, not a room');
  eq(await served('https://room.tokkah.com/embed.js'), '/embed.js', 'an asset, not a room');
  eq(await served('https://room.tokkah.com/abc-def-hij'), '/abc-def-hij', '3-3-3 is not the minted shape');
  eq(await served('https://room.tokkah.com/abcd-defg-hij'), '/abcd-defg-hij', '4-4-3 is not either');

  sec('(f) /mac keeps its 302, so the first landing-page URL still works');
  eq(await served('https://room.tokkah.com/mac'), '302 -> https://kin.tokkah.com/', '/mac');
  eq(await served('https://room.tokkah.com/mac.html'), '302 -> https://kin.tokkah.com/', '/mac.html');
} finally {
  await mf.dispose();
}

console.log(failures ? `\n${failures} ROUTING CASE(S) WRONG` : '\nAll routing cases passed.');
process.exit(failures ? 1 : 0);
