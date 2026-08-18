/**
 * parsecheck.mjs — refuse to deploy a file the browser cannot parse.
 *
 * Exists because of a specific, repeated, expensive failure: a stray backtick
 * inside a template literal. `tape-app/public/*.js` carry GLSL shaders and SQL-ish
 * blobs as template literals, and prose comments inside them love to quote
 * identifiers in backticks — which terminates the literal and turns the rest of
 * the file into a syntax error. It has shipped to prod at least twice. The cost
 * is total: the module never loads, so the whole call is dead, and the symptom
 * (a blank page) points nowhere near the comment that caused it.
 *
 * `node --check` cannot catch it: these are ES modules, and --check parses as a
 * script, so it rejects the `export` before ever reaching the bug. This parses
 * them as modules, which is what a browser does.
 *
 *   node testbed/parsecheck.mjs [files...]     # defaults to tape-app/public/*.js
 */
import { readFileSync, readdirSync } from 'node:fs';
import vm from 'node:vm';

// SourceTextModule only exists under --experimental-vm-modules, and without it
// this file throws an ImportError before checking a single line. A guard that
// silently cannot run is worse than no guard: `node testbed/parsecheck.mjs`
// exits non-zero either way, so a broken guard and a caught bug look the same
// from a shell, and the habit becomes ignoring it. Found 2026-08-18, with the
// guard dead and the failure it prevents already having shipped twice.
//
// So it re-launches itself with the flag rather than asking the caller to
// remember one.
if (!vm.SourceTextModule) {
  const { spawnSync } = await import('node:child_process');
  const r = spawnSync(process.execPath,
    // decodeURIComponent for the same reason as `root` below — the repo path
    // contains a space and a file: URL percent-encodes it.
    ['--experimental-vm-modules', '--no-warnings',
      decodeURIComponent(new URL(import.meta.url).pathname), ...process.argv.slice(2)],
    { stdio: 'inherit' });
  process.exit(r.status ?? 1);
}
const { SourceTextModule } = vm;

// decodeURIComponent because the repo path contains a space, which a file: URL
// percent-encodes and readdirSync then looks for literally.
const root = decodeURIComponent(new URL('..', import.meta.url).pathname);
const pub = `${root}tape-app/public`;
const files = process.argv.length > 2
  ? process.argv.slice(2)
  : readdirSync(pub).filter((f) => f.endsWith('.js')).map((f) => `${pub}/${f}`);

let bad = 0;
for (const f of files) {
  const src = readFileSync(f, 'utf8');
  try {
    new SourceTextModule(src, { identifier: f });
  } catch (e) {
    // Point at the line, not just the file: "Unexpected identifier" on a 4000-line
    // file is not a useful thing to hand someone at deploy time.
    bad++;
    console.log(`FAIL ${f.replace(root, '')}\n     ${e.message}`);
    const tick = src.split('\n').findIndex((l, i) => i > 0 && (l.match(/`/g) || []).length === 1);
    if (tick >= 0) console.log(`     first line with an unpaired backtick: ${tick + 1}`);
  }
}
console.log(bad ? `\n${bad} file(s) will not load in a browser.` : `${files.length} files parse as modules.`);
process.exit(bad ? 1 : 0);
