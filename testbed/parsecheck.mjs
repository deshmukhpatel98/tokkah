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
import { SourceTextModule } from 'node:vm';

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
