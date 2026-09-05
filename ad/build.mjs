import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const htmlPath = path.join(__dirname, 'kin-ad.html');
const jsPath = path.join(__dirname, 'kin-ad.js');
const outPath = path.join(__dirname, 'kin-ad.single.html');

console.log('Building kin-ad.single.html...');

const html = fs.readFileSync(htmlPath, 'utf8');
const js = fs.readFileSync(jsPath, 'utf8');

// Replace <script src="kin-ad.js"></script> with inlined script
const scriptTag = '<script src="kin-ad.js"></script>';
if (!html.includes(scriptTag)) {
  console.error('Error: could not find <script src="kin-ad.js"></script> in kin-ad.html');
  process.exit(1);
}

const singleHtml = html.replace(
  scriptTag,
  `<script>\n${js}\n</script>`
);

// Check for external URLs
// Check patterns: http://, https://, //, url(http...), url('http...'), etc.
const externalUrlRegex = /(?:https?:|\/\/)[^\s"'`<>]+/gi;
const matches = singleHtml.match(externalUrlRegex) || [];

// Filter out xmlns: "http://www.w3.org/2000/svg"
const realExternal = matches.filter(url => !url.includes('www.w3.org/2000/svg'));

if (realExternal.length > 0) {
  console.error('FAILED: Found external URLs in kin-ad.single.html:');
  realExternal.forEach(url => console.error('  ' + url));
  process.exit(1);
}

fs.writeFileSync(outPath, singleHtml, 'utf8');
const stats = fs.statSync(outPath);
console.log(`Successfully built ${outPath} (${(stats.size / 1024).toFixed(1)} KB)`);
console.log('Zero external URLs confirmed.');
