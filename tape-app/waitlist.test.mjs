/**
 * /api/waitlist: zero-leakage waitlist collection & operator read tests.
 *
 * Runs against the actual worker bundle using Miniflare 5 and real SQLite DO
 * storage, following the pattern in routing.test.mjs.
 */
import { build } from 'esbuild';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { unlinkSync, readFileSync } from 'node:fs';

const here = dirname(fileURLToPath(import.meta.url));
const bundle = join(tmpdir(), `worker-waitlist-${process.pid}.mjs`);
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
  console.log(`  ${ok ? ' ok ' : 'FAIL'}  ${what.padEnd(54)} ${String(got).padEnd(24)} want ${want}`);
}
function ok(cond, what) {
  if (!cond) failures++;
  console.log(`  ${cond ? ' ok ' : 'FAIL'}  ${what}`);
}

const { Miniflare } = await import('miniflare');
const WORKER = 'tokkah-waitlist-test';
const TEST_AGENT_KEY = 'test-operator-agent-key-secret-99';

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
        AGENT_KEY: { type: 'text', value: TEST_AGENT_KEY },
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

try {
  sec('(1) valid JSON signup');
  const r1 = await mf.dispatchFetch('https://kin.tokkah.com/api/waitlist', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'cf-connecting-ip': '192.0.2.1',
      'cf-ipcountry': 'US',
      'user-agent': 'TokkahWaitlistTest/1.0',
    },
    body: JSON.stringify({
      email: '  Alice@Example.COM  ',
      platform: 'mac',
      source: 'campaign_alpha',
    }),
  });
  eq(r1.status, 200, 'POST /api/waitlist JSON status');
  eq(r1.headers.get('cache-control'), 'no-store', 'Cache-Control header');
  const b1 = await r1.json();
  eq(b1?.ok, true, 'body.ok === true');

  sec('(2) repeat signup returns identical 200 without leaking existence');
  const r2 = await mf.dispatchFetch('https://kin.tokkah.com/api/waitlist', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'cf-connecting-ip': '192.0.2.2',
    },
    body: JSON.stringify({
      email: 'alice@example.com',
      platform: 'mac',
    }),
  });
  eq(r2.status, 200, 'repeat signup status 200');
  eq(r2.headers.get('cache-control'), 'no-store', 'repeat signup no-store');
  const b2 = await r2.json();
  eq(b2?.ok, true, 'repeat signup body.ok === true');

  sec('(3) invalid email returns 400 error:"email"');
  for (const bad of ['not-an-email', 'foo@', '@bar.com', 'foo bar@baz.com', '']) {
    const rBad = await mf.dispatchFetch('https://kin.tokkah.com/api/waitlist', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'cf-connecting-ip': '192.0.2.3',
      },
      body: JSON.stringify({ email: bad }),
    });
    eq(rBad.status, 400, `invalid email (${bad || '<empty>'}) status`);
    const bBad = await rBad.json();
    eq(bBad?.ok, false, `invalid email (${bad || '<empty>'}) ok:false`);
    eq(bBad?.error, 'email', `invalid email (${bad || '<empty>'}) error:"email"`);
  }

  sec('(4) form post 303 targets (/ ?joined=1 and /?joined=0)');
  const rFormOk = await mf.dispatchFetch('https://kin.tokkah.com/api/waitlist', {
    method: 'POST',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      'cf-connecting-ip': '192.0.2.4',
    },
    body: 'email=bob%40example.com&platform=iphone&source=web_footer',
    redirect: 'manual',
  });
  eq(rFormOk.status, 303, 'valid form post status 303');
  eq(rFormOk.headers.get('location'), '/?joined=1', 'valid form post location /?joined=1');
  eq(rFormOk.headers.get('cache-control'), 'no-store', 'valid form post no-store');

  const rFormBad = await mf.dispatchFetch('https://kin.tokkah.com/api/waitlist', {
    method: 'POST',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      'cf-connecting-ip': '192.0.2.5',
    },
    body: 'email=bad_email_address',
    redirect: 'manual',
  });
  eq(rFormBad.status, 303, 'invalid form email status 303');
  eq(rFormBad.headers.get('location'), '/?joined=0', 'invalid form email location /?joined=0');

  sec('(5) rate limit: generous 30/hour, blocks at 31st request');
  const rateLimitIp = '198.51.100.77';
  let first30AllOk = true;
  for (let i = 1; i <= 30; i++) {
    const res = await mf.dispatchFetch('https://kin.tokkah.com/api/waitlist', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'cf-connecting-ip': rateLimitIp,
      },
      body: JSON.stringify({ email: `user${i}@ratelimit.tokkah.com`, platform: 'android' }),
    });
    if (res.status !== 200) first30AllOk = false;
  }
  eq(first30AllOk, true, 'first 30 requests from IP all succeed with 200');

  const r31 = await mf.dispatchFetch('https://kin.tokkah.com/api/waitlist', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'cf-connecting-ip': rateLimitIp,
    },
    body: JSON.stringify({ email: 'user31@ratelimit.tokkah.com' }),
  });
  eq(r31.status, 429, '31st request returns 429');
  const b31 = await r31.json();
  eq(b31?.ok, false, '429 response ok:false');
  eq(b31?.retry, true, '429 response retry:true');

  const r32Form = await mf.dispatchFetch('https://kin.tokkah.com/api/waitlist', {
    method: 'POST',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      'cf-connecting-ip': rateLimitIp,
    },
    body: 'email=user32%40ratelimit.tokkah.com',
    redirect: 'manual',
  });
  eq(r32Form.status, 303, 'rate limited form request returns 303');
  eq(r32Form.headers.get('location'), '/?joined=0', 'rate limited form redirects to /?joined=0');

  // Verify another IP is NOT blocked
  const rOtherIp = await mf.dispatchFetch('https://kin.tokkah.com/api/waitlist', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'cf-connecting-ip': '198.51.100.88',
    },
    body: JSON.stringify({ email: 'unaffected@example.com' }),
  });
  eq(rOtherIp.status, 200, 'different IP is unaffected by rate limit');

  sec('(6) operator read 401 without key and 200 with key');
  const rUnauth = await mf.dispatchFetch('https://kin.tokkah.com/api/waitlist');
  eq(rUnauth.status, 401, 'unauthenticated read returns 401');
  const unauthText = await rUnauth.text();
  eq(unauthText, '', 'unauthenticated read has no body detail');

  const rWrongKey = await mf.dispatchFetch('https://kin.tokkah.com/api/waitlist?key=wrong-secret-key');
  eq(rWrongKey.status, 401, 'wrong key returns 401');

  // Authenticated via query param ?key=
  const rAuthQuery = await mf.dispatchFetch(`https://kin.tokkah.com/api/waitlist?key=${TEST_AGENT_KEY}`);
  eq(rAuthQuery.status, 200, 'operator read with ?key= returns 200');
  eq(rAuthQuery.headers.get('cache-control'), 'no-store', 'operator read no-store');
  const data = await rAuthQuery.json();
  ok(typeof data.count === 'number' && data.count >= 33, `count is a number (${data.count})`);
  ok(typeof data.byPlatform === 'object' && data.byPlatform !== null, 'byPlatform is an object');
  ok((data.byPlatform.mac ?? 0) >= 1, 'byPlatform has mac count >= 1');
  ok((data.byPlatform.iphone ?? 0) >= 1, 'byPlatform has iphone count >= 1');
  ok((data.byPlatform.android ?? 0) >= 30, 'byPlatform has android count >= 30');
  ok(Array.isArray(data.recent), 'recent is an array');
  ok(data.recent.length <= 50, `recent length is <= 50 (got ${data.recent.length})`);
  const firstRecent = data.recent[0];
  ok(
    typeof firstRecent.email === 'string' &&
    'platform' in firstRecent &&
    'source' in firstRecent &&
    'country' in firstRecent &&
    typeof firstRecent.first_seen === 'number',
    'recent items match {email, platform, source, country, first_seen}',
  );

  // Authenticated via Authorization: Bearer <AGENT_KEY>
  const rAuthHeader = await mf.dispatchFetch('https://kin.tokkah.com/api/waitlist', {
    headers: { authorization: `Bearer ${TEST_AGENT_KEY}` },
  });
  eq(rAuthHeader.status, 200, 'operator read with Bearer header returns 200');

  sec('(7) CSV export format');
  const rCsv = await mf.dispatchFetch(`https://kin.tokkah.com/api/waitlist?format=csv&key=${TEST_AGENT_KEY}`);
  eq(rCsv.status, 200, 'CSV export status 200');
  ok((rCsv.headers.get('content-type') ?? '').includes('text/csv'), 'Content-Type is text/csv');
  eq(rCsv.headers.get('content-disposition'), 'attachment; filename="waitlist.csv"', 'Content-Disposition header');
  eq(rCsv.headers.get('cache-control'), 'no-store', 'CSV export no-store');
  const csvText = await rCsv.text();
  const csvLines = csvText.trim().split('\n');
  eq(csvLines[0], 'email,platform,source,ua,country,first_seen,last_seen,hits', 'CSV header matches columns');
  ok(csvLines.length >= 34, `CSV exports all rows (got ${csvLines.length - 1} data rows)`);
  ok(csvLines.some((l) => l.startsWith('alice@example.com,mac,campaign_alpha')), 'CSV contains Alice row');
  ok(csvLines.some((l) => l.startsWith('bob@example.com,iphone,web_footer')), 'CSV contains Bob row');

  sec('(8) hostnames: works on both kin.tokkah.com and room.tokkah.com');
  const rKin = await mf.dispatchFetch(`https://kin.tokkah.com/api/waitlist?key=${TEST_AGENT_KEY}`);
  const rRoom = await mf.dispatchFetch(`https://room.tokkah.com/api/waitlist?key=${TEST_AGENT_KEY}`);
  eq(rKin.status, 200, 'kin.tokkah.com/api/waitlist works');
  eq(rRoom.status, 200, 'room.tokkah.com/api/waitlist works');
} finally {
  await mf.dispose();
}

console.log(failures ? `\n${failures} WAITLIST CASE(S) WRONG` : '\nAll waitlist cases passed.');
process.exit(failures ? 1 : 0);
