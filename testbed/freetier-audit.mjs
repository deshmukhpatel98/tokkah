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
import { readFileSync, statSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { gzipSync } from 'node:zlib';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
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
//
// wrangler.jsonc is JSONC, and JSON.parse is not. Three things in it are legal
// JSONC and syntax errors to JSON: `//` line comments, `/* */` blocks, and
// trailing commas. This audit was dead for weeks because the old one-line
// regex stripped only WHOLE-LINE `//` comments and a trailing comma appeared —
// and it died at the parse, before a single check ran and before it printed a
// verdict, so CI showed a stack trace instead of a result.
//
// A regex cannot do this job. One narrow enough to be safe misses a comment
// appended after a value; one broad enough to catch those corrupts any `//`
// that lives INSIDE a string — and this config already holds a path value one
// slash away from that ("node_modules/wrangler/config-schema.json"), with URLs
// a plausible edit away. So: a character scanner that knows where strings are,
// copies them through untouched, and drops a comma only when the next thing
// that is not whitespace-or-comment is a closing brace or bracket.
//
// Line breaks are preserved so a genuine syntax error still reports the real
// line number of wrangler.jsonc.
const stripJsonc = (s) => {
  // The next index holding something that is neither whitespace nor a comment.
  const nextSignificant = (k) => {
    while (k < s.length) {
      if (/\s/.test(s[k])) { k++; continue; }
      if (s[k] === '/' && s[k + 1] === '/') { while (k < s.length && s[k] !== '\n') k++; continue; }
      if (s[k] === '/' && s[k + 1] === '*') { const e = s.indexOf('*/', k + 2); k = e === -1 ? s.length : e + 2; continue; }
      break;
    }
    return k;
  };
  let out = '';
  let i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === '"') {
      // A string literal, copied verbatim. `\"` and `\\` do not end it.
      let j = i + 1;
      while (j < s.length) {
        if (s[j] === '\\') { j += 2; continue; }
        if (s[j] === '"') { j++; break; }
        j++;
      }
      out += s.slice(i, j);
      i = j;
      continue;
    }
    if (c === '/' && s[i + 1] === '/') {
      while (i < s.length && s[i] !== '\n') i++;   // stops ON the newline, which is kept
      continue;
    }
    if (c === '/' && s[i + 1] === '*') {
      const e = s.indexOf('*/', i + 2);
      const end = e === -1 ? s.length : e + 2;
      out += s.slice(i, end).replace(/[^\n]/g, '');   // keep the line breaks only
      i = end;
      continue;
    }
    if (c === ',' && ['}', ']'].includes(s[nextSignificant(i + 1)])) {
      i++;                                            // a trailing comma
      continue;
    }
    out += c;
    i++;
  }
  return out;
};

// VALIDATE THE RULER BEFORE MEASURING WITH IT. A stripper that quietly mangled
// a value would not throw — it would hand the checks below a config that is not
// the one on disk, and every verdict after that is fiction. This fixture holds
// each hazard at once, including the two a regex gets wrong.
{
  const probe = stripJsonc(`{
    "url": "https://example.com//x",       // a // inside a string, and a trailing comment
    "glob": "a/*b*/c",                     /* a block-comment opener inside a string */
    "quoted": "he said \\"hi\\" // not a comment",
    /* a real block comment
       spanning lines */
    "list": [1, 2, 3,],
  }`);
  let parsed;
  try { parsed = JSON.parse(probe); } catch (e) { parsed = { __err: e.message }; }
  const want = { url: 'https://example.com//x', glob: 'a/*b*/c', quoted: 'he said "hi" // not a comment', list: [1, 2, 3] };
  if (JSON.stringify(parsed) !== JSON.stringify(want)) {
    console.log(`  FAIL  the JSONC stripper is broken — it turned a known fixture into ${JSON.stringify(parsed)}`);
    console.log('\nFREE-TIER AUDIT FAILED (1)');
    process.exit(1);
  }
}

const raw = readFileSync(join(APP, 'wrangler.jsonc'), 'utf8');
let cfg;
try {
  cfg = JSON.parse(stripJsonc(raw));
} catch (e) {
  // Loud, and still a verdict. Every check below dereferences cfg, so there is
  // nothing left to run — but CI gets a sentence rather than a stack trace.
  console.log(`  FAIL  tape-app/wrangler.jsonc did not parse as JSONC: ${e.message}`);
  console.log('\nFREE-TIER AUDIT FAILED (1)');
  process.exit(1);
}
ok('wrangler.jsonc parses (comments and trailing commas and all)');

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
// The build lands OUTSIDE the repo. CONTRIBUTING.md asks people to run this
// before opening a pull request, and the old `--outdir .freetier-dry` left an
// untracked directory in tape-app/ that no .gitignore rule covers — a guard
// that dirties the tree it is guarding is a guard people learn to skip. The
// directory is removed afterwards either way.
const outDir = mkdtempSync(join(tmpdir(), 'tokkah-freetier-'));
let dry;
try {
  dry = execFileSync('npx', ['wrangler', 'deploy', '--dry-run', '--outdir', outDir], {
    cwd: APP, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, CLOUDFLARE_API_TOKEN: undefined },
  });
} catch (e) {
  fails.push(`wrangler deploy --dry-run failed: ${(e.stdout || e.message || '').split('\n').slice(-6).join(' ')}`);
}
if (dry) {
  // MEASURE WHAT IS ACTUALLY UPLOADED. This used to gzip every file in the
  // outdir, which meant the 392 KB source map — a build artifact that is not
  // part of the Worker's size budget — and the README wrangler drops in there.
  // That inflated the headline number by about 3.6x (153 KiB reported against
  // 42 KiB real), and a guard whose number is wrong is decoration however
  // green it prints. Modules are what count: JS, and wasm if it ever appears.
  const SKIP = (f) => f.endsWith('.map') || f === 'README.md';
  let total = 0;
  const measured = [];
  for (const f of readdirSync(outDir)) {
    const p = join(outDir, f);
    if (!statSync(p).isFile() || SKIP(f)) continue;
    total += gzipSync(readFileSync(p)).length;
    measured.push(f);
  }
  if (total > FREE.bundleGzipBytes) fails.push(`worker bundle ${(total / 1024).toFixed(1)} KiB gzipped exceeds the ${FREE.bundleGzipBytes / 1024 / 1024} MiB free-plan limit`);
  else ok(`worker bundle ${(total / 1024).toFixed(1)} KiB gzipped over ${measured.join(', ')} (free-plan limit ${FREE.bundleGzipBytes / 1024 / 1024} MiB — ${((100 * total) / FREE.bundleGzipBytes).toFixed(1)}% used)`);

  // CROSS-CHECK AGAINST AN INSTRUMENT THAT IS NOT THIS ONE. wrangler prints its
  // own gzipped figure, and the whole reason the bug above survived is that
  // nothing ever compared the two. A warn rather than a fail: wrangler's output
  // format is not a contract, and a cosmetic change to it must not turn CI red.
  const theirs = dry.match(/gzip:\s*([\d.]+)\s*KiB/);
  if (!theirs) warns.push('could not read wrangler\'s own gzipped size to cross-check this number');
  else {
    const drift = Math.abs(Number(theirs[1]) - total / 1024) / Number(theirs[1]);
    if (drift > 0.1) warns.push(`this audit measured ${(total / 1024).toFixed(1)} KiB gzipped but wrangler reported ${theirs[1]} KiB — one of the two is measuring the wrong files`);
    else ok(`cross-checked against wrangler's own figure (${theirs[1]} KiB gzipped)`);
  }
}
rmSync(outDir, { recursive: true, force: true });

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
