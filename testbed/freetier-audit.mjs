#!/usr/bin/env node
/**
 * Free-plan deployability audit — static, deterministic, credential-free.
 *
 * The promise in the README is "deploys on a free Cloudflare account". That
 * promise is easy to break by accident: adding one paid-only binding, or one
 * Durable Object with the key-value backend, silently makes the project
 * undeployable for everyone without a paid plan — and nothing else in CI
 * would notice.
 *
 * This rig parses the committed wrangler config and the built bundle and
 * fails loudly on anything a Workers Free account cannot run.
 *
 *   node testbed/freetier-audit.mjs
 *
 * Runs in CI on every pull request.
 */
import { readFileSync, statSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { gzipSync } from 'node:zlib';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const APP = join(ROOT, 'tape-app');

// Workers Free ceilings, from Cloudflare's platform limits + DO pricing docs.
const FREE = {
  bundleGzipBytes: 3 * 1024 * 1024,   // 3 MiB gzipped worker bundle (paid: 10 MiB)
  assetFileBytes: 25 * 1024 * 1024,   // 25 MiB per static asset
  assetCount: 20_000,
};
// Bindings a Workers Free account cannot create at all.
const PAID_ONLY_BINDINGS = [
  'queues', 'hyperdrive', 'mtls_certificates', 'vectorize',
  'dispatch_namespaces', 'logfwdr', 'pipelines',
];
// Config keys that imply a paid plan.
const PAID_ONLY_KEYS = ['placement', 'tail_consumers', 'logpush'];

const fails = [];
const warns = [];
const notes = [];
const ok = (m) => notes.push(m);

// ── config ────────────────────────────────────────────────────────────────
const raw = readFileSync(join(APP, 'wrangler.jsonc'), 'utf8');
// JSONC → JSON: strip // line comments (none of the values contain "//" today,
// and the audit fails loudly below if parsing ever breaks).
const cfg = JSON.parse(raw.replace(/^\s*\/\/.*$/gm, ''));

// 1. Durable Objects must use the SQLite backend. Cloudflare: "Only Durable
//    Objects with SQLite storage backend are available" on Workers Free.
const declared = (cfg.durable_objects?.bindings ?? []).map((b) => b.class_name);
const sqliteClasses = new Set(
  (cfg.migrations ?? []).flatMap((m) => m.new_sqlite_classes ?? []),
);
const kvClasses = (cfg.migrations ?? []).flatMap((m) => m.new_classes ?? []);
if (kvClasses.length) {
  fails.push(`Durable Objects declared with the key-value backend (paid-only): ${kvClasses.join(', ')} — use new_sqlite_classes`);
}
for (const c of declared) {
  if (!sqliteClasses.has(c)) fails.push(`Durable Object "${c}" has no new_sqlite_classes migration — it would be key-value backed (paid-only)`);
}
if (declared.length && !fails.length) ok(`${declared.length} Durable Objects, all SQLite-backed: ${declared.join(', ')}`);

// 2. No paid-only bindings or config keys.
for (const k of PAID_ONLY_BINDINGS) if (cfg[k]) fails.push(`paid-only binding present: ${k}`);
for (const k of PAID_ONLY_KEYS) if (cfg[k]) fails.push(`paid-only config key present: ${k}`);

// 3. No custom domain required to deploy — a fork must land on workers.dev.
if (cfg.routes || cfg.route) fails.push('committed config pins routes/custom domain — a fork cannot deploy it as-is');
if (cfg.workers_dev === false) fails.push('workers_dev is false — a fork would deploy with no reachable URL');
else ok('deploys to <name>.<subdomain>.workers.dev with no domain needed');

// 4. No secrets required to boot. (Optional ones are fine; required ones are not.)
const workerSrc = readFileSync(join(APP, cfg.main), 'utf8');
for (const [envVar, why] of [['TURN_KEY_ID', 'TURN'], ['TURN_KEY_API_TOKEN', 'TURN'], ['LOG_ADMIN_TOKEN', 'admin log access']]) {
  // Guarded use (`if (!env.X)` / `env.X ?` / `env.X &&` / `!== env.X`) is fine;
  // an unguarded dereference at boot would make the secret mandatory.
  const used = workerSrc.includes(`env.${envVar}`);
  const guarded = new RegExp(`!\\s*env\\.${envVar}|env\\.${envVar}\\s*(&&|\\?|!==|===)|\\bif\\s*\\([^)]*env\\.${envVar}`).test(workerSrc);
  if (used && !guarded) warns.push(`env.${envVar} (${why}) may be dereferenced unguarded — confirm a fork boots without it`);
}
ok('no secrets required to deploy (TURN and admin token are optional)');

// ── built bundle ──────────────────────────────────────────────────────────
let dry;
try {
  dry = execFileSync('npx', ['wrangler', 'deploy', '--dry-run', '--outdir', '.freetier-dry'], {
    cwd: APP, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, CLOUDFLARE_API_TOKEN: undefined },
  });
} catch (e) {
  fails.push(`wrangler deploy --dry-run failed: ${(e.stdout || e.message || '').split('\n').slice(-6).join(' ')}`);
}
if (dry) {
  const outDir = join(APP, '.freetier-dry');
  let total = 0;
  for (const f of readdirSync(outDir)) {
    const p = join(outDir, f);
    if (statSync(p).isFile()) total += gzipSync(readFileSync(p)).length;
  }
  if (total > FREE.bundleGzipBytes) fails.push(`worker bundle ${(total / 1024).toFixed(1)} KiB gzipped exceeds the ${FREE.bundleGzipBytes / 1024 / 1024} MiB free-plan limit`);
  else ok(`worker bundle ${(total / 1024).toFixed(1)} KiB gzipped (free-plan limit ${FREE.bundleGzipBytes / 1024 / 1024} MiB — ${((100 * total) / FREE.bundleGzipBytes).toFixed(1)}% used)`);
}

// ── static assets ─────────────────────────────────────────────────────────
const assetsDir = join(APP, cfg.assets.directory);
let count = 0, biggest = { n: '', b: 0 };
const walk = (d) => {
  for (const e of readdirSync(d, { withFileTypes: true })) {
    const p = join(d, e.name);
    if (e.isDirectory()) { walk(p); continue; }
    if (e.isSymbolicLink?.()) continue;
    count++;
    const b = statSync(p).size;
    if (b > biggest.b) biggest = { n: p.slice(assetsDir.length + 1), b };
  }
};
walk(assetsDir);
if (count > FREE.assetCount) fails.push(`${count} static assets exceeds the ${FREE.assetCount} free-plan limit`);
if (biggest.b > FREE.assetFileBytes) fails.push(`asset ${biggest.n} is ${(biggest.b / 1024 / 1024).toFixed(1)} MiB, over the ${FREE.assetFileBytes / 1024 / 1024} MiB per-file limit`);
if (!fails.some((f) => f.includes('asset'))) ok(`${count} static assets, largest ${biggest.n} at ${(biggest.b / 1024).toFixed(0)} KiB`);

// ── report ────────────────────────────────────────────────────────────────
for (const n of notes) console.log(`  ok    ${n}`);
for (const w of warns) console.log(`  warn  ${w}`);
for (const f of fails) console.log(`  FAIL  ${f}`);
console.log(fails.length
  ? `\nFREE-TIER AUDIT FAILED (${fails.length})`
  : `\nFREE-TIER AUDIT PASSES — deployable on a Workers Free account`);
process.exit(fails.length ? 1 : 0);
