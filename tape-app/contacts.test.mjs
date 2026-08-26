/**
 * Tests for the "tap a name to call" doorbell, its SILENT MODE, and the TURN
 * port ordering (`kin*` and `turnOrderUdp` in src/worker.ts).
 *
 * The doorbell is a mailbox a stranger is ALLOWED to write to. That makes its
 * dangerous bugs the quiet ones: a ring that is accepted and never delivered, a
 * ring delivered long after the caller gave up, a credential check that passes,
 * or a rate limit that locks the rightful owner out of their own inbox. None of
 * those show up as an error anywhere.
 *
 * So the assertions below are weighted towards the pairs of inputs a rule MUST
 * rank differently, never towards a single happy path:
 *
 *   - (a) skew 61 s is refused AND skew 59 s is accepted. A gate that refuses
 *     everything passes a one-sided replay test and silently kills the feature.
 *   - (b) 2 and 32 characters are ACCEPTED while 1 and 33 are refused. Without
 *     both ends of both bounds, "the handle regex works" is indistinguishable
 *     from a regex that refuses everything.
 *   - (b3) KIN_ROUTE_RE and KIN_HANDLE_RE are compared decision-for-decision
 *     over a corpus. A one-character disagreement between them is a 404 nobody
 *     can explain, because the request never reaches the code that would say why.
 *   - (e) the lease is measured from min(receipt, client stamp), so the 60 s skew
 *     window and the 60 s lease cannot stack into 120 s of tolerated staleness.
 *     Both halves are asserted: a ring stamped 59 s ago is ACCEPTED and then
 *     NOT DELIVERED two seconds later.
 *   - (c) a wrong credential is refused with the same 401 as an unregistered
 *     handle, so the endpoint is not an oracle for which handles exist.
 *   - (g) THE SQUAT TEST. Handles are now people's names, so they are guessable,
 *     so the ONLY thing standing between a person and losing their own name is
 *     the proof-of-possession signature. (g3) proves a second device with a
 *     valid signature of its own cannot take a claimed handle, and (g2) proves
 *     the original device can still come back. Both directions, or the rule is
 *     half tested.
 *   - (g4) the skew gate is proved to run BEFORE the signature check, twice
 *     over: a genuinely VALID signature with bad skew still fails, and a
 *     counting verifier records zero curve operations. Order-of-checks is not
 *     observable from a status code alone.
 *   - (h) a failed poll is charged to its own window, proving a stranger who
 *     knows a handle cannot 429 the owner off their own mailbox. Every rate
 *     limit also has to REOPEN — a window that never reopens passes a
 *     "the limit fires" test and is a permanent ban.
 *   - (i) TURN: 3478 is chosen when Cloudflare lists it LAST (the shipped bug),
 *     when it lists it FIRST (which a reversed sort would fail), and 443 is
 *     chosen when 3478 is ABSENT. Without that third case "3478 was chosen" is
 *     indistinguishable from a hardcode, and this project has burned days on
 *     rulers that could not fail. (i0) reimplements the OLD loop and asserts it
 *     really did pick 53 — without it, "the new one works" proves nothing about
 *     what it fixed.
 *   - (l) SILENT MODE, and its primary invariant is not the obvious one.
 *     "No one can call you" is easy to implement and easy to test. What breaks by
 *     accident is that a caller must not be able to TELL silence from absence, and
 *     the natural implementation ("if silent, return ok early") breaks it on the
 *     SECOND doorbell press, because a fabricated `queued` stops tracking the
 *     mailbox: 1,1 from a silent handle against 1,2 from an absent one. So (l1)
 *     drives one identical seventeen-ring script through both and compares every
 *     response field by field — and then proves the two worlds really did behave
 *     differently inside, or "identical" would also be satisfied by the toggle
 *     doing nothing at all. (l2) proves only the OWNING device may silence a
 *     handle, and that the three ways of not being the owner give one answer.
 *     (l4) reads one stored row at four clocks, so read-time expiry is a fact
 *     about the row and not about anything that ran in between. (l5) proves the
 *     separate domain string in both directions, with controls, since "both were
 *     refused" is also what a broken signer looks like.
 *   - (j) reads the SOURCE, because the worst mistakes available here are
 *     invisible to any functional test: a handler added after the
 *     `this.signal(request)` fallthrough is inert behind a 426; a mailbox write
 *     that stamps the operator room registry is a privacy leak that works
 *     perfectly; and a register handler that never persists `putKey` leaves
 *     first-writer-wins permanently disengaged while every pure-function test
 *     in (g) still passes. (j4) adds the silent-mode ones: kinRingDecide must
 *     have exactly ONE 200 response site (a second is where indistinguishability
 *     goes to die), the toggle must be loaded on every ring, and the proof must
 *     be verified against the STORED key rather than the presented one.
 *   - (k2) runs all of that in real workerd through real durable storage, and
 *     compares two ring responses AS BYTES rather than as parsed objects.
 *
 * A NOTE ON WHAT THIS FILE DOES NOT DO: it does not mutate worker.ts and re-run
 * itself. Mutation is run BY HAND against a saved copy of the source and the
 * results are recorded in the commit — (i0) is the closest thing here, and it
 * works by reimplementing the OLD broken code inside the test rather than by
 * editing the file. Two mutations were run for silent mode: making the silent
 * response distinguishable (fails l1/j4/k2, three different ways) and letting any
 * key silence any handle (fails l2/l5/j4/k2).
 *
 * The module is bundled from src/worker.ts on every run, like diagnose.test.mjs,
 * so this can never pass against a frozen artifact.
 *
 * Run: node contacts.test.mjs
 */
import { build } from 'esbuild';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { unlinkSync, readFileSync } from 'node:fs';

const here = dirname(fileURLToPath(import.meta.url));
const bundle = join(tmpdir(), `worker-contacts-${process.pid}.mjs`);
await build({
  entryPoints: [join(here, 'src/worker.ts')],
  bundle: true, format: 'esm', platform: 'neutral', outfile: bundle,
  logLevel: 'silent',
});
const {
  kinRingDecide, kinPollDecide, kinPollBody, kinRegisterDecide, kinQuietDecide, kinQuietActive,
  kinBoxPut, kinBoxTake, kinBoxHas, kinWaitMs, kinWindow, kinTimingSafeEqual, turnOrderUdp,
  kinB64, kinB64Encode, kinVerifyEd25519,
  KIN_HANDLE_RE, KIN_ROUTE_RE,
} = await import(bundle);
// The two signed-message prefixes are NOT exported, and must not be: worker.ts
// is the worker ENTRY module, so workerd reads every named export as an
// entrypoint and refuses to start when one is a plain string ("the provided
// value is not of type 'function or ExportedHandler'"). Exporting them for the
// convenience of this file would typecheck, pass every pure test here, and break
// the deploy — so they are read out of the source, which is where the contract
// with the Swift client lives anyway.
const srcText = readFileSync(join(here, 'src/worker.ts'), 'utf8');
const contextOf = (name) => {
  const m = srcText.match(new RegExp(`const ${name} = '([^']+)'`));
  return m ? m[1] : null;
};
const REG_CTX = contextOf('KIN_REG_CONTEXT');
const QUIET_CTX = contextOf('KIN_QUIET_CONTEXT');
process.on('exit', () => { try { unlinkSync(bundle); } catch {} });

let failures = 0;
const ok = (cond, what) => {
  if (!cond) { failures++; console.log('  FAIL  ' + what); }
};
const eq = (got, want, what) =>
  ok(got === want, `${what}: expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
const deep = (got, want, what) =>
  ok(JSON.stringify(got) === JSON.stringify(want), `${what}: expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
const sec = (s) => console.log('\n──── ' + s);

// ── Fixtures ────────────────────────────────────────────────────────────────
//
// Handles are names now: short, lowercase, machine-assigned from the Mac's
// short username with a collision ladder. So the fixtures are names.
//
// (The base32 alphabet fixture that used to live here is gone with the hash
// handles it served. It was also WRONG — it read
// 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' while Crypto.codeAlphabet is
// '23456789ABCDEFGHJKLMNPQRSTUVWXYZ', digits first — and a wrong fixture with a
// confident comment is how a port inherits a bug.)
const TO = 'devesh';
const FROM = 'asha';
const handle = (n) => 'caller' + n;               // distinct, legal, never TO
const ROOM = 'RVROOMROOMROOMROOM22';              // 20 chars, matches ROOM_RE
// 64 bytes % 3 == 1, so base64 of a signature is 86 data chars and TWO pads.
// 32 bytes % 3 == 2, so a key is 43 data chars and ONE pad. Getting this wrong
// is how a fixture ends up testing the length regex instead of the curve.
const SIG = 's'.repeat(86) + '==';                // base64-SHAPED 64 bytes, signs nothing
const KEY = 'k'.repeat(43) + '=';                 // base64 of a 32-byte Ed25519 pubkey
const kk = (n) => String(n).padStart(4, '0') + 'k'.repeat(39) + '=';   // distinct pubkeys
const TOK = 'a'.repeat(64);                       // SHA256 hex
const BADTOK = 'b'.repeat(64);

const NOW = 1_800_000_000_000;              // ms
const T = Math.floor(NOW / 1000);           // ring stamps are UNIX SECONDS

eq(SIG.length, 88, 'fixture: a ring sig is 88 chars of base64 (64 bytes)');
eq(KEY.length, 44, 'fixture: a device key is 44 chars of base64 (32 bytes)');
// The fixtures must decode to the right number of BYTES, or the shape tests
// below would be measuring the regex and never reaching the curve.
eq(kinB64(SIG, 64)?.length, 64, 'fixture: SIG really decodes to 64 bytes');
eq(kinB64(KEY, 32)?.length, 32, 'fixture: KEY really decodes to 32 bytes');

const ring = (over = {}) =>
  JSON.stringify({ to: TO, from: FROM, room: ROOM, t: T, sig: SIG, k: KEY, ...over });
const fresh = () => ({ box: new Map(), hits: new Map() });
// A ring straight into a mailbox, bypassing nothing — used to set up polls.
const put = (s, over = {}, now = NOW) => kinRingDecide(ring(over), over.to ?? TO, s.box, s.hits, now);

// ── Real Ed25519, on both ends ──────────────────────────────────────────────
//
// The test signs with the same primitive the worker verifies with. No mock: a
// mock verifier would make (g) a test of the mock. The algorithm string was
// separately probed against the real workerd binary (see the comment above
// kinVerifyEd25519) — this file only proves the worker's own arithmetic.
const te = new TextEncoder();
const b64 = (u8) => btoa(String.fromCharCode(...u8));

async function device(label) {
  const kp = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey));
  const over = async (msg) =>
    b64(new Uint8Array(await crypto.subtle.sign({ name: 'Ed25519' }, kp.privateKey, te.encode(msg))));
  return {
    label,
    k: b64(raw),
    over,                                    // sign an ARBITRARY string, for the replay tests
    async sign(to, tok, t) {
      return over('kin-reg-v1|' + to + '|' + tok + '|' + t);
    },
    // The silent-mode toggle's signed string. Written out longhand rather than
    // built from the constant on purpose: this is what a Swift client will have
    // to reproduce from the spec, so the test must state it independently. If
    // the worker changes its message and this line does not, (l) fails — which
    // is the point.
    async signQuiet(to, quiet, until, t) {
      return over('kin-quiet-v1|' + to + '|' + quiet + '|' + until + '|' + t);
    },
  };
}

// Build a registration body. It SENDS (to, tok, t) and SIGNS (signTo, signTok,
// signT), which are the same thing by default — making them differ is how a
// tampered field is expressed, and it is the only way to prove the signature
// really covers that field rather than merely accompanying it.
async function reg(dev, o = {}) {
  const to = 'to' in o ? o.to : TO;
  const tok = 'tok' in o ? o.tok : TOK;
  const t = 't' in o ? o.t : T;
  const sig = 'sig' in o ? o.sig
    : await dev.sign(o.signTo ?? to, o.signTok ?? tok, o.signT ?? t);
  const body = { to, tok, k: 'k' in o ? o.k : dev.k, t, sig };
  for (const [key, val] of Object.entries(o.extra ?? {})) body[key] = val;
  return JSON.stringify(body);
}

// A stand-in for the DO's two durable rows, replaying registers the way the real
// DO replays them — so (g) tests a SEQUENCE, not hand-placed state. The real DO
// wiring that feeds this is checked separately in (j); a harness that mirrors
// the DO can never catch the DO being wrong.
const inbox = (over = {}) => ({ tok: null, key: null, quiet: null, hits: new Map(), ...over });
async function doReg(mb, raw, to = TO, now = NOW, verify) {
  const d = await kinRegisterDecide(raw, to, mb.tok, mb.key, mb.hits, now, verify);
  if (d.put !== undefined) mb.tok = d.put;
  if (d.putKey !== undefined) mb.key = d.putKey;
  return d;
}

// Build a silent-mode body. Same trick as reg(): it SENDS (to, quiet, until, t)
// and SIGNS (signTo, signQuiet, signUntil, signT), which are the same thing by
// default. Making them differ is the only way to prove the signature COVERS a
// field rather than merely travelling beside it.
async function quietOf(dev, o = {}) {
  const to = 'to' in o ? o.to : TO;
  const quiet = 'quiet' in o ? o.quiet : true;
  const until = 'until' in o ? o.until : 0;
  const t = 't' in o ? o.t : T;
  const sig = 'sig' in o ? o.sig : await dev.signQuiet(
    o.signTo ?? to, o.signQuiet ?? quiet, o.signUntil ?? until, o.signT ?? t,
  );
  const body = { to, k: 'k' in o ? o.k : dev.k, t, sig, quiet, until };
  for (const [key, val] of Object.entries(o.extra ?? {})) body[key] = val;
  return JSON.stringify(body);
}
// Replays a quiet POST the way the real DO does: decide against the STORED key,
// then persist the third durable row. The real wiring is checked in (j4)/(k).
async function doQuiet(mb, raw, to = TO, now = NOW, verify) {
  const d = await kinQuietDecide(raw, to, mb.key, mb.hits, now, verify);
  if (d.putQuiet !== undefined) mb.quiet = d.putQuiet;
  return d;
}
// A verifier that counts curve operations, so "the skew gate runs first" stops
// being an argument about a status code and becomes a number.
const counting = () => {
  const s = { n: 0 };
  s.fn = async (...a) => { s.n++; return kinVerifyEd25519(...a); };
  return s;
};

const DEV = await device('dev1');
const DEV2 = await device('dev2');

// ── (a) clock skew: the replay gate, and it must rank two inputs differently ─
{
  sec('(a) skew: |now - t| > 60 s is refused, inside it is accepted');
  for (const [dt, want, why] of [
    [0, 200, 'exactly now'],
    [-59, 200, '59 s in the past is fine'],
    [59, 200, '59 s in the future is fine (a client clock runs both ways)'],
    [-61, 400, '61 s in the past is a replay'],
    [61, 400, '61 s in the future is a replay'],
    [-86_400, 400, 'a day-old captured ring'],
  ]) {
    const d = put(fresh(), { t: T + dt }, NOW);
    console.log(`  t${dt >= 0 ? '+' : ''}${dt}s -> ${d.status} ${JSON.stringify(d.body)}   ${why}`);
    eq(d.status, want, `(a) t${dt >= 0 ? '+' : ''}${dt}s`);
  }
  // A ring whose t is in milliseconds by mistake is ~57 million seconds off.
  eq(put(fresh(), { t: NOW }).status, 400, '(a) t in ms is refused as skew');
  eq(put(fresh(), { t: 'now' }).status, 400, '(a) non-numeric t');
  eq(put(fresh(), { t: NaN }).status, 400, '(a) NaN t');
  // `t` is stringified into the signature both ends compute, so a value with
  // more than one spelling is a signature that fails on one end and nowhere
  // says why. Integer seconds only, on both the ring and the register path.
  eq(put(fresh(), { t: T + 0.5 }).status, 400, '(a) a fractional t has two spellings — refused');
  eq(put(fresh(), { t: 1e21 }).status, 400, '(a) and 1e21 renders as "1e+21" — refused');
  eq(put(fresh(), { t: Infinity }).status, 400, '(a) Infinity t');
  eq(put(fresh(), { t: T }).status, 200, '(a) CONTROL: an integer t is fine');
}

// ── (b) handle format: short, lowercase, human, starts with a letter ────────
{
  sec('(b) handle format: ^[a-z][a-z0-9]{1,31}$ — a name, not a hash');
  const s = fresh();
  eq(kinRingDecide(ring(), TO, s.box, s.hits, NOW).status, 200, '(b) `devesh` is accepted');

  // BOTH ENDS OF BOTH BOUNDS. A regex that refuses everything passes any
  // rejection-only list, and this project has shipped rulers that could not fail.
  for (const [h, want, why] of [
    ['devesh', 200, 'the name on the box'],
    ['de', 200, 'two chars — the shortest legal handle'],
    ['d' + 'e'.repeat(31), 200, '32 chars — the longest legal handle'],
    ['devesh2', 200, 'a collision-ladder rung: digits are legal after the first char'],
    ['deveshp', 200, 'the other kind of rung'],
    ['a1b2c3', 200, 'letters and digits mixed'],
    ['d', 400, 'one char — too short to be a name'],
    ['d' + 'e'.repeat(32), 400, '33 chars — one over'],
    ['Devesh', 400, 'a capital letter (the deployed regex was UPPERCASE-only)'],
    ['DEVESH', 400, 'all caps'],
    ['9devesh', 400, 'starts with a digit'],
    ['2devesh', 400, 'starts with a digit, the base32 way'],
    ['devesh-x', 400, 'a hyphen — no separators yet, on purpose'],
    ['devesh_x', 400, 'an underscore'],
    ['devesh.x', 400, 'a dot'],
    ['dev esh', 400, 'a space'],
    ['déjà', 400, 'non-ASCII'],
    ['', 400, 'empty'],
    ['../../etc/passwd', 400, 'path traversal'],
    ['ZZZZZZZZZZZZZZZZZZZZZZZZZZ', 400, 'the OLD 26-char hash format is gone'],
  ]) {
    const st = fresh();
    const d = kinRingDecide(
      JSON.stringify({ to: h, from: FROM, room: ROOM, t: T, sig: SIG, k: KEY }),
      h, st.box, st.hits, NOW,
    );
    console.log(`  ${JSON.stringify(h).slice(0, 36).padEnd(38)} -> ${d.status} ${JSON.stringify(d.body)}   ${why}`);
    eq(d.status, want, `(b) ${why}`);
  }

  sec('(b2) the rest of the ring is validated just as strictly');
  const cases = [
    [{ room: 'short' }, 'a room under 8 chars'],
    [{ room: 'has space here!' }, 'a room outside ROOM_RE'],
    [{ room: 'x'.repeat(65) }, 'a room over 64 chars'],
    [{ sig: 'nope' }, 'a sig too short to be a signature'],
    [{ sig: 's'.repeat(200) }, 'a sig used as a payload channel'],
    [{ sig: '<script>alert(1)</script>aaaaaaaaaaaaaaaaaaaa' }, 'a sig with markup in it'],
    [{ from: TO }, 'a device ringing itself'],
    [{ k: 'nope' }, 'a k that is not 32 bytes of base64'],
    [{ k: 'k'.repeat(44) + '=' }, 'a k one byte too long'],
    [{ k: 'k'.repeat(42) + '=' }, 'a k one byte too short'],
    [{ k: 'k'.repeat(42) + '!=' }, 'a k with a character outside base64'],
    [{ k: 42 }, 'a k that is not a string'],
  ];
  for (const [over, why] of cases) {
    const d = put(fresh(), over);
    console.log(`  ${why.padEnd(46)} -> ${d.status} ${JSON.stringify(d.body)}`);
    eq(d.status, 400, `(b2) refuse ${why}`);
  }
  // A ring signed for one handle must not be filed under another: the caller's
  // signature covers `to`, so the body and the URL have to agree.
  const s3 = fresh();
  const cross = kinRingDecide(
    JSON.stringify({ to: handle(3), from: FROM, room: ROOM, t: T, sig: SIG, k: KEY }),
    TO, s3.box, s3.hits, NOW,
  );
  console.log(`  ${'a body `to` that disagrees with the URL'.padEnd(46)} -> ${cross.status} ${JSON.stringify(cross.body)}`);
  eq(cross.status, 400, '(b2) refuse a body `to` that disagrees with the URL');
  eq(s3.box.size, 0, '(b2) and nothing was filed anywhere');

  sec('(b2b) the ring field allowlist is exactly six, and `k` is one of them');
  const s2 = fresh();
  // The 7th field. A lax mailbox is an unauthenticated write channel into the
  // callee's JSON parser.
  const extra = JSON.stringify({ to: TO, from: FROM, room: ROOM, t: T, sig: SIG, k: KEY, cmd: 'rm -rf' });
  eq(kinRingDecide(extra, TO, s2.box, s2.hits, NOW).status, 400, '(b2b) a 7th unknown field drops the whole ring');
  // And the count is a count, not just an allowlist: six known fields with one
  // MISSING and one unknown substituted must also fail.
  const swapped = JSON.stringify({ to: TO, from: FROM, room: ROOM, t: T, sig: SIG, cmd: 'x' });
  eq(kinRingDecide(swapped, TO, fresh().box, fresh().hits, NOW).status, 400,
    '(b2b) six fields where one is unknown is still refused');
  // WITHOUT `k` the ring is refused: the callee would have nothing to verify
  // against, so a ring it cannot judge must never be accepted on its behalf.
  const noK = JSON.stringify({ to: TO, from: FROM, room: ROOM, t: T, sig: SIG });
  const noKd = kinRingDecide(noK, TO, fresh().box, fresh().hits, NOW);
  console.log(`  a ring with no k -> ${noKd.status} ${JSON.stringify(noKd.body)}`);
  eq(noKd.status, 400, '(b2b) a ring without `k` is refused');
  // CONTROL: the very same ring WITH k is accepted, so the above is the missing
  // field talking and not something else about the body.
  eq(kinRingDecide(ring(), TO, fresh().box, fresh().hits, NOW).status, 200,
    '(b2b) CONTROL: the same ring with `k` is accepted');

  eq(kinRingDecide('[]', TO, s2.box, s2.hits, NOW).status, 400, '(b2b) an array is not a ring');
  eq(kinRingDecide('null', TO, s2.box, s2.hits, NOW).status, 400, '(b2b) null is not a ring');
  eq(kinRingDecide('{', TO, s2.box, s2.hits, NOW).status, 400, '(b2b) unparseable JSON');
  eq(kinRingDecide('{"to":"' + TO + '"}', TO, s2.box, s2.hits, NOW).status, 400, '(b2b) a partial ring');
  eq(kinRingDecide('x'.repeat(2000), TO, s2.box, s2.hits, NOW).status, 413, '(b2b) an oversized body');
}

// ── (b3) the route regex and the body validator must not drift ─────────────
// A one-character disagreement here is a 404 with no explanation anywhere: the
// edge refuses the path, so the DO — the thing that would say "bad handle" —
// never runs. Compared decision-for-decision rather than eyeballed.
{
  sec('(b3) KIN_ROUTE_RE agrees with KIN_HANDLE_RE, character class for character class');
  const corpus = [
    'devesh', 'de', 'd', 'd' + 'e'.repeat(31), 'd' + 'e'.repeat(32),
    'Devesh', 'DEVESH', '9devesh', '2devesh', 'devesh-x', 'devesh_x', 'devesh.x',
    'a1b2c3', 'devesh2', 'z9', '', 'ZZZZZZZZZZZZZZZZZZZZZZZZZZ', 'déjà',
    'register', 'ring', 'poll', 'quiet', 'api', 'kin', 'root', 'admin', 'null', 'undefined',
  ];
  let mismatches = 0;
  for (const h of corpus) {
    const byHandle = KIN_HANDLE_RE.test(h);
    const byRoute = KIN_ROUTE_RE.test('/api/kin/' + h + '/ring');
    if (byHandle !== byRoute) {
      mismatches++;
      console.log(`  DRIFT ${JSON.stringify(h)}: handle=${byHandle} route=${byRoute}`);
    }
  }
  eq(mismatches, 0, `(b3) all ${corpus.length} corpus handles get the same verdict from both regexes`);
  // And the corpus is not all-one-answer, or the comparison above is vacuous.
  const yes = corpus.filter((h) => KIN_HANDLE_RE.test(h)).length;
  console.log(`  corpus: ${yes} legal, ${corpus.length - yes} illegal — both regexes agree on every one`);
  ok(yes > 3 && yes < corpus.length - 3, '(b3) the corpus contains plenty of both, so agreement means something');

  sec('(b3b) a handle that spells a verb is routed, not reserved');
  // DECISION, asserted so it stays one: reserved words are NOT reserved. The
  // path is four fixed segments and the capture group cannot contain a slash, so
  // the verb is always the last segment and there is nothing to be ambiguous
  // about. Somebody's Mac account really is called `poll`, and silently denying
  // them their own name would be a bug with no symptom.
  for (const [path, wantHandle, wantVerb] of [
    ['/api/kin/register/register', 'register', 'register'],
    ['/api/kin/register/ring', 'register', 'ring'],
    ['/api/kin/ring/poll', 'ring', 'poll'],
    ['/api/kin/poll/poll', 'poll', 'poll'],
    ['/api/kin/devesh/ring', 'devesh', 'ring'],
    ['/api/kin/devesh/quiet', 'devesh', 'quiet'],
    ['/api/kin/quiet/quiet', 'quiet', 'quiet'],
    ['/api/kin/quiet/ring', 'quiet', 'ring'],
  ]) {
    const m = path.match(KIN_ROUTE_RE);
    console.log(`  ${path.padEnd(30)} -> handle=${JSON.stringify(m?.[1])} verb=${JSON.stringify(m?.[2])}`);
    eq(m?.[1], wantHandle, `(b3b) ${path} handle`);
    eq(m?.[2], wantVerb, `(b3b) ${path} verb`);
  }
  // And the shapes that must NOT route, so the above is a grammar and not a
  // regex that matches anything with slashes in it.
  for (const path of [
    '/api/kin/devesh/foo', '/api/kin/devesh', '/api/kin/a/b/ring',
    '/api/kin//ring', '/api/kin/devesh/ring/', '/api/kin/devesh/RING',
    '/api/kin/devesh/register?x=1',
  ]) {
    ok(!KIN_ROUTE_RE.test(path), `(b3b) ${path} does not route`);
  }
  // A reserved-word handle is also a legal handle to the body validator, or the
  // edge would route it and the DO would then 400 it.
  for (const h of ['register', 'ring', 'poll', 'quiet']) {
    eq(kinRingDecide(
      JSON.stringify({ to: h, from: FROM, room: ROOM, t: T, sig: SIG, k: KEY }),
      h, fresh().box, fresh().hits, NOW,
    ).status, 200, `(b3b) \`${h}\` is a working handle end to end`);
  }
}

// ── (c) the mailbox is authenticated, and is not an existence oracle ────────
{
  sec('(c) poll credential');
  const s = fresh();
  eq(put(s, {}).status, 200, '(c) a ring is queued');

  const unreg = kinPollDecide(TO, TOK, null, s.box, s.hits, NOW);
  console.log(`  no registration      -> ${unreg.status} ${JSON.stringify(unreg.body)}`);
  eq(unreg.status, 401, '(c) an unregistered handle refuses the poll');

  const wrong = kinPollDecide(TO, BADTOK, TOK, s.box, s.hits, NOW);
  console.log(`  wrong credential     -> ${wrong.status} ${JSON.stringify(wrong.body)}`);
  eq(wrong.status, 401, '(c) a wrong credential is refused');
  deep(wrong.body, unreg.body, '(c) both 401s are byte-identical — not an existence oracle');

  eq(kinPollDecide(TO, 'short', TOK, s.box, s.hits, NOW).status, 400, '(c) a malformed tok');
  eq(kinPollDecide(TO, 'A'.repeat(64), TOK, s.box, s.hits, NOW).status, 400, '(c) uppercase hex is not our tok format');
  eq(kinPollDecide('Nope!', TOK, TOK, s.box, s.hits, NOW).status, 400, '(c) a malformed handle');

  // The ring is still there: a refused poll must not drain the mailbox.
  const good = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW);
  console.log(`  right credential     -> ${good.status} rings=${good.body.rings.length} ${JSON.stringify(good.body.rings[0])}`);
  eq(good.status, 200, '(c) the right credential is admitted');
  eq(good.body.rings.length, 1, '(c) three refused polls did not drain the mailbox');
  eq(good.body.rings[0].from, FROM, '(c) the ring carries the caller');
  eq(good.body.rings[0].room, ROOM, '(c) and the room to meet in');
  eq(good.body.rings[0].sig, SIG, '(c) and the signature, VERBATIM — the callee verifies it, not us');
  // THE FIELD THE WHOLE FEATURE TURNS ON. A poll that drops `k` leaves the
  // callee with a signature and nothing to check it against, so it correctly
  // refuses to ring — and that failure looks exactly like "nobody called".
  eq(good.body.rings[0].k, KEY, '(c) and the caller DEVICE KEY, or the callee can verify nothing');
  eq(good.body.rings[0].t, T, '(c) and the original stamp, or the signature would not verify');
  eq(good.body.rings[0].ageMs, 0, '(c) and its age, so the callee can judge staleness itself');
  ok(!('to' in good.body.rings[0]), '(c) the mailbox does not echo the handle back into every ring');

  ok(kinTimingSafeEqual(TOK, TOK), '(c) timing-safe compare accepts a match');
  ok(!kinTimingSafeEqual(TOK, BADTOK), '(c) and refuses a mismatch');
  ok(!kinTimingSafeEqual(TOK, TOK.slice(0, 63)), '(c) and a length mismatch');
}

// ── (d) delivered exactly once: a poll drains ──────────────────────────────
{
  sec('(d) a poll drains the mailbox');
  const s = fresh();
  put(s, {});
  const first = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW);
  const second = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 2500);
  console.log(`  poll 1 -> ${first.body.rings.length} ring(s);  poll 2 (+2.5 s) -> ${second.body.rings.length} ring(s)`);
  eq(first.body.rings.length, 1, '(d) the first poll gets the ring');
  eq(second.status, 200, '(d) the second poll is allowed');
  eq(second.body.rings.length, 0, '(d) and gets nothing — delivered exactly once');
  eq(s.box.size, 0, '(d) the drained handle is forgotten, not left as an empty list');

  // A caller who re-rings after the drain does get through again: it is still
  // waiting, and that is a real second doorbell press.
  put(s, {}, NOW + 3000);
  eq(kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 5000).body.rings.length, 1,
    '(d) a caller still waiting can ring again after a drain');
}

// ── (e) the lease, and the skew+lease stacking bug it exists to prevent ─────
{
  sec('(e) lease: 60 s from min(receipt, client stamp)');
  const s = fresh();
  put(s, {}, NOW);
  eq(kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 59_000).body.rings.length, 1,
    '(e) a 59 s old ring is still delivered');

  const s2 = fresh();
  put(s2, {}, NOW);
  const late = kinPollDecide(TO, TOK, TOK, s2.box, s2.hits, NOW + 61_000);
  console.log(`  ring at NOW, poll at +61 s -> ${late.body.rings.length} ring(s)`);
  eq(late.body.rings.length, 0, '(e) a 61 s old ring is NOT delivered — a stale ring is worse than none');

  // THE STACKING CASE. A ring stamped 59 s ago passes the skew gate, so it is
  // accepted; if the lease ran from RECEIPT it would then live another 60 s and
  // be delivered 119 s after the caller pressed call. bornAt = min(receipt,
  // stamp) is what stops that.
  const s3 = fresh();
  const accepted = put(s3, { t: T - 59 }, NOW);
  eq(accepted.status, 200, '(e) a ring stamped 59 s ago IS accepted (skew gate says so)');
  const stacked = kinPollDecide(TO, TOK, TOK, s3.box, s3.hits, NOW + 2_000);
  console.log(`  ring stamped 59 s ago, polled 2 s after receipt -> ${stacked.body.rings.length} ring(s)`);
  eq(stacked.body.rings.length, 0, '(e) and is already expired 2 s later — skew and lease do not stack');
  // Control, so the above is not just "everything expires": the same 2 s poll
  // delivers a ring stamped now.
  const s4 = fresh();
  put(s4, { t: T }, NOW);
  eq(kinPollDecide(TO, TOK, TOK, s4.box, s4.hits, NOW + 2_000).body.rings.length, 1,
    '(e) CONTROL: a freshly stamped ring survives the same 2 s');

  // A client stamp in the FUTURE must not buy a longer life.
  const s5 = fresh();
  put(s5, { t: T + 59 }, NOW);
  eq(kinPollDecide(TO, TOK, TOK, s5.box, s5.hits, NOW + 61_000).body.rings.length, 0,
    '(e) a future stamp cannot extend the lease past 60 s from receipt');
}

// ── (f) the cap, and which end of the queue it drops ───────────────────────
{
  sec('(f) cap of 8 rings per handle, oldest evicted');
  const s = fresh();
  let last;
  for (let i = 0; i < 8; i++) {
    last = kinRingDecide(
      JSON.stringify({ to: TO, from: handle(i), room: ROOM + i, t: T, sig: SIG, k: kk(i) }),
      TO, s.box, s.hits, NOW + i,
    );
  }
  eq(last.status, 200, '(f) eight rings are all accepted');
  eq(last.body.queued, 8, '(f) and all eight are held');
  eq(last.body.evicted, 0, '(f) nothing evicted yet');

  const ninth = kinRingDecide(
    JSON.stringify({ to: TO, from: handle(8), room: ROOM + 8, t: T, sig: SIG, k: kk(8) }),
    TO, s.box, s.hits, NOW + 8,
  );
  console.log(`  9th ring -> ${ninth.status} queued=${ninth.body.queued} evicted=${ninth.body.evicted}`);
  eq(ninth.body.queued, 8, '(f) the cap holds at eight');
  eq(ninth.body.evicted, 1, '(f) and it says it dropped one');

  const held = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 9).body.rings.map((r) => r.from);
  eq(held.length, 8, '(f) eight delivered');
  ok(!held.includes(handle(0)), '(f) the OLDEST was evicted');
  ok(held.includes(handle(8)), '(f) and the NEWEST survived — a jammer cannot wall the mailbox off');

  sec('(f2) a caller re-ringing the same room replaces itself');
  const s2 = fresh();
  const a = put(s2, { t: T - 30 }, NOW);
  // A real client re-stamps when it re-rings: the signature covers `t` and the
  // skew gate refuses a stale one. So the replacement carries a fresh stamp, and
  // its age must come from THAT stamp rather than from the copy it displaced.
  const b = put(s2, { t: T }, NOW + 1000);
  eq(a.body.queued, 1, '(f2) first ring');
  eq(b.body.queued, 1, '(f2) the second replaces it rather than stacking');
  eq(b.body.evicted, 0, '(f2) replacing is not evicting');
  const got = kinPollDecide(TO, TOK, TOK, s2.box, s2.hits, NOW + 1000).body.rings;
  console.log(`  same (from, room) twice -> ${got.length} ring(s), ageMs=${got[0].ageMs}`);
  eq(got.length, 1, '(f2) one doorbell press, one ring');
  eq(got[0].ageMs, 1000, '(f2) and it is the FRESH copy — age from the new stamp, not the 30 s old one');
}

// ── (g) register: PROOF OF POSSESSION ──────────────────────────────────────
//
// This is the section that matters. Handles used to be 130-bit hashes and
// unguessable, and that unguessability was the only thing protecting a mailbox.
// Handles are names now. `devesh` is guessable by anyone who has met Devesh, so
// without a signature the name goes to whoever sends the first HTTP request —
// and under the old rule, merely PROBING a free handle claimed it.
{
  sec('(g) register: base64 and canonicalisation helpers first');
  const raw32 = new Uint8Array(32).fill(7);
  const std = kinB64Encode(raw32);
  eq(std.length, 44, '(g) 32 bytes encode to 44 chars with padding');
  deep([...kinB64(std, 32)], [...raw32], '(g) and decode back byte for byte');
  // Every spelling of the SAME key must canonicalise to one string, or a
  // padding variant would read as a different device and the squat check would
  // be trivially bypassable.
  const urlsafe = std.replace(/\+/g, '-').replace(/\//g, '_');
  const unpadded = std.replace(/=+$/, '');
  for (const [variant, why] of [[urlsafe, 'url-safe alphabet'], [unpadded, 'no padding']]) {
    const dec = kinB64(variant, 32);
    ok(dec !== null, `(g) ${why} decodes`);
    eq(kinB64Encode(dec), std, `(g) ${why} canonicalises to the same key`);
  }
  eq(kinB64('!!!!', 32), null, '(g) junk decodes to null');
  eq(kinB64(kinB64Encode(new Uint8Array(31)), 32), null, '(g) 31 bytes is not a key — length is checked');
  eq(kinB64(kinB64Encode(new Uint8Array(33)), 32), null, '(g) nor is 33');

  sec('(g1) a valid signature claims a free handle; the body fits the 512-byte cap');
  const mb = inbox();
  const body = await reg(DEV);
  console.log(`  register body: ${body.length} bytes  ${body.slice(0, 60)}…`);
  const first = await doReg(mb, body);
  console.log(`  first claim   -> ${first.status} ${JSON.stringify(first.body)} put=${first.put ? 'yes' : 'no'} putKey=${first.putKey ? 'yes' : 'no'}`);
  eq(first.status, 200, '(g1) a signed claim on a free handle is accepted');
  eq(first.body.fresh, true, '(g1) and says it was fresh');
  eq(first.put, TOK, '(g1) and instructs the DO to persist the credential');
  ok(typeof first.putKey === 'string' && first.putKey.length === 44,
    '(g1) and the DEVICE KEY, canonical — without this row first-writer-wins never engages');
  eq(first.putKey, kinB64Encode(kinB64(DEV.k, 32)), '(g1) and it is this device\'s key');

  // ASSERTED, not assumed: the widest legal body must fit KIN_REG_MAX_BODY.
  const wide = 'd' + 'e'.repeat(31);
  const wideBody = await reg(DEV, { to: wide });
  console.log(`  widest legal body (32-char handle): ${wideBody.length} bytes, cap is 512`);
  ok(wideBody.length < 512, `(g1) the widest legal registration (${wideBody.length} B) fits under the 512 B cap`);
  eq((await doReg(inbox(), wideBody, wide)).status, 200, '(g1) and it is accepted at full width');
  // And the cap is a real cap, so it is not merely generous.
  eq((await doReg(inbox(), 'x'.repeat(600))).status, 413, '(g1) an oversized body is refused');

  sec('(g2) the ORIGINAL device comes back: refresh, and rotate the credential');
  const same = await doReg(mb, await reg(DEV));
  console.log(`  same device, same tok -> ${same.status} ${JSON.stringify(same.body)} put=${same.put ? 'yes' : 'no'} putKey=${same.putKey ? 'yes' : 'no'}`);
  eq(same.status, 200, '(g2) re-registering with the same key is the refresh path');
  eq(same.body.fresh, false, '(g2) and reports it was not fresh');
  eq(same.put, undefined, '(g2) and writes nothing when nothing changed');
  eq(same.putKey, undefined, '(g2) neither row is rewritten');

  const rotated = await doReg(mb, await reg(DEV, { tok: BADTOK }));
  console.log(`  same device, NEW tok  -> ${rotated.status} put=${rotated.put === BADTOK ? 'new tok' : rotated.put}`);
  eq(rotated.status, 200, '(g2) the original device may ROTATE its poll credential');
  eq(rotated.put, BADTOK, '(g2) and the new credential is persisted');
  eq(rotated.putKey, undefined, '(g2) while the key row stays as written');
  eq(mb.tok, BADTOK, '(g2) the mailbox now polls on the rotated credential');
  eq(mb.key, first.putKey, '(g2) and is still owned by the same key');

  sec('(g3) THE SQUAT TEST: a second device cannot take a claimed name');
  // dev2 is not attacking the crypto. It has its own perfectly valid keypair and
  // signs a perfectly valid registration. It simply is not the owner.
  const squat = await doReg(mb, await reg(DEV2, { tok: 'c'.repeat(64) }));
  console.log(`  dev2, valid sig of its OWN key -> ${squat.status} ${JSON.stringify(squat.body)}`);
  eq(squat.status, 403, '(g3) a different device is refused with `taken`');
  eq(squat.put, undefined, '(g3) and cannot overwrite the credential');
  eq(squat.putKey, undefined, '(g3) and cannot overwrite the key');
  eq(mb.tok, BADTOK, '(g3) the mailbox is untouched');
  eq(mb.key, first.putKey, '(g3) and still belongs to the first device');
  // CONTROL, in the same breath: the rightful device still gets in afterwards.
  // A rule that refused everyone would pass the assertion above.
  eq((await doReg(mb, await reg(DEV, { tok: BADTOK }))).status, 200,
    '(g3) CONTROL: the owner still gets in right after the squat attempt');

  sec('(g3b) presenting the owner\'s key without the owner\'s private key');
  // The other half of the squat: dev2 copies dev1's PUBLIC key (which it can
  // read off any ring) and signs with its own private key. The signature does
  // not verify under the key it presents, so it never reaches the taken check.
  const forged = JSON.parse(await reg(DEV2, { tok: 'd'.repeat(64) }));
  forged.k = DEV.k;                      // dev1's public key, dev2's signature
  const stolenKey = await doReg(mb, JSON.stringify(forged));
  console.log(`  dev2's sig under dev1's k -> ${stolenKey.status} ${JSON.stringify(stolenKey.body)}`);
  eq(stolenKey.status, 401, '(g3b) a signature that does not match the key it presents is refused');
  eq(stolenKey.put, undefined, '(g3b) and changes nothing');
  eq(mb.key, first.putKey, '(g3b) the mailbox still belongs to dev1');

  sec('(g3c) a free handle: probing it no longer CLAIMS it');
  // Under the old rule this single request took the name. Now an unsigned or
  // badly signed probe learns nothing and leaves nothing behind.
  const virgin = inbox();
  const probe = await doReg(virgin, JSON.stringify({
    to: TO, tok: TOK, k: KEY, t: T, sig: SIG,
  }));
  console.log(`  unsigned probe of a FREE handle -> ${probe.status} ${JSON.stringify(probe.body)}`);
  eq(probe.status, 401, '(g3c) a probe with a junk signature is refused');
  eq(virgin.tok, null, '(g3c) and claims nothing — the name is still free');
  eq(virgin.key, null, '(g3c) no key row either');
  // CONTROL: the real owner then walks up and takes it.
  eq((await doReg(virgin, await reg(DEV))).status, 200, '(g3c) CONTROL: the owner can still claim it');

  sec('(g4) SKEW IS CHECKED BEFORE THE SIGNATURE, proved two ways');
  // Way one: a signature that is GENUINELY VALID over a stale timestamp. If the
  // signature check ran first this would pass it, and only the skew gate can
  // refuse it. The error names which gate spoke.
  const stale = await reg(DEV, { t: T - 3600 });
  const c1 = counting();
  const staleD = await doReg(inbox(), stale, TO, NOW, c1.fn);
  console.log(`  VALID sig, t-3600s -> ${staleD.status} ${JSON.stringify(staleD.body)}  verify() calls: ${c1.n}`);
  eq(staleD.status, 400, '(g4) a valid signature with 3600 s of skew is still refused');
  eq(staleD.body.error, 'skew', '(g4) and the skew gate is what refused it');
  // Way two: the count. Zero curve operations were spent on it.
  eq(c1.n, 0, '(g4) and NOT ONE curve operation was spent — skew is checked first');

  // The control that makes the count mean something: a fresh timestamp does
  // reach the verifier exactly once.
  const c2 = counting();
  const okD = await doReg(inbox(), await reg(DEV), TO, NOW, c2.fn);
  console.log(`  valid sig, t=now   -> ${okD.status}  verify() calls: ${c2.n}`);
  eq(okD.status, 200, '(g4) CONTROL: a fresh registration is accepted');
  eq(c2.n, 1, '(g4) CONTROL: and DOES reach the verifier — the counter can count');

  // Both edges of the skew window, so it is a window and not a wall.
  for (const [dt, want, why] of [
    [0, 200, 'now'],
    [-59, 200, '59 s in the past'],
    [59, 200, '59 s in the future'],
    [-61, 400, '61 s in the past'],
    [61, 400, '61 s in the future'],
  ]) {
    const d = await doReg(inbox(), await reg(DEV, { t: T + dt }), TO, NOW);
    console.log(`  register t${dt >= 0 ? '+' : ''}${dt}s -> ${d.status} ${JSON.stringify(d.body)}   ${why}`);
    eq(d.status, want, `(g4) register skew ${why}`);
  }

  sec('(g5) the signature covers EVERY field that has an effect');
  // Sign one value, send another. Each of these proves the signed string really
  // includes that field, rather than merely travelling beside it.
  for (const [o, why] of [
    [{ t: T + 5, signT: T }, 'a tampered `t` (5 s later than signed)'],
    [{ tok: BADTOK, signTok: TOK }, 'a tampered `tok` — a signature lifted onto another credential'],
    [{ signTo: 'someoneelse' }, 'a signature made for a DIFFERENT handle'],
    [{ k: DEV2.k }, 'the wrong device key beside a valid signature'],
    [{ sig: SIG }, 'a syntactically perfect signature of nothing'],
  ]) {
    const d = await doReg(inbox(), await reg(DEV, o), TO, NOW);
    console.log(`  ${why.padEnd(58)} -> ${d.status} ${JSON.stringify(d.body)}`);
    eq(d.status, 401, `(g5) refuse ${why}`);
  }
  // Malformed shapes, refused before any crypto by a regex.
  for (const [o, want, why] of [
    [{ tok: 'nope' }, 400, 'a malformed tok'],
    [{ k: 'nope' }, 400, 'a malformed k'],
    [{ k: 'k'.repeat(43) + '=' }, 401, 'a well-formed k that is not a curve point'],
    [{ sig: 'short' }, 400, 'a sig too short to be Ed25519'],
    [{ sig: 's'.repeat(96) }, 400, 'a sig too long to be Ed25519'],
    [{ t: 'now' }, 400, 'a non-numeric t'],
    [{ t: T + 0.5 }, 400, 'a fractional t (two spellings, one signature)'],
    [{ t: Infinity }, 400, 'an infinite t'],
    [{ extra: { cmd: 'rm -rf' } }, 400, 'a 6th unknown field'],
  ]) {
    const d = await doReg(inbox(), await reg(DEV, o), TO, NOW);
    console.log(`  ${why.padEnd(58)} -> ${d.status} ${JSON.stringify(d.body)}`);
    eq(d.status, want, `(g5) ${why}`);
  }
  eq((await doReg(inbox(), await reg(DEV, { to: handle(4) }), TO, NOW)).status, 400,
    '(g5) a body/URL handle mismatch');
  eq((await doReg(inbox(), '{}')).status, 400, '(g5) an empty body');
  eq((await doReg(inbox(), '{')).status, 400, '(g5) unparseable JSON');
  eq((await doReg(inbox(), '[]')).status, 400, '(g5) an array is not a registration');
  eq((await kinRegisterDecide(await reg(DEV), 'Devesh', null, null, new Map(), NOW)).status, 400,
    '(g5) a URL handle in the old uppercase format');

  sec('(g6) a LEGACY row (tok, no key) is not a second squat window');
  // Rows written before proof-of-possession existed have a tok and no key. If
  // any valid signature could adopt one, the migration itself would be the hole
  // this whole section closes. Adoption requires already knowing the tok.
  const legacy = inbox({ tok: TOK, key: null });
  const stranger = await doReg(legacy, await reg(DEV2, { tok: 'e'.repeat(64) }));
  console.log(`  legacy row, stranger's tok -> ${stranger.status} ${JSON.stringify(stranger.body)}`);
  eq(stranger.status, 403, '(g6) a stranger cannot adopt a legacy row');
  eq(legacy.key, null, '(g6) and no key was written');
  const owner = await doReg(legacy, await reg(DEV, { tok: TOK }));
  console.log(`  legacy row, the stored tok -> ${owner.status} ${JSON.stringify(owner.body)}`);
  eq(owner.status, 200, '(g6) CONTROL: whoever knows the stored tok CAN adopt it');
  ok(typeof legacy.key === 'string', '(g6) and the key row is written, closing the row for good');
  eq((await doReg(legacy, await reg(DEV2, { tok: TOK }))).status, 403,
    '(g6) after adoption even a correct tok cannot take it — the key rules now');
}

// ── (h) rate limits ───────────────────────────────────────────────────────
{
  sec('(h) ring budget: 4/min per device key, 4/min per `from`, 12/min and 60/h per `to`');
  // ≤4 rings/min from one device key to one handle.
  const s = fresh();
  let n = 0;
  for (let i = 0; i < 4; i++) if (put(s, {}, NOW + i).status === 200) n++;
  const fifth = put(s, {}, NOW + 4);
  console.log(`  per (k,to): ${n} accepted, 5th -> ${fifth.status} ${JSON.stringify(fifth.body)}`);
  eq(n, 4, '(h) four rings from one device are accepted');
  eq(fifth.status, 429, '(h) the fifth in a minute is refused');
  // The window is a window, not a ban: it must reopen. The stamp advances with
  // the clock, or the skew gate would be the thing refusing this and the rate
  // limit would go untested.
  eq(put(s, { t: T + 61 }, NOW + 61_000).status, 200, '(h) and the window reopens a minute later');

  // The `from` window is a SIBLING of the `k` window: minting one identity must
  // not buy the other's allowance. Same `from`, a fresh key every time.
  const sf = fresh();
  let nf = 0;
  for (let i = 0; i < 4; i++) if (put(sf, { k: kk(100 + i) }, NOW + i).status === 200) nf++;
  const fifthFrom = put(sf, { k: kk(999) }, NOW + 4);
  console.log(`  per (from,to) with 5 DISTINCT keys: ${nf} accepted, 5th -> ${fifthFrom.status}`);
  eq(nf, 4, '(h) four rings from one `from` are accepted');
  eq(fifthFrom.status, 429, '(h) minting a new device key does not buy a 5th ring on the same `from`');
  eq(put(sf, { k: kk(998), t: T + 61 }, NOW + 61_000).status, 200, '(h) and that window reopens too');

  // ≤12/min per `to` from anyone. Distinct callers AND distinct keys, so neither
  // per-caller window is ever the thing that fires.
  const s2 = fresh();
  let accepted = 0;
  for (let i = 0; i < 13; i++) {
    const d = kinRingDecide(
      JSON.stringify({ to: TO, from: handle(i), room: ROOM + (i % 7), t: T, sig: SIG, k: kk(i) }),
      TO, s2.box, s2.hits, NOW + i,
    );
    if (d.status === 200) accepted++;
  }
  console.log(`  per-\`to\` from 13 distinct devices: ${accepted} accepted (was 30/min before)`);
  eq(accepted, 12, '(h) twelve rings per minute per handle, from anyone');
  eq(kinRingDecide(
    JSON.stringify({ to: TO, from: handle(50), room: ROOM + 'x', t: T + 61, sig: SIG, k: kk(50) }),
    TO, s2.box, s2.hits, NOW + 61_000,
  ).status, 200, '(h) and the per-`to` minute window reopens');

  sec('(h1b) the hourly `to` cap: what actually bounds denial of sleep');
  // A minute cap alone cannot: 12/min sustained is 17,280 rings a day. So one
  // ring every 6 s — comfortably under 12/min — must still stop at 60 in an hour.
  const s6 = fresh();
  let hourAccepted = 0;
  for (let i = 0; i < 61; i++) {
    const d = kinRingDecide(
      JSON.stringify({
        to: TO, from: handle(200 + i), room: ROOM + (i % 7),
        t: T + i * 6, sig: SIG, k: kk(200 + i),
      }),
      TO, s6.box, s6.hits, NOW + i * 6000,
    );
    if (d.status === 200) hourAccepted++;
  }
  console.log(`  one ring every 6 s for 6 minutes (under 12/min the whole way): ${hourAccepted} accepted of 61`);
  eq(hourAccepted, 60, '(h1b) sixty rings an hour per handle, and the 61st is refused');
  // And it reopens as the hour slides, or it is a ban rather than a window.
  const reopened = kinRingDecide(
    JSON.stringify({
      to: TO, from: handle(400), room: ROOM + 'z',
      t: T + 3600, sig: SIG, k: kk(400),
    }),
    TO, s6.box, s6.hits, NOW + 3_600_000,
  );
  console.log(`  one hour after the first ring -> ${reopened.status} ${JSON.stringify(reopened.body)}`);
  eq(reopened.status, 200, '(h1b) and the hour window slides open again');

  sec('(h1c) a refused caller does not spend the victim\'s global budget');
  // Ordering: the per-caller windows are checked BEFORE the per-`to` ones, so
  // one flooder cannot exhaust everybody else's allowance by being refused.
  const s7 = fresh();
  for (let i = 0; i < 20; i++) put(s7, {}, NOW + i);   // one device, 4 land, 16 refused
  let others = 0;
  for (let i = 0; i < 12; i++) {
    const d = kinRingDecide(
      JSON.stringify({ to: TO, from: handle(300 + i), room: ROOM + i, t: T, sig: SIG, k: kk(300 + i) }),
      TO, s7.box, s7.hits, NOW + 20 + i,
    );
    if (d.status === 200) others++;
  }
  console.log(`  after one device burned 20 attempts, 12 other devices: ${others} accepted`);
  eq(others, 8, '(h1c) the flooder spent only its own 4 of the 12, not all of them');
  ok(others > 0, '(h1c) and genuine callers still got through');

  sec('(h) poll limits');
  const s3 = fresh();
  eq(kinPollDecide(TO, TOK, TOK, s3.box, s3.hits, NOW).status, 200, '(h) first poll');
  eq(kinPollDecide(TO, TOK, TOK, s3.box, s3.hits, NOW + 1999).status, 429, '(h) a poll 1999 ms later is refused');
  eq(kinPollDecide(TO, TOK, TOK, s3.box, s3.hits, NOW + 2000).status, 200, '(h) at 2000 ms it is allowed');

  // A STRANGER MUST NOT BE ABLE TO 429 THE OWNER OFF THEIR OWN MAILBOX.
  const s4 = fresh();
  put(s4, {});
  for (let i = 0; i < 25; i++) kinPollDecide(TO, BADTOK, TOK, s4.box, s4.hits, NOW + i);
  const ownerPoll = kinPollDecide(TO, TOK, TOK, s4.box, s4.hits, NOW + 25);
  console.log(`  after 25 failed polls, the owner -> ${ownerPoll.status} rings=${ownerPoll.body.rings?.length}`);
  eq(ownerPoll.status, 200, '(h) failed polls are charged to their own window, not the owner\'s');
  eq(ownerPoll.body.rings.length, 1, '(h) and the owner still gets the ring');
  // And the failed-auth window itself does close, so it is not a free spin.
  let refused = 0;
  const s5 = fresh();
  for (let i = 0; i < 40; i++) if (kinPollDecide(TO, BADTOK, TOK, s5.box, s5.hits, NOW + i).status === 429) refused++;
  eq(refused, 10, '(h) failed polls are themselves capped at 30/min');

  sec('(h2) the budgets are siblings, not one shared pot');
  // Two independent maps: exhausting one says nothing about the other. This is
  // the shape of kinPosts vs macPosts.
  const mine = new Map(), theirs = new Map();
  for (let i = 0; i < 5; i++) kinWindow(mine, 'ip', NOW + i, 60_000, 5);
  eq(kinWindow(mine, 'ip', NOW + 5, 60_000, 5), false, '(h2) my budget is spent');
  eq(kinWindow(theirs, 'ip', NOW + 5, 60_000, 5), true, '(h2) and the neighbour\'s is untouched');
  // And inside one map, the verb prefixes cannot spend each other either.
  const edge = new Map();
  for (let i = 0; i < 5; i++) kinWindow(edge, 'ring|1.2.3.4', NOW + i, 60_000, 5);
  eq(kinWindow(edge, 'ring|1.2.3.4', NOW + 5, 60_000, 5), false, '(h2) ring is spent');
  eq(kinWindow(edge, 'poll|1.2.3.4', NOW + 5, 60_000, 5), true, '(h2) poll is not — a ring flood cannot stop a poll');
  eq(kinWindow(edge, 'ring|5.6.7.8', NOW + 5, 60_000, 5), true, '(h2) and another IP is not');

  sec('(h3) register is capped, and the cap reopens');
  const rmb = inbox();
  let regOk = 0;
  for (let i = 0; i < 10; i++) if ((await doReg(rmb, await reg(DEV), TO, NOW + i)).status === 200) regOk++;
  const eleventh = await doReg(rmb, await reg(DEV), TO, NOW + 10);
  console.log(`  registers in one minute: ${regOk} accepted, 11th -> ${eleventh.status}`);
  eq(regOk, 10, '(h3) ten registers a minute per handle');
  eq(eleventh.status, 429, '(h3) the eleventh is refused');
  eq((await doReg(rmb, await reg(DEV, { t: T + 61 }), TO, NOW + 61_000)).status, 200,
    '(h3) and the window reopens');
}

// ── (l) SILENT MODE ────────────────────────────────────────────────────────
//
// "There should be an option of silent mode or something. Where, like, if that
// is enabled, no one can call you." Lettered (l) but placed here, with the other
// FUNCTIONAL sections: (i) is TURN, (j) reads the source, (k) runs workerd, and
// all three are last-mile sections that this one has entries in as well.
//
// THE PRIMARY INVARIANT IS (l1) AND IT IS NOT THE OBVIOUS ONE. Whether silence
// silences is easy to get right and easy to test. What is easy to break by
// accident is that a caller must not be able to TELL silence from absence — and
// the natural implementation ("if silent, return ok early") breaks it on the
// second doorbell press, because the fabricated `queued` stops tracking the
// mailbox. So (l1) drives an identical seventeen-ring script through a silent
// handle and an absent one and compares every response byte for byte, and then
// proves the two worlds really did behave differently on the inside — otherwise
// "identical" would be satisfied by silent mode not working at all.
{
  // A mailbox already owned by DEV, so each case below starts from a clean rate
  // window. Same shape doReg would have left behind, and (j4)/(k) check that the
  // real DO reaches it.
  const DEVK = kinB64Encode(kinB64(DEV.k, 32));
  const owned = (over = {}) => inbox({ tok: TOK, key: DEVK, ...over });

  sec('(l1) THE INVARIANT: a ring to a SILENT handle is byte-identical to a ring to an ABSENT one');
  // The silent row is produced by the real decision function, not hand-built —
  // a hand-built row would test this file's idea of the shape.
  const setter = owned();
  const set = await doQuiet(setter, await quietOf(DEV, { quiet: true, until: 0 }));
  eq(set.status, 200, '(l1) setup: the owner silences the handle');
  const QUIET_ON = setter.quiet;
  ok(kinQuietActive(QUIET_ON, NOW), '(l1) setup: and the row reads as silent at NOW');

  // Seventeen rings that between them exercise every number in the response:
  // accumulation, replacement, the cap, eviction, a rate refusal, and two
  // validation refusals. The two worlds see EXACTLY this list.
  const script = [];
  for (let i = 0; i < 13; i++) script.push({ from: handle(i), room: ROOM + i, k: kk(i) });
  script.splice(2, 0, { from: handle(0), room: ROOM + 0, k: kk(0) });   // a re-ring: replaces
  script.push({ from: handle(20), room: ROOM + 20, k: kk(20) });        // past the minute cap
  script.push({ from: handle(21), room: 'short', k: kk(21) });          // a bad room: 400
  script.push({ from: handle(22), room: ROOM + 22, k: kk(22), t: T - 3600 }); // stale: 400

  const silent = fresh();
  const away = fresh();
  let mismatches = 0;
  const seen = { statuses: new Set(), maxQueued: 0, evicted: 0, muted: 0 };
  for (let i = 0; i < script.length; i++) {
    const c = script[i];
    const raw = JSON.stringify({ to: TO, from: c.from, room: c.room, t: c.t ?? T, sig: SIG, k: c.k });
    const at = NOW + i * 10;
    // The ONLY difference between these two calls is the sixth argument.
    const s = kinRingDecide(raw, TO, silent.box, silent.hits, at, QUIET_ON);
    const a = kinRingDecide(raw, TO, away.box, away.hits, at, null);
    const sTxt = s.status + ' ' + JSON.stringify(s.body);
    const aTxt = a.status + ' ' + JSON.stringify(a.body);
    if (sTxt !== aTxt) {
      mismatches++;
      console.log(`  DIVERGED on ring ${i}:  silent ${sTxt}   absent ${aTxt}`);
    }
    // Field by field, not merely "both 200": the stringify above already pins
    // the key ORDER, and these pin the values a caller can read.
    eq(s.status, a.status, `(l1) ring ${i}: same status`);
    deep(Object.keys(s.body), Object.keys(a.body), `(l1) ring ${i}: same fields, same order`);
    for (const key of Object.keys(a.body)) {
      eq(s.body[key], a.body[key], `(l1) ring ${i}: same ${key}`);
    }
    // The out-of-band flag must NEVER be in a body. If it is, the toggle is
    // legible from the outside and this whole section is decoration.
    ok(!('muted' in s.body), `(l1) ring ${i}: the silenced flag is not in the response body`);
    ok(a.muted === undefined, `(l1) ring ${i}: and an absent handle never reports one`);
    if (s.status === 200) {
      seen.maxQueued = Math.max(seen.maxQueued, s.body.queued);
      seen.evicted += s.body.evicted;
      if (s.muted) seen.muted++;
      eq(s.muted, true, `(l1) ring ${i}: accepted by a silent handle IS silenced out of band`);
    } else {
      eq(s.muted, undefined, `(l1) ring ${i}: a REFUSED ring is not silenced — the check is last`);
    }
    seen.statuses.add(s.status);
  }
  console.log(`  ${script.length} rings, statuses ${[...seen.statuses].sort().join('/')}, `
    + `max queued ${seen.maxQueued}, evictions ${seen.evicted}, silenced ${seen.muted}`);
  eq(mismatches, 0, `(l1) all ${script.length} responses are byte-identical between a silent handle and an absent one`);
  // THE CONTROLS THAT MAKE THAT MEAN SOMETHING. A script that only ever produced
  // 400s would compare equal and prove nothing.
  ok(seen.statuses.has(200), '(l1) the script contains accepted rings');
  ok(seen.statuses.has(400), '(l1) and refused ones');
  ok(seen.statuses.has(429), '(l1) and rate-limited ones — a silent handle still says 429, or the toggle is legible');
  ok(seen.maxQueued > 1, `(l1) and \`queued\` really climbed (to ${seen.maxQueued}) — this is the field the obvious implementation fabricates`);
  ok(seen.evicted > 0, '(l1) and the cap really evicted');
  ok(seen.muted > 0, '(l1) and the silent world really silenced rings');

  // ── and now the difference, which only the OWNER can see ──────────────────
  const sPoll = kinPollDecide(TO, TOK, TOK, silent.box, silent.hits, NOW + 900, QUIET_ON, seen.muted);
  const aPoll = kinPollDecide(TO, TOK, TOK, away.box, away.hits, NOW + 900, null, 0);
  console.log(`  the owner's poll:  silent -> ${sPoll.body.rings?.length} ring(s), absent -> ${aPoll.body.rings?.length} ring(s)`);
  eq(sPoll.body.rings?.length, 0, '(l1) the silent handle delivers NOTHING to the callee');
  eq(aPoll.body.rings?.length, 8, '(l1) while the absent one had eight waiting all along');
  eq(silent.box.size, 0, '(l1) and the silenced rings are thrown away by the drain, not kept');
  eq(sPoll.body.quiet?.on, true, '(l1) the owner, and only the owner, is told why');

  sec('(l2) only the device that owns the handle may silence it');
  const mb = owned();
  const c1 = counting();
  const byOwner = await doQuiet(mb, await quietOf(DEV, { quiet: true, until: 0 }), TO, NOW, c1.fn);
  console.log(`  the owner            -> ${byOwner.status} ${JSON.stringify(byOwner.body)}  verify() calls: ${c1.n}`);
  eq(byOwner.status, 200, '(l2) the owning device is accepted');
  eq(byOwner.body.quiet, true, '(l2) and told the toggle is in force');
  eq(c1.n, 1, '(l2) at the cost of exactly one curve operation');
  deep(mb.quiet, { quiet: true, until: 0, exceptKnown: false, at: NOW }, '(l2) and this is the row that was written');

  // DEV2 is not attacking the crypto: it has its own valid keypair and signs a
  // perfectly valid toggle. It simply is not the owner.
  const c2 = counting();
  const byStranger = await doQuiet(owned(), await quietOf(DEV2), TO, NOW, c2.fn);
  console.log(`  another device       -> ${byStranger.status} ${JSON.stringify(byStranger.body)}  verify() calls: ${c2.n}`);
  eq(byStranger.status, 401, '(l2) a different device cannot silence someone else\'s handle');
  eq(byStranger.putQuiet, undefined, '(l2) and writes nothing');
  eq(c2.n, 0, '(l2) and never reaches the curve — the ownership compare is free, and first');

  // A handle nobody has registered has no key to prove possession against.
  const c3 = counting();
  const virgin = inbox();
  const noKey = await doQuiet(virgin, await quietOf(DEV), TO, NOW, c3.fn);
  console.log(`  an UNCLAIMED handle  -> ${noKey.status} ${JSON.stringify(noKey.body)}  verify() calls: ${c3.n}`);
  eq(noKey.status, 401, '(l2) an unregistered handle cannot be silenced');
  eq(virgin.quiet, null, '(l2) and nothing is stored under it');
  eq(c3.n, 0, '(l2) no curve operation either');
  deep(noKey.body, byStranger.body,
    '(l2) and its refusal is byte-identical to the wrong-key one — not a second existence oracle');

  // The one failure that DOES cost a curve op is the owner-shaped one, which is
  // the only place the expense is justified.
  const c4 = counting();
  const badSig = await doQuiet(owned(), await quietOf(DEV, { sig: SIG }), TO, NOW, c4.fn);
  console.log(`  owner's key, junk sig-> ${badSig.status} ${JSON.stringify(badSig.body)}  verify() calls: ${c4.n}`);
  eq(badSig.status, 401, '(l2) the owner\'s key with a signature of nothing is refused');
  deep(badSig.body, byStranger.body, '(l2) with the same refusal — three causes, one answer');
  eq(c4.n, 1, '(l2) and this is the only failure that spends a curve operation');

  // Every spelling of the owner's key is the owner's key, or a padding variant
  // would read as a stranger and lock a device out of its own toggle.
  for (const [variant, why] of [
    [DEV.k.replace(/=+$/, ''), 'unpadded'],
    [DEV.k.replace(/\+/g, '-').replace(/\//g, '_'), 'url-safe alphabet'],
  ]) {
    const d = await doQuiet(owned(), await quietOf(DEV, { k: variant }), TO, NOW);
    console.log(`  owner's key, ${why.padEnd(19)} -> ${d.status}`);
    eq(d.status, 200, `(l2) the owner's key in the ${why} spelling is still the owner's key`);
  }

  // CONTROL: a rule that refused everybody would pass every assertion above.
  const back = await doQuiet(mb, await quietOf(DEV, { quiet: false }), TO, NOW + 1000);
  eq(back.status, 200, '(l2) CONTROL: the owner still gets in after all of that');
  eq(back.body.quiet, false, '(l2) and can turn it back OFF — a toggle, not a trapdoor');
  eq(mb.quiet?.quiet, false, '(l2) which is what the stored row now says');

  sec('(l3) quiet:true and a ring lands nowhere; quiet:false and it lands');
  {
    const box = owned();
    await doQuiet(box, await quietOf(DEV, { quiet: true }));
    const s = fresh();
    const r1 = kinRingDecide(ring(), TO, s.box, s.hits, NOW, box.quiet);
    eq(r1.status, 200, '(l3) the ring is accepted');
    eq(r1.muted, true, '(l3) and silenced');
    eq(s.box.get(TO)?.length, 1, '(l3) it is HELD, so `queued` keeps telling the truth to the caller');
    const p1 = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 100, box.quiet, 1);
    eq(p1.body.rings?.length, 0, '(l3) and the callee is never handed it');
    eq(s.box.size, 0, '(l3) the drain threw it away — a silenced ring is not delivered later');

    // The toggle goes off, the very same caller rings again.
    await doQuiet(box, await quietOf(DEV, { quiet: false, t: T + 1 }), TO, NOW + 1000);
    const r2 = kinRingDecide(ring({ t: T + 3 }), TO, s.box, s.hits, NOW + 3000, box.quiet);
    eq(r2.status, 200, '(l3) the next ring is accepted');
    eq(r2.muted, undefined, '(l3) and is NOT silenced');
    const p2 = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 3100, box.quiet, 1);
    eq(p2.body.rings?.length, 1, '(l3) so it reaches the callee');
    eq(p2.body.rings?.[0]?.from, FROM, '(l3) with the caller intact');

    // ONE MAILBOX, BOTH KINDS. The filter is per-ring, not per-mailbox: a ring
    // that arrived before the toggle went on is still delivered afterwards.
    const s2 = fresh();
    kinRingDecide(ring({ from: handle(31), room: ROOM + 31, k: kk(31) }), TO, s2.box, s2.hits, NOW, null);
    kinRingDecide(ring({ from: handle(32), room: ROOM + 32, k: kk(32) }), TO, s2.box, s2.hits, NOW + 1, QUIET_ON);
    const mixed = kinPollDecide(TO, TOK, TOK, s2.box, s2.hits, NOW + 2, QUIET_ON, 1);
    console.log(`  a mailbox holding one live ring and one silenced -> ${mixed.body.rings?.length} delivered`);
    eq(mixed.body.rings?.length, 1, '(l3) only the live one is delivered');
    eq(mixed.body.rings?.[0]?.from, handle(31), '(l3) and it is the one that arrived before the toggle');
  }

  sec('(l4) `until` is a deadline, and it EXPIRES WHEN IT IS READ — nothing sweeps');
  {
    const until = T + 3600;
    const box = owned();
    const d = await doQuiet(box, await quietOf(DEV, { quiet: true, until }));
    eq(d.status, 200, '(l4) a time-boxed silence is accepted');
    eq(d.body.until, until, '(l4) and echoes the deadline back');
    deep(box.quiet, { quiet: true, until, exceptKnown: false, at: NOW }, '(l4) stored verbatim, as signed');

    // ONE ROW, FOUR CLOCKS. Nothing runs between these calls.
    const row = box.quiet;
    ok(kinQuietActive(row, NOW), '(l4) silent now');
    ok(kinQuietActive(row, until * 1000 - 1), '(l4) silent one millisecond before the deadline');
    ok(!kinQuietActive(row, until * 1000), '(l4) NOT silent at the deadline');
    ok(!kinQuietActive(row, until * 1000 + 86_400_000), '(l4) nor a day later');
    deep(box.quiet, { quiet: true, until, exceptKnown: false, at: NOW },
      '(l4) and the row is UNTOUCHED — the expiry was a read, not a sweep');

    // Through the ring path, which is where it matters.
    const before = fresh();
    eq(kinRingDecide(ring(), TO, before.box, before.hits, NOW, row).muted, true,
      '(l4) a ring before the deadline is silenced');
    const after = fresh();
    const lateRing = kinRingDecide(ring({ t: until }), TO, after.box, after.hits, until * 1000, row);
    eq(lateRing.status, 200, '(l4) a ring after the deadline is accepted');
    eq(lateRing.muted, undefined, '(l4) and NOT silenced');
    eq(kinPollDecide(TO, TOK, TOK, after.box, after.hits, until * 1000 + 100, row, 0).body.rings?.length, 1,
      '(l4) so it is delivered, with nobody having lifted the toggle');

    // The other three shapes kinQuietActive has to rank, or "it expires" is
    // indistinguishable from "it never silences".
    ok(kinQuietActive({ quiet: true, until: 0, exceptKnown: false, at: NOW }, NOW + 10 * 365 * 86_400_000),
      '(l4) until:0 is INDEFINITE — still silent a decade later');
    ok(!kinQuietActive({ quiet: false, until: T + 3600, exceptKnown: false, at: NOW }, NOW),
      '(l4) quiet:false with a live deadline is not silent — the toggle wins');
    ok(!kinQuietActive(null, NOW), '(l4) no row at all is not silent');
    ok(!kinQuietActive(undefined, NOW), '(l4) nor an unread one');
  }

  sec('(l5) DOMAIN SEPARATION: a quiet signature is not a register signature, either way round');
  {
    eq(REG_CTX, 'kin-reg-v1|', '(l5) the register domain string is what the Swift client signs');
    eq(QUIET_CTX, 'kin-quiet-v1|', '(l5) and the quiet one is its own');
    ok(QUIET_CTX !== REG_CTX, '(l5) they are not the same string');
    ok(!QUIET_CTX.startsWith(REG_CTX) && !REG_CTX.startsWith(QUIET_CTX),
      '(l5) and neither is a prefix of the other, so no field layout can make one read as the other');

    // A register signature, presented as a toggle.
    const regSig = JSON.parse(await reg(DEV, { tok: TOK, t: T })).sig;
    const asQuiet = await doQuiet(owned(), await quietOf(DEV, { sig: regSig }), TO, NOW);
    console.log(`  a REGISTER signature used to silence -> ${asQuiet.status} ${JSON.stringify(asQuiet.body)}`);
    eq(asQuiet.status, 401, '(l5) a register signature cannot silence a handle');

    // A toggle signature, presented as a registration.
    const quietSig = JSON.parse(await quietOf(DEV, { quiet: true, until: 0, t: T })).sig;
    const mb2 = inbox();
    const asReg = await doReg(mb2, await reg(DEV, { sig: quietSig }), TO, NOW);
    console.log(`  a QUIET signature used to register   -> ${asReg.status} ${JSON.stringify(asReg.body)}`);
    eq(asReg.status, 401, '(l5) a quiet signature cannot claim a handle');
    eq(mb2.key, null, '(l5) and claims nothing');

    // CONTROLS, in the same breath: each signature works for its OWN operation.
    // Without these, "both were refused" is what a broken signer looks like.
    eq((await doReg(inbox(), await reg(DEV, { tok: TOK, t: T }), TO, NOW)).status, 200,
      '(l5) CONTROL: that same register body, with its own signature, registers');
    eq((await doQuiet(owned(), await quietOf(DEV, { quiet: true, until: 0, t: T }), TO, NOW)).status, 200,
      '(l5) CONTROL: and that same quiet body, with its own signature, silences');

    // And the signature covers every field of the toggle that has an effect.
    for (const [o, why] of [
      [{ signQuiet: false }, 'signed quiet:false, sent quiet:true — the toggle itself'],
      [{ signQuiet: true, quiet: false }, 'and the same trick in reverse'],
      [{ until: T + 3600, signUntil: 0 }, 'a tampered `until` — silence stretched past what was signed'],
      [{ until: T + 60, signUntil: T + 3600 }, 'a tampered `until` the other way'],
      [{ signTo: 'someoneelse' }, 'a signature made for a DIFFERENT handle'],
      [{ t: T + 5, signT: T }, 'a tampered `t` (5 s later than signed)'],
      [{ k: DEV2.k }, 'the wrong device key beside a valid signature'],
    ]) {
      const r = await doQuiet(owned(), await quietOf(DEV, o), TO, NOW);
      console.log(`  ${why.padEnd(58)} -> ${r.status} ${JSON.stringify(r.body)}`);
      eq(r.status, 401, `(l5) refuse ${why}`);
      eq(r.putQuiet, undefined, `(l5) and store nothing for ${why}`);
    }
  }

  sec('(l6) SKEW IS CHECKED BEFORE THE SIGNATURE on the quiet route too');
  {
    // A GENUINELY VALID signature over a stale timestamp. Only the skew gate can
    // refuse this, and the counter says how much it cost to find out.
    const c = counting();
    const stale = await doQuiet(owned(), await quietOf(DEV, { t: T - 3600 }), TO, NOW, c.fn);
    console.log(`  VALID sig, t-3600s -> ${stale.status} ${JSON.stringify(stale.body)}  verify() calls: ${c.n}`);
    eq(stale.status, 400, '(l6) a valid signature with an hour of skew is still refused');
    eq(stale.body.error, 'skew', '(l6) and the skew gate is what refused it');
    eq(c.n, 0, '(l6) and NOT ONE curve operation was spent — skew is checked first');
    const c2 = counting();
    const ok200 = await doQuiet(owned(), await quietOf(DEV), TO, NOW, c2.fn);
    eq(ok200.status, 200, '(l6) CONTROL: a fresh toggle is accepted');
    eq(c2.n, 1, '(l6) CONTROL: and DOES reach the verifier — the counter can count');
    for (const [dt, want, why] of [
      [0, 200, 'now'], [-59, 200, '59 s in the past'], [59, 200, '59 s in the future'],
      [-61, 400, '61 s in the past'], [61, 400, '61 s in the future'],
    ]) {
      const d = await doQuiet(owned(), await quietOf(DEV, { t: T + dt }), TO, NOW);
      console.log(`  quiet t${dt >= 0 ? '+' : ''}${dt}s -> ${d.status} ${JSON.stringify(d.body)}   ${why}`);
      eq(d.status, want, `(l6) quiet skew ${why}`);
    }
  }

  sec('(l7) poll hands the toggle back, so a restarted or updated client relearns it');
  {
    const shape = (q, dropped, now = NOW) =>
      kinPollDecide(TO, TOK, TOK, new Map(), new Map(), now, q, dropped).body;
    // THE WIRE SHAPE, pinned. A client that was restarted has no idea what it set,
    // and a toggle that has desynchronised from the server is how someone
    // believes they are reachable while they are not.
    const none = shape(null, 0);
    deep(Object.keys(none), ['to', 'rings', 'quiet', 'pollMs', 'leaseMs'],
      '(l7) the poll body gained `quiet` and lost nothing');
    deep(none.quiet, { on: false, until: 0, exceptKnown: false, dropped: 0 },
      '(l7) a handle with no row still reports the full shape — no missing keys for a Swift decoder');

    const until = T + 3600;
    deep(shape({ quiet: true, until: 0, exceptKnown: false, at: NOW }, 3).quiet,
      { on: true, until: 0, exceptKnown: false, dropped: 3 },
      '(l7) silent indefinitely, and it says how many calls it swallowed');
    deep(shape({ quiet: true, until, exceptKnown: false, at: NOW }, 0).quiet,
      { on: true, until, exceptKnown: false, dropped: 0 },
      '(l7) silent with a deadline, read before it');
    // THE ONE THAT MATTERS: read AFTER the deadline the row still says
    // quiet:true, and the report must not.
    deep(shape({ quiet: true, until, exceptKnown: false, at: NOW }, 0, until * 1000).quiet,
      { on: false, until, exceptKnown: false, dropped: 0 },
      '(l7) an expired deadline reports on:false — the client must believe `on`, not `until`');
    deep(shape({ quiet: false, until: 0, exceptKnown: false, at: NOW }, 5).quiet,
      { on: false, until: 0, exceptKnown: false, dropped: 5 },
      '(l7) and a toggle that is off reports off');
    // v1 has no wire field for exceptKnown, so it can only ever be false. Asserted
    // so that adding one is a deliberate act that breaks a test and gets read.
    const setter2 = owned();
    await doQuiet(setter2, await quietOf(DEV, { quiet: true }));
    eq(setter2.quiet?.exceptKnown, false, '(l7) exceptKnown is stored and is always false in v1');
    eq((await doQuiet(owned(), await quietOf(DEV, { extra: { exceptKnown: true } }), TO, NOW)).status, 400,
      '(l7) and cannot be set from the wire — a 7th field drops the whole request');
  }

  sec('(l8) the toggle is validated as strictly as everything else here');
  {
    const cases = [
      [{ quiet: 'yes' }, 400, 'a quiet that is not a boolean'],
      [{ quiet: 1 }, 400, 'quiet as a number (1 and true are different signatures)'],
      [{ until: 'soon' }, 400, 'an until that is not a number'],
      [{ until: -1 }, 400, 'a negative until'],
      [{ until: T + 0.5 }, 400, 'a fractional until (two spellings, one signature)'],
      [{ until: 1e21 }, 400, 'an until that renders as "1e+21"'],
      [{ until: Infinity }, 400, 'an infinite until'],
      [{ until: T - 60 }, 400, 'a deadline already in the past — a toggle that would read on and behave off'],
      [{ until: T }, 400, 'a deadline of exactly now'],
      [{ until: NOW }, 400, 'an until in MILLISECONDS by mistake — 57,000 years, refused by the horizon'],
      [{ t: 'now' }, 400, 'a non-numeric t'],
      [{ t: T + 0.5 }, 400, 'a fractional t'],
      // WATCH WHICH GATE SPEAKS on the next line. It answers `skew`, not `bad t`,
      // because Number.isInteger(1e21) is TRUE — the integer check catches
      // fractions and the skew gate catches magnitudes. `until` has no skew gate,
      // which is why KIN_QUIET_MAX_S exists (the 1e21 `until` case above).
      [{ t: 1e21 }, 400, 'a t that renders as "1e+21"'],
      [{ t: NaN }, 400, 'a NaN t'],
      [{ k: 'nope' }, 400, 'a malformed k'],
      [{ k: 'k'.repeat(44) + '=' }, 400, 'a k one byte too long'],
      [{ sig: 'short' }, 400, 'a sig too short to be Ed25519'],
      [{ sig: 's'.repeat(96) }, 400, 'a sig too long to be Ed25519'],
      [{ to: handle(9) }, 400, 'a body `to` that disagrees with the URL'],
      [{ extra: { cmd: 'rm -rf' } }, 400, 'a 7th unknown field'],
      [{ until: T + 3600 }, 200, 'CONTROL: a deadline an hour out'],
      [{ until: T + 315_360_000 }, 200, 'CONTROL: the far edge of the horizon, ~10 years'],
      [{ until: 0 }, 200, 'CONTROL: indefinite'],
      [{ quiet: false, until: 0 }, 200, 'CONTROL: turning it off'],
    ];
    for (const [o, want, why] of cases) {
      const d = await doQuiet(owned(), await quietOf(DEV, o), TO, NOW);
      console.log(`  ${why.padEnd(66)} -> ${d.status} ${JSON.stringify(d.body)}`);
      eq(d.status, want, `(l8) ${why}`);
    }
    eq((await doQuiet(owned(), '{}')).status, 400, '(l8) an empty body');
    eq((await doQuiet(owned(), '{')).status, 400, '(l8) unparseable JSON');
    eq((await doQuiet(owned(), '[]')).status, 400, '(l8) an array is not a toggle');
    eq((await doQuiet(owned(), 'null')).status, 400, '(l8) nor is null');
    eq((await doQuiet(owned(), 'x'.repeat(600))).status, 413, '(l8) an oversized body');
    eq((await kinQuietDecide(await quietOf(DEV), 'Devesh', DEVK, new Map(), NOW)).status, 400,
      '(l8) an out-of-format URL handle');
    // The body a real client sends must fit the cap at full width.
    const wide = 'd' + 'e'.repeat(31);
    const wideBody = await quietOf(DEV, { to: wide, until: T + 315_360_000 });
    console.log(`  widest legal quiet body: ${wideBody.length} bytes, cap is 512`);
    ok(wideBody.length < 512, `(l8) the widest legal toggle (${wideBody.length} B) fits under the 512 B cap`);

    sec('(l9) the toggle is rate limited, and a stranger cannot lock the owner out of it');
    const rmb = owned();
    let n = 0;
    for (let i = 0; i < 6; i++) if ((await doQuiet(rmb, await quietOf(DEV), TO, NOW + i)).status === 200) n++;
    const seventh = await doQuiet(rmb, await quietOf(DEV), TO, NOW + 6);
    console.log(`  toggles in one minute: ${n} accepted, 7th -> ${seventh.status} ${JSON.stringify(seventh.body)}`);
    eq(n, 6, '(l9) six toggles a minute per handle');
    eq(seventh.status, 429, '(l9) the seventh is refused');
    eq((await doQuiet(rmb, await quietOf(DEV, { t: T + 61 }), TO, NOW + 61_000)).status, 200,
      '(l9) and the window reopens — a limit that never reopens is a ban');

    // A STRANGER MUST NOT BE ABLE TO 429 THE OWNER OUT OF THEIR OWN TOGGLE.
    const smb = owned();
    for (let i = 0; i < 25; i++) await doQuiet(smb, await quietOf(DEV2), TO, NOW + i);
    const ownerAfter = await doQuiet(smb, await quietOf(DEV), TO, NOW + 25);
    console.log(`  after 25 refused attempts, the owner -> ${ownerAfter.status}`);
    eq(ownerAfter.status, 200, '(l9) failed attempts are charged to their own window, not the owner\'s');
    // And that window closes too, so it is not a free spin at our CPU.
    let refused = 0;
    const fmb = owned();
    for (let i = 0; i < 40; i++) {
      if ((await doQuiet(fmb, await quietOf(DEV2), TO, NOW + i)).status === 429) refused++;
    }
    eq(refused, 10, '(l9) and refused attempts are themselves capped at 30/min');
  }
}

// ── (m) THE HELD POLL ──────────────────────────────────────────────────────
//
// The doorbell used to be a 5 s poll, so a call took 2.5 s on average and 5 s at
// worst to reach a screen. The callee now asks the server to HOLD its GET open
// and answer the instant somebody rings.
//
// The dangerous bugs here are all shaped like the ones above: quiet, and
// indistinguishable from "nobody is calling".
//
//   - (m2) a poll asked to wait comes back with `park` and an EMPTY body. That
//     is on purpose and is asserted as a property: a Durable Object that
//     forgot to honour `park` would otherwise send a perfectly well-formed
//     "no rings" and the feature would silently be a 25-second poll.
//   - (m3/m4) `waitedMs` is present exactly when the caller asked to wait, and
//     ABSENT otherwise. That field is the client's only positive evidence that
//     the far side understands waiting — an older worker ignores an unknown
//     query parameter in silence, which is indistinguishable from a fast new
//     one. (m4) compares a plain poll's body key for key against the shape that
//     shipped, because an old client must keep working against this server.
//   - (m5) is the drain-then-refuse bug, and it is the one that would lose real
//     calls. The drain is destructive; a rate check placed after it throws a
//     ring away on the way to answering 429. So a ring already in the mailbox
//     must be delivered EVEN WHEN THE ARMING WINDOW IS EXHAUSTED, and (m5)
//     proves both halves — the same exhausted window refuses an empty poll.
//   - (m7) the concurrency cap answers 200, never 429. A 429 there reads as
//     "no ring" to anything that does not parse it, and this endpoint's failure
//     mode is a missed call.
//   - (m9) a silenced ring does not count as something to deliver. If it did,
//     a caller ringing a silenced handle could end the callee's wait over and
//     over — denial of sleep rebuilt out of the silence switch.
{
  sec('(m) the held poll: parking, and the ways it must not lose a ring');
  // Not exported, for the reason in the (j4) block: worker.ts is the worker
  // ENTRY module and workerd refuses to start when a named export is not a
  // function or an ExportedHandler. Read out of the source, like the context
  // strings above.
  const numOf = (name) => {
    const m = srcText.match(new RegExp(`const ${name} = ([0-9_]+)`));
    return m ? Number(m[1].replace(/_/g, '')) : null;
  };
  const MAXPARKED = numOf('KIN_WAIT_MAX_PARKED');
  const WAITGAP = numOf('KIN_WAIT_GAP_MS');
  const MAXWAIT = numOf('KIN_WAIT_MAX_MS');
  const MINWAIT = numOf('KIN_WAIT_MIN_MS');
  ok(MAXPARKED && WAITGAP && MAXWAIT && MINWAIT, '(m0) the four wait constants are readable from the source');

  // ── (m1) the ruler: known inputs, including two that MUST rank differently ─
  for (const [raw, want] of [
    [null, 0], ['', 0], ['abc', 0], ['-1', 0], ['0', 0], ['NaN', 0], ['Infinity', 0],
    [String(MINWAIT - 1), 0],          // below the floor is NOT a wait
    [String(MINWAIT), MINWAIT],        // ...and the floor itself IS one
    ['25000', 25000],
    ['25000.7', 25000],                // floored, never fractional ms
    [String(MAXWAIT * 1000), MAXWAIT], // clamped at the top, not merely floored
  ]) {
    eq(kinWaitMs(raw), want, `(m1) kinWaitMs(${JSON.stringify(raw)}) is ${want}`);
  }

  // ── (m2) an empty mailbox parks, with nothing in the body ─────────────────
  {
    const s = fresh();
    const d = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW, null, 0, 25000, 0);
    eq(d.status, 200, '(m2) a waiting poll on an empty mailbox is a 200');
    eq(d.park, true, '(m2) and is marked for the DO to hold');
    deep(d.body, {}, '(m2) with an EMPTY body — a DO that ignored `park` must not send a plausible "no rings"');
    ok(!('rings' in d.body), '(m2) and no `rings` key at all, so it cannot be read as an empty mailbox');
  }

  // ── (m3) a mailbox with something in it answers at once, and says it waited ─
  {
    const s = fresh();
    put(s, {});
    const d = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW, null, 0, 25000, 0);
    eq(d.status, 200, '(m3) a waiting poll with a ring waiting answers at once');
    eq(d.park, undefined, '(m3) and does not park');
    eq(d.body.rings.length, 1, '(m3) handing over the ring');
    eq(d.body.waitedMs, 0, '(m3) and reporting that it waited no time — the field is the client\'s proof this server holds');
  }

  // ── (m4) THE OLD CLIENT'S POLL IS UNCHANGED ───────────────────────────────
  // Key for key against the shape that shipped. Two ends of a call update
  // independently, so an old Mac must keep working against this worker.
  {
    const s = fresh();
    const d = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW);
    deep(Object.keys(d.body).sort(), ['leaseMs', 'pollMs', 'quiet', 'rings', 'to'],
      '(m4) a poll with no `wait` has exactly the keys it always had');
    ok(!('waitedMs' in d.body), '(m4) and NO waitedMs — its absence is what tells an old client nothing changed');
    eq(d.body.pollMs, 5000, '(m4) and it is still told to come back in 5 s');
    // The same request with wait= differs by exactly one key and nothing else.
    const s2 = fresh();
    const w = kinPollDecide(TO, TOK, TOK, s2.box, s2.hits, NOW, null, 0, 25000, MAXPARKED);
    deep(Object.keys(w.body).sort(), ['leaseMs', 'pollMs', 'quiet', 'rings', 'to', 'waitedMs'],
      '(m4) and a waiting poll differs from it by exactly one added key');
  }

  // ── (m5) THE DRAIN IS DESTRUCTIVE, SO THE RATE CHECK LOOKS FIRST ──────────
  {
    const s = fresh();
    // Exhaust the arming window on an empty mailbox.
    const first = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW, null, 0, 25000, 0);
    eq(first.park, true, '(m5) the first waiting poll parks');
    const refused = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 10, null, 0, 25000, 0);
    eq(refused.status, 429, '(m5) a second one 10 ms later is refused — the window is real');
    eq(refused.body.retryMs, WAITGAP, '(m5) and says how long to wait, so the client does not guess');
    // NOW a ring lands, and the window is still shut.
    put(s, {}, NOW + 20);
    const delivered = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 30, null, 0, 25000, 0);
    eq(delivered.status, 200,
      '(m5) a poll inside the SAME shut window is NOT refused when a ring is waiting');
    eq(delivered.body.rings.length, 1, '(m5) and the ring is handed over rather than thrown away');
    // And the refusal really did leave the mailbox alone: the ring above was put
    // after the 429, so prove the non-destructive half directly.
    const s2 = fresh();
    put(s2, {});
    ok(kinBoxHas(s2.box, TO, NOW), '(m5) kinBoxHas sees a live ring');
    eq(s2.box.get(TO)?.length, 1, '(m5) and LOOKING DID NOT TAKE IT — a peek that drained would lose the call it refused');
  }

  // ── (m6) a poll that delivered costs no arming budget ─────────────────────
  // Without this the ordinary path — ring lands, client comes straight back —
  // is a 429 every single time, and the second of two rings 300 ms apart waits
  // out a backoff for no reason.
  {
    const s = fresh();
    put(s, { from: handle(1) });
    eq(kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW, null, 0, 25000, 0).body.rings.length, 1,
      '(m6) the first waiting poll delivers');
    put(s, { from: handle(2) }, NOW + 5);
    const again = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 6, null, 0, 25000, 0);
    eq(again.status, 200, '(m6) and a second one 6 ms later is allowed, because the first one did work');
    eq(again.body.rings.length, 1, '(m6) delivering the second ring immediately');
    // CONTROL, or "the window works" is indistinguishable from no window at all.
    const empty = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 7, null, 0, 25000, 0);
    eq(empty.park, true, '(m6) CONTROL: the next empty one parks (it is the first unproductive arming)');
    eq(kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 8, null, 0, 25000, 0).status, 429,
      '(m6) CONTROL: and the one after that is refused — unproductive armings ARE charged');
  }

  // ── (m7) at the concurrency cap: answer, never refuse ─────────────────────
  {
    const s = fresh();
    const d = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW, null, 0, 25000, MAXPARKED);
    eq(d.status, 200, '(m7) a waiting poll above the parked cap is answered, not refused');
    eq(d.park, undefined, '(m7) and is not parked');
    eq(d.body.rings.length, 0, '(m7) with a real, parseable empty mailbox');
    eq(d.body.waitedMs, 0, '(m7) still saying this server holds — the client must not fall back over a busy moment');
    const under = kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + WAITGAP + 1, null, 0, 25000, MAXPARKED - 1);
    eq(under.park, true, '(m7) CONTROL: one below the cap still parks');
  }

  // ── (m8) the two windows cannot spend each other ──────────────────────────
  {
    const s = fresh();
    kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW, null, 0, 25000, 0);      // charges wait:
    eq(kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 10, null, 0, 25000, 0).status, 429,
      '(m8) the arming window is spent');
    eq(kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW + 10).status, 200,
      '(m8) and a plain poll still goes through — an old client cannot be locked out by a new one');
    const s2 = fresh();
    kinPollDecide(TO, TOK, TOK, s2.box, s2.hits, NOW);                        // charges poll:
    eq(kinPollDecide(TO, TOK, TOK, s2.box, s2.hits, NOW + 10).status, 429, '(m8) the plain window is spent');
    eq(kinPollDecide(TO, TOK, TOK, s2.box, s2.hits, NOW + 10, null, 0, 25000, 0).park, true,
      '(m8) and a waiting poll still parks — a new client cannot be locked out by an old one');
  }

  // ── (m9) a silenced ring is not something to deliver ──────────────────────
  {
    const s = fresh();
    kinBoxPut(s.box, { ...JSON.parse(ring()), t: T }, NOW, true);   // muted
    ok(!kinBoxHas(s.box, TO, NOW), '(m9) a silenced ring does not count as something waiting');
    eq(kinPollDecide(TO, TOK, TOK, s.box, s.hits, NOW, null, 0, 25000, 0).park, true,
      '(m9) so a waiting poll still parks rather than ending to hand over nothing');
    // CONTROL: the same ring, not silenced, does count.
    const s2 = fresh();
    kinBoxPut(s2.box, { ...JSON.parse(ring()), t: T }, NOW, false);
    ok(kinBoxHas(s2.box, TO, NOW), '(m9) CONTROL: a live ring does count');
    // And an expired one does not, whatever its mute bit says.
    eq(kinBoxHas(s2.box, TO, NOW + 61_000), false, '(m9) an expired ring does not count either');
  }
}

// ── (i) TURN: which UDP port the app is told to use ───────────────────────
{
  const cf = (ports, user = 'u') => [{
    urls: [
      'stun:stun.cloudflare.com:3478',
      ...ports.map((p) => `turn:turn.cloudflare.com:${p}?transport=udp`),
      'turns:turn.cloudflare.com:5349?transport=tcp',
      'turn:turn.cloudflare.com:80?transport=tcp',
    ],
    username: user, credential: 'c',
  }];

  // (i0) Prove the OLD code really was broken, or "the new one works" proves
  // nothing about what it fixed. This is the exact loop that shipped.
  sec('(n) THE HANG-UP: one envelope, the opposite news');
  // Measured on a real call, and it was the loudest complaint about the whole
  // feature: cancel a call and the other Mac "just kept showing calling
  // forever". There was no un-ring to send. This is it -- the same signed
  // envelope with `kind: "bye"` on it, which travels the same mailbox, wakes the
  // same held poll, and is dropped by any client that does not recognise it.
  //
  // The pairs that MUST be ranked differently, or this is a one-sided test:
  //   · kind "bye" is accepted AND kind "hangup" is refused. A closed set that
  //     accepted anything would let an unknown word reach a client that has no
  //     idea what to do with it.
  //   · a bye IS delivered to a silent handle AND an ordinary ring is NOT. One
  //     without the other is either a silence switch that leaks calls or a
  //     caller who never learns they were declined.
  //   · a bye does NOT spend the ring budget AND is still bounded by its own.
  {
    const bye = (over = {}) => ring({ kind: 'bye', ...over });
    const s0 = fresh();
    const d0 = kinRingDecide(bye(), TO, s0.box, s0.hits, NOW);
    console.log(`  kind bye     -> ${d0.status} ${JSON.stringify(d0.body)}`);
    eq(d0.status, 200, '(n) a bye is accepted');
    for (const bad of ['hangup', 'BYE', 'bye ', '', 'ring']) {
      eq(kinRingDecide(bye({ kind: bad }), TO, fresh().box, fresh().hits, NOW).status, 400,
        `(n) kind ${JSON.stringify(bad)} is not a word this server knows`);
    }
    eq(kinRingDecide(bye({ kind: 5 }), TO, fresh().box, fresh().hits, NOW).status, 400,
      '(n) nor is a number');
    eq(kinRingDecide(bye({ kind: null }), TO, fresh().box, fresh().hits, NOW).status, 400,
      '(n) nor null -- absent means absent, and JSON null is a value');
    // Every other rule still applies to it. A `kind` is not a bypass.
    eq(kinRingDecide(bye({ t: T + 61 }), TO, fresh().box, fresh().hits, NOW).status, 400,
      '(n) a bye is skew-checked like anything else');
    eq(kinRingDecide(bye({ from: TO }), TO, fresh().box, fresh().hits, NOW).status, 400,
      '(n) and cannot be sent to yourself');
    eq(kinRingDecide(bye({ room: 'short' }), TO, fresh().box, fresh().hits, NOW).status, 400,
      '(n) and still needs a real room');
    eq(kinRingDecide(JSON.stringify({ to: TO, from: FROM, room: ROOM, t: T, sig: SIG, kind: 'bye' }),
      TO, fresh().box, fresh().hits, NOW).status, 400,
      '(n) and `kind` does not substitute for a required field');

    // ── IT REACHES THE CLIENT, with the word intact ─────────────────────────
    const s1 = fresh();
    put(s1, { kind: 'bye' });
    const body1 = kinPollBody(TO, s1.box, NOW, null, 0);
    console.log(`  polled: ${JSON.stringify(body1.rings)}`);
    eq(body1.rings.length, 1, '(n) a poll hands the bye over');
    eq(body1.rings[0].kind, 'bye', '(n) with `kind` still on it -- a field dropped in transit does nothing at all');
    // CONTROL: an ordinary ring carries NO kind key at all, not kind:null. A
    // Swift decoder reading `nil` and a JSON `null` are the same thing here, but
    // the shape on the wire is what an older client parses.
    const s1b = fresh();
    put(s1b);
    const plain = kinPollBody(TO, s1b.box, NOW, null, 0).rings[0];
    ok(!('kind' in plain), '(n) CONTROL: an ordinary ring is shaped exactly as it was before byes existed');

    // ── A CANCEL THAT ARRIVES BEFORE THE FIRST POLL REPLACES THE RING ──────
    // kinBoxPut replaces on (from, room), which is what makes this work: a
    // caller who rings and immediately cancels leaves ONE entry saying "bye",
    // not a ring the callee is about to be shown for a call nobody is on.
    const s2 = fresh();
    put(s2);
    const rep = put(s2, { kind: 'bye' }, NOW + 500);
    console.log(`  ring then bye, unpolled: queued ${rep.body.queued}, replaced in place`);
    eq(rep.body.queued, 1, '(n) the bye takes the ring\'s slot rather than queueing behind it');
    const after = kinPollBody(TO, s2.box, NOW + 600, null, 0).rings;
    eq(after.length, 1, '(n) so the callee is handed one message');
    eq(after[0].kind, 'bye', '(n) and it is the hang-up, not a phantom ring');

    // ── SILENT MODE: the pair that has to be ranked differently ────────────
    const QON = { quiet: true, until: 0, exceptKnown: false, at: NOW };
    ok(kinQuietActive(QON, NOW), '(n) setup: the row reads as silent');
    const sq = fresh();
    kinRingDecide(ring(), TO, sq.box, sq.hits, NOW, QON);
    eq(kinPollBody(TO, sq.box, NOW, QON, 0).rings.length, 0,
      '(n) a RING to a silent handle is swallowed, exactly as before');
    const sq2 = fresh();
    const dq = kinRingDecide(bye(), TO, sq2.box, sq2.hits, NOW, QON);
    ok(!dq.muted, '(n) a BYE to a silent handle is not marked muted');
    // BEFORE the poll, because kinPollBody DRAINS. Asked in this order the first
    // time round and it read false for a bye that was sitting right there --
    // the mailbox was empty because the assertion above had just emptied it.
    ok(kinBoxHas(sq2.box, TO, NOW), '(n) it counts as something to hand over, so a held poll wakes for it');
    eq(kinPollBody(TO, sq2.box, NOW, QON, 0).rings.length, 1,
      '(n) and is delivered -- silence stops you being called, not being told a call ended');
    const sq3 = fresh();
    kinRingDecide(ring(), TO, sq3.box, sq3.hits, NOW, QON);
    ok(!kinBoxHas(sq3.box, TO, NOW), '(n) CONTROL: a silenced ring still wakes nothing');

    // ── THE BUDGETS ARE SIBLINGS ───────────────────────────────────────────
    // Four calls placed and four cancelled inside a minute. If the bye were
    // charged to the ring window the fourth call could not be placed, and if
    // rings were charged to the bye window the fourth cancel would be lost.
    const sb = fresh();
    let rings = 0, byes = 0;
    for (let i = 0; i < 4; i++) {
      if (put(sb, { room: ROOM + i }, NOW + i * 2).status === 200) rings++;
      if (put(sb, { room: ROOM + i, kind: 'bye' }, NOW + i * 2 + 1).status === 200) byes++;
    }
    console.log(`  four call-and-cancel pairs in one minute: ${rings} rings, ${byes} byes`);
    eq(rings, 4, '(n) all four rings land');
    eq(byes, 4, '(n) and all four byes land -- a hang-up is not charged to the doorbell');
    // And the bye window is a real window: the fifth is refused, so a bye flood
    // is bounded exactly as tightly as a ring flood.
    eq(put(sb, { room: ROOM + 'x', kind: 'bye' }, NOW + 20).status, 429,
      '(n) the fifth bye in a minute is refused');
    eq(put(sb, { room: ROOM + 'x' }, NOW + 21).status, 429,
      '(n) CONTROL: and so is the fifth ring, on its own window');
    eq(put(sb, { room: ROOM + 'y', kind: 'bye', t: T + 61 }, NOW + 61_000).status, 200,
      '(n) and the bye window reopens rather than being a ban');

    // The hourly denial-of-sleep bound must be UNCHANGED by byes existing: the
    // honest caller who cancels must not run out of rings sooner than a flooder
    // who never does.
    const sh = fresh();
    let landed = 0;
    for (let i = 0; i < 60; i++) {
      const at = NOW + i * 6000, ts = T + i * 6;
      kinRingDecide(JSON.stringify({ to: TO, from: handle(600 + i), room: ROOM + (i % 7),
        t: ts, sig: SIG, k: kk(600 + i), kind: 'bye' }), TO, sh.box, sh.hits, at);
      if (kinRingDecide(JSON.stringify({ to: TO, from: handle(600 + i), room: ROOM + (i % 7),
        t: ts, sig: SIG, k: kk(600 + i) }), TO, sh.box, sh.hits, at + 1).status === 200) landed++;
    }
    console.log(`  sixty rings in an hour, each preceded by a bye: ${landed} landed`);
    eq(landed, 60, '(n) sixty rings an hour still, byes or no byes');
  }

  sec('(i0) the loop this replaced picked whatever Cloudflare listed LAST');
  const oldPick = (iceServers) => {
    let host = '', port = 3478;
    for (const s of iceServers ?? []) {
      const urls = Array.isArray(s.urls) ? s.urls : s.urls ? [s.urls] : [];
      for (const u of urls) {
        if (typeof u !== 'string' || !u.startsWith('turn:')) continue;
        if (u.includes('transport=tcp')) continue;
        const hp = u.slice(5).split('?')[0];
        const colon = hp.lastIndexOf(':');
        if (colon < 0) continue;
        host = hp.slice(0, colon);
        port = parseInt(hp.slice(colon + 1), 10) || 3478;
      }
    }
    return { host, port };
  };
  console.log(`  old code on [3478,443,53] -> port ${oldPick(cf([3478, 443, 53])).port}`);
  eq(oldPick(cf([3478, 443, 53])).port, 53, '(i0) the old loop shipped :53');
  eq(oldPick(cf([53, 443, 3478])).port, 3478, '(i0) and would have shipped :3478 on a reordered list — UNPINNED');

  sec('(i) turnOrderUdp: 3478 preferred, fallbacks kept, order irrelevant');
  for (const [ports, wantPort, wantList, why] of [
    [[3478, 443, 53], 3478, [3478, 443, 53], '3478 listed FIRST (a reversed sort would fail here)'],
    [[53, 443, 3478], 3478, [3478, 443, 53], '3478 listed LAST — the case that shipped :53'],
    [[443, 3478, 53], 3478, [3478, 443, 53], '3478 in the middle'],
    [[443, 53], 443, [443, 53], '3478 ABSENT — proves a preference, not a hardcode'],
    [[53], 53, [53], 'only 53 — the fallback is kept, never deleted'],
    [[443], 443, [443], 'only 443'],
  ]) {
    const p = turnOrderUdp(cf(ports));
    console.log(`  ${JSON.stringify(ports).padEnd(20)} -> port ${String(p?.port).padEnd(5)} ports ${JSON.stringify(p?.ports).padEnd(18)} ${why}`);
    eq(p?.port, wantPort, `(i) ${why}`);
    deep(p?.ports, wantList, `(i) ordered fallbacks for ${JSON.stringify(ports)}`);
    eq(p?.host, 'turn.cloudflare.com', '(i) host carried through');
    eq(p?.username, 'u', '(i) credential carried through');
    eq(p?.credential, 'c', '(i) and its secret');
  }

  sec('(i2) turnOrderUdp: nothing usable means p2pOnly, never a guess');
  eq(turnOrderUdp(cf([])), null, '(i2) no UDP relay at all');
  eq(turnOrderUdp([]), null, '(i2) an empty server list');
  eq(turnOrderUdp(undefined), null, '(i2) a response with no iceServers');
  eq(turnOrderUdp([{ urls: ['turns:turn.cloudflare.com:5349?transport=tcp'] }]), null, '(i2) TCP/TLS only — the app has no TCP relay path');
  eq(turnOrderUdp([{ urls: ['stun:stun.cloudflare.com:3478'], username: 'u' }]), null, '(i2) STUN is not a relay');
  eq(turnOrderUdp([{ urls: ['turn:turn.cloudflare.com:3478?transport=udp'], credential: 'c' }]), null,
    '(i2) a relay with no username is not a relay');
  eq(turnOrderUdp([{ urls: 'turn:turn.cloudflare.com:3478?transport=udp', username: 'u', credential: 'c' }])?.port,
    3478, '(i2) a bare string urls field (not an array) still parses');
  eq(turnOrderUdp([{ urls: ['turn:turn.cloudflare.com:notaport?transport=udp'], username: 'u' }]), null, '(i2) an unparseable port');
  eq(turnOrderUdp([{ urls: ['turn:turn.cloudflare.com:99999?transport=udp'], username: 'u' }]), null, '(i2) a port out of range');

  sec('(i3) unranked ports keep Cloudflare\'s own order rather than being shuffled');
  const un = turnOrderUdp(cf([9991, 9992]));
  console.log(`  [9991,9992] -> port ${un?.port} ports ${JSON.stringify(un?.ports)}`);
  eq(un?.port, 9991, '(i3) the first unranked port wins');
  deep(un?.ports, [9991, 9992], '(i3) stable — equal rank falls back to arrival order');
  const mixed = turnOrderUdp(cf([9991, 53, 9992, 3478]));
  deep(mixed?.ports, [3478, 53, 9991, 9992], '(i3) ranked ports first, then the rest in arrival order');
}

// ── (j) the mistakes no functional test can see ───────────────────────────
// A handler after the signal() fallthrough answers 426 and looks like a client
// bug; a mailbox write that stamps the operator room registry works perfectly
// while leaking; and a register handler that never persists `putKey` leaves
// first-writer-wins permanently disengaged while every assertion in (g) passes.
{
  sec('(j) source-level guards');
  const src = readFileSync(join(here, 'src/worker.ts'), 'utf8');

  const iReg = src.indexOf("endsWith('/kin/register')");
  const iRing = src.indexOf("endsWith('/kin/ring')");
  const iPoll = src.indexOf("endsWith('/kin/poll')");
  const iQuiet = src.indexOf("endsWith('/kin/quiet')");
  const iSignal = src.indexOf('return this.signal(request);');
  ok(iReg > 0 && iRing > 0 && iPoll > 0 && iQuiet > 0, '(j) all four doorbell verbs are dispatched in Room.fetch');
  ok(iSignal > 0, '(j) the signal() fallthrough is where it was');
  for (const [name, i] of [['register', iReg], ['ring', iRing], ['poll', iPoll], ['quiet', iQuiet]]) {
    ok(i < iSignal, `(j) /kin/${name} dispatches BEFORE signal() — after it, signal() answers 426 and the route is inert`);
  }
  console.log(`  dispatch at ${iReg}/${iRing}/${iPoll}/${iQuiet}, signal() fallthrough at ${iSignal}`);

  // The room-seen stamp fires from exactly two places, and neither is reachable
  // from a doorbell path. If a third appears, a human should look at it.
  const stamps = src.match(/https:\/\/do\/room-seen/g) ?? [];
  console.log(`  room-seen stamp call sites: ${stamps.length}`);
  eq(stamps.length, 2, '(j) exactly two room-seen stamps (hold-join admission, and the /api/room/ edge match)');

  // The doorbell's own code must not contain one.
  const edgeStart = src.indexOf('const kin = url.pathname.match(KIN_ROUTE_RE);');
  const edgeEnd = src.indexOf('// /api/room/:code/ws');
  ok(edgeStart > 0 && edgeEnd > edgeStart, '(j) the doorbell edge block is locatable');
  const edgeBlock = src.slice(edgeStart, edgeEnd);
  ok(!edgeBlock.includes('room-seen'), '(j) the edge doorbell block never stamps the room registry');
  ok(!edgeBlock.includes('HEALTH'), '(j) and never touches the Health DO at all');
  ok(edgeBlock.includes('kinPosts'), '(j) it rate limits on the sibling map');
  for (const other of ['macPosts', 'hbPosts', 'iceMints']) {
    ok(!edgeBlock.includes(other), `(j) and NOT on ${other} — telemetry and rings must not share a budget`);
  }

  const doStart = src.indexOf('private kinTok');
  const doEnd = src.indexOf('private rvPeers');
  ok(doStart > 0 && doEnd > doStart, '(j) the doorbell DO methods are locatable');
  const doBlock = src.slice(doStart, doEnd);
  ok(!doBlock.includes('room-seen'), '(j) the in-DO doorbell handlers never stamp the room registry either');
  ok(!doBlock.includes('this.roomCode'), '(j) and never read the room code');

  sec('(j2) the register handler really persists the KEY');
  // THE BUG THIS CATCHES AND NOTHING ELSE CAN: kinRegisterDecide can return a
  // flawless `putKey` and the DO can drop it on the floor. Then `haveKey` is
  // forever null, every register is `fresh`, and the squat check in (g3) never
  // runs in production — while every assertion in (g) still passes, because (g)
  // drives its own store. This is the "declared but never wired" shape.
  ok(doBlock.includes('d.putKey'), '(j2) the DO reads d.putKey out of the decision');
  ok(doBlock.includes("'kin_key'") || doBlock.includes('kin_key'), '(j2) and names the kin_key row');
  ok(/row\.kin_key\s*=\s*d\.putKey/.test(doBlock), '(j2) and puts it in the row it writes');
  ok(/row\.kin_tok\s*=\s*d\.put\b/.test(doBlock), '(j2) alongside the credential row');
  ok(/this\.kinKey\s*=\s*d\.putKey/.test(doBlock), '(j2) and refreshes its own cache, or the next register reads a stale null');
  ok(doBlock.includes('kinKeyLoad'), '(j2) and the handler actually LOADS the stored key before deciding');
  ok(/haveKey/.test(doBlock), '(j2) and passes it to kinRegisterDecide as haveKey');
  // ONE batched write, IN THE REGISTER HANDLER. Two separate puts there could
  // land the credential without the key that owns it — which is exactly the
  // legacy shape (g6) has to distrust. Scoped to the handler rather than to the
  // whole doorbell block, because the silent-mode toggle writes its own row and
  // a count over the block would have to be relaxed every time a row is added —
  // which is how a real guarantee decays into a number nobody trusts.
  const method = (name, nextMarker) => {
    const a = src.indexOf(`private async ${name}(`);
    const b = src.indexOf(nextMarker, a + 1);
    ok(a > 0 && b > a, `(j2) the ${name} handler is locatable`);
    return src.slice(a, b);
  };
  const regHandler = method('kinRegister', 'private async kinRing(');
  const regPuts = regHandler.match(/this\.state\.storage\.put\(/g) ?? [];
  console.log(`  storage.put call sites in kinRegister: ${regPuts.length}`);
  eq(regPuts.length, 1, '(j2) exactly one storage.put in kinRegister, so tok and key land together or not at all');
  const gets = doBlock.match(/this\.state\.storage\.get<[A-Za-z]+>\('kin_(tok|key|quiet)'\)/g) ?? [];
  console.log(`  durable rows the doorbell reads: ${gets.join(', ')}`);
  eq(gets.length, 3, '(j2) three durable rows read, kin_tok, kin_key and kin_quiet — the only state this feature adds');

  sec('(j3) skew is checked before the signature IN THE SOURCE too');
  // (g4) proves it behaviourally with a counting verifier. This proves it
  // textually, so the guarantee survives someone deleting the counter.
  const fnStart = src.indexOf('export async function kinRegisterDecide(');
  // Ends at the NEXT function, not at the edge-limits block: kinQuietDecide now
  // sits between them and has its own copy of this guard in (j4).
  const fnEnd = src.indexOf('export async function kinQuietDecide(', fnStart);
  ok(fnStart > 0 && fnEnd > fnStart, '(j3) kinRegisterDecide is locatable');
  const fn = src.slice(fnStart, fnEnd);
  const iSkew = fn.indexOf('KIN_SKEW_S');
  const iVerify = fn.indexOf('await verify(');
  console.log(`  in kinRegisterDecide: skew gate at ${iSkew}, verify() at ${iVerify}`);
  ok(iSkew > 0, '(j3) the skew gate is there at all');
  ok(iVerify > 0, '(j3) and so is the signature check');
  ok(iSkew < iVerify, '(j3) and skew comes FIRST — a replay must expire before it costs us a curve op');
  // The rate window, too: an unauthenticated endpoint must not do its most
  // expensive work before its cheapest limit.
  ok(fn.indexOf('kinWindow(') < iVerify, '(j3) and the rate window is spent before the signature check');
  // And the server must NOT verify a ring. If `verify` ever appears in
  // kinRingDecide, someone has turned a mailbox into an identity authority.
  const rStart = src.indexOf('export function kinRingDecide(');
  const rEnd = src.indexOf('export function kinPollDecide(');
  const ringFn = src.slice(rStart, rEnd);
  ok(rStart > 0 && rEnd > rStart, '(j3) kinRingDecide is locatable');
  // Matched as CALL SYNTAX, not as prose: the function's own comments say the
  // words "verify" and "decode", and a substring test would fail on the
  // documentation that exists to prevent the very change it is guarding.
  ok(!/\bverify\s*\(/.test(ringFn), '(j3) kinRingDecide calls no verifier — the callee does, by design');
  ok(!ringFn.includes('crypto.subtle'), '(j3) and touches no crypto at all');
  ok(!/kinB64\s*\(/.test(ringFn), '(j3) and does not even decode `k` — it checks the shape and stores it');

  // ── (j4) SILENT MODE, and the one mistake no functional test can catch ────
  //
  // (l1) proves a silent handle and an absent one answer identically for one
  // seventeen-ring script. It cannot prove there is no SECOND response site that
  // some future script would reach. That is a source fact, so it is checked here.
  sec('(j4) silent mode: one response site, and the toggle read from the stored key');
  // Comments stripped FIRST. These are counts of code, and a comment that
  // quotes a response body is not a second response site -- the block above the
  // 200 in kinRingDecide quotes `{ok: true, queued: 1}` to explain the outage it
  // was written for, and without this line that quotation fails the test it is
  // documenting. Same trap as (j3) above, which matches call syntax rather than
  // prose for exactly this reason.
  const ringCode = ringFn
    .replace(/\/\*[\s\S]*?\*\//g, '')      // block comments
    .replace(/(^|[^:])\/\/[^\n]*/g, '$1');  // line comments, sparing `://` in a URL
  const ring200 = ringCode.match(/status: 200/g) ?? [];
  eq(ring200.length, 1,
    '(j4) kinRingDecide has exactly ONE 200 response site — an early return for the silent case is how `queued` starts lying');
  const queuedLit = ringCode.match(/queued:/g) ?? [];
  eq(queuedLit.length, 1, '(j4) and `queued` is built in exactly one place');
  // The body at the ONE 200 site, not the first `body:` in the function (which is
  // a 400). Anchored on the status so it cannot drift onto an error path.
  const bodyLit = (() => {
    const from = ringCode.slice(ringCode.indexOf('status: 200'));
    const at = from.indexOf('body: {');
    if (at < 0) return '';
    // Brace-balanced, because the body now contains a nested spread and a regex
    // that stops at the first `}` would print half of it and look complete.
    let depth = 0;
    for (let i = at + 6; i < from.length; i++) {
      if (from[i] === '{') depth++;
      else if (from[i] === '}' && --depth === 0) return from.slice(at, i + 1).replace(/\s+/g, ' ');
    }
    return '';
  })();
  console.log(`  the single ring body: ${bodyLit}`);
  ok(bodyLit.includes('r.queued'), '(j4) and it comes from the store, not from a literal');
  ok(!bodyLit.includes('muted'), '(j4) and the silenced flag is NOT in it — that flag is the toggle, in the clear');

  // The silence check is the LAST gate. Any earlier and a silent handle stops
  // charging and refusing on the rate windows, which is legible from outside.
  const iActive = ringFn.indexOf('kinQuietActive(');
  const iLastWindow = ringFn.lastIndexOf('kinWindow(');
  const iBoxPut = ringFn.indexOf('kinBoxPut(');
  console.log(`  in kinRingDecide: last rate window ${iLastWindow}, silence check ${iActive}, store ${iBoxPut}`);
  ok(iActive > 0, '(j4) kinRingDecide consults the toggle at all — otherwise the whole feature is a dead control');
  ok(iActive > iLastWindow, '(j4) AFTER every rate window: a silent handle must still spend budget and still say 429');
  ok(iActive < iBoxPut, '(j4) and before the store, which is what marks the ring');

  // The DO half. A pure function that reads a toggle nobody loads is the
  // "declared but never wired" shape this project has shipped three times.
  const ringHandler = method('kinRing', 'private async kinPoll(');
  ok(/await this\.kinQuietLoad\(\)/.test(ringHandler), '(j4) the DO LOADS the toggle on the ring path');
  ok(ringHandler.indexOf('kinQuietLoad') < ringHandler.indexOf('kinRingDecide('),
    '(j4) before it decides, and passes it in');
  ok(/kinRingDecide\([\s\S]*quiet[\s\S]*\)/.test(ringHandler), '(j4) as the sixth argument');
  eq((ringHandler.match(/\bif \(/g) ?? []).length, 3,
    '(j4) and the only branches in kinRing are the method check, the mute counter and the wake — the load is unconditional, so a silent handle costs the same read as a live one');
  // ── THE WAKE, and the two things that must be true of it ──────────────────
  // The doorbell is what releases a held poll, so this line is the whole
  // latency win. It must be gated on `!d.muted` — a silenced ring that woke a
  // waiter would end the callee's wait to hand them nothing, and a caller who
  // kept ringing a silenced handle could keep ending it, which is denial of
  // sleep rebuilt out of the silence switch. And it must come AFTER the
  // decision, or it is a branch that can change what the caller is told and the
  // indistinguishability the whole (l) section proves is gone.
  ok(/if \(d\.status === 200 && !d\.muted\) this\.kinWake\(/.test(ringHandler),
    '(j4) the wake fires only for a ring that will actually be handed over');
  ok(ringHandler.indexOf('kinRingDecide(') < ringHandler.indexOf('this.kinWake('),
    '(j4) and only after the response has been decided, so it cannot change it');
  ok(!/headers/.test(ringHandler),
    '(j4) the handler sets no headers of its own, so both paths get json()\'s — identical, not merely similar');
  const quietHandler = method('kinQuietSet', 'private rendezvous(');
  ok(/kin_quiet/.test(quietHandler), '(j4) kinQuietSet names the kin_quiet row');
  ok(/this\.state\.storage\.put\('kin_quiet', d\.putQuiet\)/.test(quietHandler), '(j4) and writes what the decision returned');
  ok(/this\.kinQuiet = d\.putQuiet/.test(quietHandler),
    '(j4) and refreshes its own cache, or the next ring in this isolate rings a phone that was just silenced');
  ok(/await this\.kinKeyLoad\(\)/.test(quietHandler), '(j4) and verifies against the STORED key, which it loads');
  eq((quietHandler.match(/this\.state\.storage\.put\(/g) ?? []).length, 1, '(j4) one write, one row');
  const pollHandler = method('kinPoll', 'private async kinQuietSet(');
  ok(/kinQuietLoad\(\)/.test(pollHandler), '(j4) and poll reads the toggle back out for the owner');
  ok(/this\.kinMuted/.test(pollHandler), '(j4) along with the count of what was swallowed');
  ok(/if \(d\.muted\) this\.kinMuted\+\+/.test(ringHandler), '(j4) which the ring path is what increments');

  // ── (j5) THE HOLD, read out of the source ─────────────────────────────────
  //
  // (k3) proves the DO holds and wakes at runtime. These four read the things
  // that a passing runtime test would still be compatible with: a `park` the
  // handler quietly ignores, a hold with no deadline, and a cap that only ever
  // counts up. All three are invisible until the day they are not.
  ok(/if \(!d\.park\) return json\(/.test(pollHandler),
    '(j5) kinPoll HONOURS `park` — a handler that ignored it would answer a plausible "no rings" forever');
  ok(/await this\.kinHold\(/.test(pollHandler), '(j5) and holds the request itself');
  ok(/status: 204/.test(pollHandler), '(j5) answering 204 when the wait ran out');
  ok(/setTimeout\(\(\) => finish\(false\), waitMs\)/.test(pollHandler),
    '(j5) the hold has a DEADLINE, so a client that vanished costs one wait and not a leaked request');
  ok(/if \(done\) return;/.test(pollHandler),
    '(j5) and finishing is idempotent — a waiter woken and then timed out must not decrement the cap twice');
  eq((pollHandler.match(/this\.kinParked\+\+/g) ?? []).length, 1, '(j5) the parked count goes up in one place');
  eq((pollHandler.match(/this\.kinParked--/g) ?? []).length, 1, '(j5) and down in one place, which is that idempotent exit');

  // ── (j6) THE GHOST WAITER, which is the bug this design nearly shipped ─────
  //
  // The wake DRAINS, destructively. So a waiter belonging to a process that has
  // already been killed takes the ring, writes it to a socket nobody is reading,
  // and the listener that IS alive wakes to an empty mailbox. Measured: kill the
  // app mid-hold, ring the handle, and the menu-bar resident got nothing.
  //
  // Three lines hold the fix together and each is invisible at runtime when it
  // is wrong — a wake-all still passes every "the ring arrives" test as long as
  // exactly one listener exists.
  ok(/let newest: \(\(woke: boolean\) => void\) \| undefined;[\s\S]{0,160}newest\?\.\(true\)/.test(pollHandler),
    '(j6) a ring wakes exactly ONE waiter, the newest — waking two hands the ring to whichever resolves first and gives the other an empty box');
  ok(/if \(d\.status === 200\) this\.kinEvict\(to\)/.test(pollHandler),
    '(j6) an authenticated poll evicts the parked waiters, because it is the only client proven alive');
  ok(!/if \(d\.park\) this\.kinEvict|this\.kinEvict\(to\);\s*\n\s*const d =/.test(pollHandler),
    '(j6) and eviction is AFTER the credential check — otherwise anyone who knew a handle could keep evicting its waiter and make the doorbell slow');
  ok(/for \(const finish of \[\.\.\.set\]\) finish\(false\)/.test(pollHandler),
    '(j6) eviction finishes FALSE — `true` would turn the fix into the bug and every eviction would swallow a ring');
  ok(/this\.kinWaiters\.delete\(to\);\s*\n(\s*\/\/[^\n]*\n)*\s*for \(const finish of \[\.\.\.set\]\)/.test(pollHandler),
    '(j6) and snapshots the set before firing — each waiter removes itself, and iterating a mutating set skips waiters');

  // kinQuietDecide: the same order-of-checks law as register, plus the one that
  // is specific to this route — WHOSE key the proof is checked against.
  const qStart = src.indexOf('export async function kinQuietDecide(');
  const qEnd = src.indexOf('// ── Edge rate limits for the doorbell', qStart);
  ok(qStart > 0 && qEnd > qStart, '(j4) kinQuietDecide is locatable');
  const quietFn = src.slice(qStart, qEnd);
  const qSkew = quietFn.indexOf('KIN_SKEW_S');
  const qVerify = quietFn.indexOf('await verify(');
  const qWindow = quietFn.indexOf('kinWindow(');
  console.log(`  in kinQuietDecide: skew ${qSkew}, rate window ${qWindow}, verify() ${qVerify}`);
  ok(qSkew > 0 && qSkew < qVerify, '(j4) skew is checked before the signature here too');
  ok(qWindow > 0 && qWindow < qVerify, '(j4) and a rate window is spent before it');
  ok(/kinB64\(haveKey/.test(quietFn), '(j4) it DECODES THE STORED KEY');
  ok(/await verify\(stored,/.test(quietFn),
    '(j4) and verifies against those bytes — verifying against the presented key would let anybody silence anybody');
  ok(!/await verify\(pub/.test(quietFn), '(j4) never against the key in the request');
  ok(/kinB64Encode\(pub\) !== haveKey/.test(quietFn), '(j4) having first proved the presented key IS the stored one');
  ok(quietFn.includes('KIN_QUIET_CONTEXT'), '(j4) and signs under its own domain string');
  ok(!quietFn.includes('KIN_REG_CONTEXT'),
    '(j4) never under the register one — a signature valid for one operation must not be replayable as another');

  // Poll is where a silenced ring dies, and where the toggle is reported.
  const pollFn = src.slice(
    src.indexOf('export function kinPollDecide('),
    src.indexOf('// The exact fields a registration carries'),
  );
  ok(/\.filter\(\(r\) => !r\.mute\)/.test(pollFn), '(j4) poll drops silenced rings before the callee is handed anything');
  ok(/kinQuietActive\(/.test(pollFn), '(j4) and reports the READ-TIME verdict rather than the stored bit');

  // NO SWEEP, AND ONE INTERPRETER. A deadline read in two places is a deadline
  // with two answers, and an alarm that fails to fire leaves someone silently
  // unreachable — which is the failure this whole feature exists to avoid.
  const untilReads = src.match(/until \* 1000/g) ?? [];
  eq(untilReads.length, 1, '(j4) the deadline is interpreted in exactly one place, kinQuietActive');
  ok(!/setAlarm/.test(src), '(j4) and nothing schedules an alarm to expire it');

  // The contexts must not be exported. worker.ts is the worker ENTRY module, so a
  // named export is an entrypoint, and workerd refuses to start on a string one:
  // "Incorrect type for map entry 'KIN_REG_CONTEXT': the provided value is not of
  // type 'function or ExportedHandler'". That is a DEPLOY failure that typechecks
  // perfectly and that no pure test here can see. (k) caught it once; this makes
  // it cheap to catch again.
  ok(/^const KIN_REG_CONTEXT/m.test(src), '(j4) KIN_REG_CONTEXT is not exported — a string export stops workerd from starting');
  ok(/^const KIN_QUIET_CONTEXT/m.test(src), '(j4) nor is KIN_QUIET_CONTEXT');
  // ── A PRIMITIVE EXPORT IS A DEAD DEPLOY, NOT A FAILED TEST ───────────────
  //
  // This guarded single-quoted strings only, and a NUMBER walked straight past
  // it: `export const KIN_LISTEN_MS = 90_000` made the whole runtime refuse to
  // boot -- "Incorrect type for map entry 'KIN_LISTEN_MS': the provided value
  // is not of type 'function or ExportedHandler'". The workerd section below
  // caught it, which is the only reason it was a red test rather than a
  // production outage; a change that skipped that section would have shipped.
  //
  // So: refuse every primitive, not the one spelling that bit us first.
  // Regexes and objects stay allowed -- KIN_HANDLE_RE is exported and works,
  // because workerd only objects to values it cannot treat as an entrypoint.
  const badExports = src.match(/^export const [A-Z_][A-Z0-9_]* = (?:['"`]|-?\d|true\b|false\b)/gm) ?? [];
  eq(badExports.length, 0,
    `(j4) and no top-level PRIMITIVE is exported -- workerd will not start${badExports.length ? ': ' + badExports.join(', ') : ''}`);
}

// ── (l) a ring that goes nowhere should say so ──────────────────────────────
//
// The bug this is here for: on 2026-08-26 a Mac's login agent had been dead
// since the previous evening, and every ring aimed at it came back
// `{ok: true, queued: 1}` — the same bytes a ring at a wide-awake Mac returns.
// The caller had no way to tell "it is ringing" from "there is nobody there",
// so it showed a ringing screen for twenty hours' worth of calls into a house
// with nobody in it. Only the server can know this, so only the server can say.
{
  sec('(l) a ring reports whether the callee was still listening');
  const s = fresh();

  // UNKNOWN IS NOT NO. A Durable Object that has just woken has heard from
  // nobody at all, and answering "they are offline" there would be a confident
  // lie told to every caller after every eviction. The key must be ABSENT.
  const cold = kinRingDecide(ring(), TO, s.box, s.hits, NOW, null, null);
  eq(cold.status, 200, '(l) a ring is still accepted when liveness is unknown');
  eq('listening' in cold.body, false, '(l) unknown liveness omits the key entirely');

  const live = kinRingDecide(ring(), TO, fresh().box, fresh().hits, NOW, null, 0);
  eq(live.body.listening, true, '(l) a poll in flight reads as listening');

  const recent = kinRingDecide(ring(), TO, fresh().box, fresh().hits, NOW, null, 89_999);
  eq(recent.body.listening, true, '(l) heard from just inside the window: listening');

  // The arm that matters, and its neighbour one millisecond away. A threshold
  // tested only from the comfortable side is a threshold nobody has tested.
  const gone = kinRingDecide(ring(), TO, fresh().box, fresh().hits, NOW, null, 90_001);
  eq(gone.body.listening, false, '(l) heard from just outside it: NOT listening');

  const longGone = kinRingDecide(ring(), TO, fresh().box, fresh().hits, NOW, null, 20 * 3600 * 1000);
  eq(longGone.body.listening, false, '(l) twenty hours later: NOT listening — the real case');

  // A window that a resident cannot stay inside would mark healthy Macs dead.
  // The resident polls every 4 s, and holds for ~25 s when the server holds.
  const LISTEN_MS = Number((srcText
    .match(/const KIN_LISTEN_MS = ([0-9_]+)/) ?? [, '0'])[1].replace(/_/g, ''));
  eq(LISTEN_MS, 90_000, '(l) the window is the one written in worker.ts');
  ok(LISTEN_MS >= 60_000,
     `(l) the window (${LISTEN_MS} ms) is wider than a held poll plus a retry`);

  // And it must not change what a ring DOES. `listening` is a report, not a gate.
  eq(gone.body.ok, true, '(l) a ring at a silent Mac is still accepted and queued');
  eq(gone.body.queued >= 1, true, '(l) ...and still lands in the mailbox for when they return');
}

// ── (k) THE WHOLE THING, IN THE REAL RUNTIME ──────────────────────────────
//
// Everything above drives pure functions, and (g) drives a store that MIRRORS
// the Durable Object. A mirror can never catch the DO being wrong, and every
// interaction bug this project has shipped lived in exactly that gap — a
// callback declared and invoked but assigned nowhere, a control that drew and
// hovered and never fired. So this section runs the real worker in real workerd
// (the binary wrangler ships), through the real edge route, into the real DO,
// against real durable storage, using the runtime's own Ed25519.
//
// It is also the only test here that proves the ALGORITHM STRING is right.
// Node's WebCrypto and workerd's are different implementations; a registration
// that verifies in Node proves nothing about production. This one runs in the
// same runtime production does.
{
  sec('(k) end to end in real workerd: edge route -> DO -> durable storage');
  const { Miniflare } = await import('miniflare');
  // Miniflare 5 — which wrangler 4.121 hard-pins as a DIRECT dependency, so this
  // is not a resolution accident and cannot be dodged by a version bump —
  // dropped the flat single-worker options this section used to pass. The shape
  // below is the same three things declared the new way:
  //
  //   • the script    -> config.manifest, one ESM module, still read from the
  //                      esbuild bundle above so this can never run against a
  //                      frozen artifact.
  //   • the two DOs   -> a binding in config.env (which worker exports it) plus
  //                      an entry in config.exports (how it stores). `storage`
  //                      is REQUIRED there, so the SQLite backend cannot be
  //                      quietly lost the way the old optional `useSQLite: true`
  //                      could have been — dropping it is a startup error, not a
  //                      silent downgrade to the key-value backend.
  //   • the R2 bucket -> a `type: 'r2'` binding in config.env.
  //
  // `compatibilityDate` is camelCase here and snake_case in wrangler.jsonc; the
  // schema in node_modules/miniflare/dist/src/index.d.ts is the authority, and
  // an unexpected key is a hard validation error rather than a warning.
  const WORKER = 'tokkah-contacts-test';
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
        },
        exports: {
          Room: { type: 'durable-object', storage: 'sqlite' },
          Health: { type: 'durable-object', storage: 'sqlite' },
        },
      },
    }],
  });
  try {
    const hit = async (label, method, path, body) => {
      const r = await mf.dispatchFetch('http://x' + path, method === 'GET' ? {} : { method, body });
      const txt = await r.text();
      let parsed; try { parsed = JSON.parse(txt); } catch { parsed = txt; }
      console.log(`  ${label.padEnd(48)} ${r.status}  ${txt.slice(0, 90)}`);
      // `txt` and the content-type come back raw as well: (k2) compares the bytes
      // of two responses, and "identical body" is not a claim JSON.parse can make.
      return { status: r.status, body: parsed, txt, ctype: r.headers.get('content-type') };
    };
    // The worker reads its own clock, so these stamps must be real ones.
    const now = Math.floor(Date.now() / 1000);
    const A = DEV, B = DEV2;
    const TOK1 = '1'.repeat(64), TOK2 = '2'.repeat(64), TOK3 = '3'.repeat(64);
    const H = 'devesh';

    // THE R2 BUCKET IS THE ONE BINDING NOTHING ELSE IN HERE WOULD MISS. Both
    // Durable Objects are exercised by every assertion below, so losing one is
    // loud; drop MACREL and this whole file stays green while /macos/dl — the
    // route every install and every self-update comes down — is dead in prod.
    // The worker answers 503 "releases not configured" when the binding is
    // absent and 404 "no such release" when it is bound and the key is missing,
    // so the two are distinguishable. Measured both ways against this bundle
    // before this line was written: bound -> 404, binding removed -> 503.
    eq((await hit('macos/dl: is MACREL really bound?', 'GET', '/macos/dl/Kin.dmg')).status, 404,
      '(k) the R2 bucket binding is live — a 503 here means MACREL never bound at all');

    eq((await hit('register: owner A claims `devesh`', 'POST', `/api/kin/${H}/register`,
      await reg(A, { to: H, tok: TOK1, t: now }))).status, 200, '(k) A claims the handle');
    eq((await hit('register: A refreshes', 'POST', `/api/kin/${H}/register`,
      await reg(A, { to: H, tok: TOK1, t: now }))).status, 200, '(k) A can refresh');

    // THE SQUAT, for real. B has a valid keypair and a valid signature.
    eq((await hit('register: SQUATTER B, valid sig of its own key', 'POST', `/api/kin/${H}/register`,
      await reg(B, { to: H, tok: TOK2, t: now }))).status, 403, '(k) B cannot take a claimed name');
    // And again, on a later request. THIS is the assertion the source guard in
    // (j2) is only a proxy for: if the DO dropped `putKey`, haveKey would be
    // null on every request and this would answer 200.
    eq((await hit('register: B again, a round trip later', 'POST', `/api/kin/${H}/register`,
      await reg(B, { to: H, tok: TOK2, t: now }))).status, 403,
      '(k) still refused after a round trip — the kin_key row really persisted');

    // The owner rotates its poll credential, and the old one stops working.
    eq((await hit('register: A rotates its tok', 'POST', `/api/kin/${H}/register`,
      await reg(A, { to: H, tok: TOK3, t: now }))).status, 200, '(k) the owner may rotate');
    // A valid signature over a stale timestamp: refused by the skew gate, in
    // the runtime that will actually run it.
    const staleE2E = await hit('register: VALID sig, t-3600', 'POST', `/api/kin/${H}/register`,
      await reg(A, { to: H, tok: TOK1, t: now - 3600 }));
    eq(staleE2E.status, 400, '(k) a stale registration is refused end to end');
    eq(staleE2E.body.error, 'skew', '(k) and by the skew gate specifically');
    // The old handle format does not even ROUTE any more — it 404s at the edge,
    // which is why KIN_ROUTE_RE and KIN_HANDLE_RE have to agree.
    eq((await hit('register: OLD uppercase handle', 'POST', '/api/kin/Devesh/register',
      await reg(A, { to: 'Devesh', tok: TOK1, t: now }))).status, 404,
      '(k) an out-of-format handle 404s at the edge');

    const SIGE = 's'.repeat(86) + '==';
    const ringOf = (o = {}) => JSON.stringify({
      to: H, from: 'asha', room: 'RVROOMROOMROOMROOM22', t: now, sig: SIGE, k: B.k, ...o,
    });
    eq((await hit('ring: with k', 'POST', `/api/kin/${H}/ring`, ringOf())).status, 200,
      '(k) a ring with k is accepted');
    const bare = JSON.parse(ringOf()); delete bare.k;
    eq((await hit('ring: without k', 'POST', `/api/kin/${H}/ring`, JSON.stringify(bare))).status, 400,
      '(k) a ring without k is refused');

    const poll = await hit('poll: with the ROTATED tok', 'GET', `/api/kin/${H}/poll?tok=${TOK3}`);
    eq(poll.status, 200, '(k) the rotated credential polls');
    eq(poll.body.rings.length, 1, '(k) and the ring is there');
    eq(poll.body.rings[0].k, B.k, '(k) with the caller device key intact, byte for byte');
    eq((await hit('poll: with the rotated-AWAY tok', 'GET', `/api/kin/${H}/poll?tok=${TOK1}`)).status, 401,
      '(k) and the superseded credential no longer polls');

    // A handle that spells a verb, end to end — the decision asserted in (b3b),
    // proved against the real router rather than against a regex in isolation.
    for (const word of ['register', 'ring', 'poll', 'quiet']) {
      const d = await device(word);
      eq((await hit(`register: the handle \`${word}\``, 'POST', `/api/kin/${word}/register`,
        await reg(d, { to: word, tok: TOK1, t: now }))).status, 200,
        `(k) \`${word}\` is a usable handle in the real router`);
    }

    // ── (k2) SILENT MODE, in the runtime, through durable storage ────────────
    //
    // Every handle here gets its OWN poll, because KIN_POLL_GAP_MS allows one
    // poll per handle per two seconds of real time and this file does not sleep.
    sec('(k2) silent mode end to end: byte-identical to an absent handle');
    const S1 = await device('s1'), S2 = await device('s2');
    const SILENT = 'silentone';    // registered, then silenced
    const ABSENT = 'awayone';      // never registered, never polled
    const TOGGLED = 'silenttwo';   // silenced, then un-silenced

    eq((await hit('register: silentone', 'POST', `/api/kin/${SILENT}/register`,
      await reg(S1, { to: SILENT, tok: TOK1, t: now }))).status, 200, '(k2) the owner claims silentone');
    // A stranger cannot silence it, in the real DO, against the real stored key.
    eq((await hit('quiet: a DIFFERENT device tries', 'POST', `/api/kin/${SILENT}/quiet`,
      await quietOf(S2, { to: SILENT, quiet: true, until: 0, t: now }))).status, 401,
      '(k2) only the owning device may silence a handle');
    const qOn = await hit('quiet: the owner silences for an hour', 'POST', `/api/kin/${SILENT}/quiet`,
      await quietOf(S1, { to: SILENT, quiet: true, until: now + 3600, t: now }));
    eq(qOn.status, 200, '(k2) the owner may');
    eq(qOn.body.quiet, true, '(k2) and is told it is in force');
    eq(qOn.body.until, now + 3600, '(k2) with the deadline echoed back');

    // THE INVARIANT, over TWO rings each so `queued` has to climb identically.
    // Same bodies, same order, two handles: one silent, one that has never been
    // heard of. Compared as BYTES, plus the content-type.
    const twoRings = [
      { from: 'asha', room: 'RVROOMROOMROOMROOM22', k: B.k },
      { from: 'bina', room: 'RVROOMROOMROOMROOM33', k: A.k },
    ];
    for (let i = 0; i < twoRings.length; i++) {
      const r = twoRings[i];
      const mk = (to) => JSON.stringify({ to, from: r.from, room: r.room, t: now, sig: SIGE, k: r.k });
      const s = await hit(`ring ${i + 1}: -> SILENT handle`, 'POST', `/api/kin/${SILENT}/ring`, mk(SILENT));
      const a = await hit(`ring ${i + 1}: -> ABSENT handle`, 'POST', `/api/kin/${ABSENT}/ring`, mk(ABSENT));
      eq(s.status, a.status, `(k2) ring ${i + 1}: same status`);
      eq(s.txt, a.txt, `(k2) ring ${i + 1}: BYTE-IDENTICAL body (${s.txt})`);
      eq(s.ctype, a.ctype, `(k2) ring ${i + 1}: same content-type`);
      eq(s.body.queued, i + 1, `(k2) ring ${i + 1}: and \`queued\` really climbed to ${i + 1} on BOTH — the fabricated-body implementation reads 1,1 here`);
    }

    const sPoll = await hit('poll: the silent handle\'s owner', 'GET', `/api/kin/${SILENT}/poll?tok=${TOK1}`);
    eq(sPoll.status, 200, '(k2) the owner polls');
    eq(sPoll.body.rings?.length, 0, '(k2) and is handed NOTHING — the Mac never wakes');
    eq(sPoll.body.quiet?.on, true, '(k2) while being told the toggle is on');
    eq(sPoll.body.quiet?.until, now + 3600, '(k2) with the deadline that survived a durable write and a read back');
    eq(sPoll.body.quiet?.exceptKnown, false, '(k2) exceptKnown false, as v1 has no way to set it');
    eq(sPoll.body.quiet?.dropped, 2, '(k2) and a count of the two calls it swallowed');

    // The toggle round-trips: on, then off, and a ring lands.
    eq((await hit('register: silenttwo', 'POST', `/api/kin/${TOGGLED}/register`,
      await reg(S2, { to: TOGGLED, tok: TOK2, t: now }))).status, 200, '(k2) a second handle is claimed');
    eq((await hit('quiet: on', 'POST', `/api/kin/${TOGGLED}/quiet`,
      await quietOf(S2, { to: TOGGLED, quiet: true, until: 0, t: now }))).status, 200, '(k2) silenced');
    const qOff = await hit('quiet: off again', 'POST', `/api/kin/${TOGGLED}/quiet`,
      await quietOf(S2, { to: TOGGLED, quiet: false, until: 0, t: now }));
    eq(qOff.status, 200, '(k2) and un-silenced');
    eq(qOff.body.quiet, false, '(k2) which it reports');
    eq((await hit('ring: after the toggle went off', 'POST', `/api/kin/${TOGGLED}/ring`,
      JSON.stringify({ to: TOGGLED, from: 'asha', room: 'RVROOMROOMROOMROOM44', t: now, sig: SIGE, k: A.k }),
    )).status, 200, '(k2) a ring is accepted');
    const tPoll = await hit('poll: silenttwo', 'GET', `/api/kin/${TOGGLED}/poll?tok=${TOK2}`);
    eq(tPoll.body.rings?.length, 1, '(k2) and DELIVERED — the toggle is a toggle in the real DO too');
    eq(tPoll.body.quiet?.on, false, '(k2) which now reports off');
    eq(tPoll.body.quiet?.dropped, 0, '(k2) and swallowed nothing');

    // The route exists at the edge and answers the same 401 for an unclaimed
    // handle as for a wrong key — checked here because the edge could plausibly
    // 404 a verb it has not been taught.
    eq((await hit('quiet: an UNCLAIMED handle', 'POST', '/api/kin/nobodyhere/quiet',
      await quietOf(S1, { to: 'nobodyhere', quiet: true, until: 0, t: now }))).status, 401,
      '(k2) an unclaimed handle cannot be silenced, and the verb routes');
    eq((await hit('quiet: GET instead of POST', 'GET', `/api/kin/${SILENT}/quiet`)).status, 405,
      '(k2) and the verb is POST-only at the edge');

    // ── (k3) THE HELD POLL, IN REAL WORKERD ─────────────────────────────────
    //
    // Every assertion in (m) is about a pure function deciding to park. NOTHING
    // there proves a Durable Object actually holds a request open, actually
    // wakes on a ring, or actually answers 204 at the deadline — the decision
    // and the holding are different code, and the holding is the half that
    // cannot be unit tested. `Room.kinHold` is a promise, a timer and a set of
    // callbacks; a wake that skipped a waiter, a timer that was never cleared,
    // or a `park` the DO forgot to honour would all leave (m) entirely green.
    //
    // So this section uses a real clock and real elapsed time, and asserts on
    // BOTH ends of it: fast when rung, and not-fast when not.
    sec('(k3) the held poll end to end: a real request, really held, really woken');
    const HELD = 'holdone';
    const TOKH = '4'.repeat(64);
    const H1 = await device('h1');
    eq((await hit('register: holdone', 'POST', `/api/kin/${HELD}/register`,
      await reg(H1, { to: HELD, tok: TOKH, t: Math.floor(Date.now() / 1000) }))).status, 200,
      '(k3) the owner claims holdone');

    // 1. Held and woken. The poll goes out first and is NOT awaited; a ring
    //    follows 250 ms later; the poll must come back with it, long before its
    //    own 8 s deadline.
    {
      const t0 = Date.now();
      const parked = mf.dispatchFetch(`http://x/api/kin/${HELD}/poll?tok=${TOKH}&wait=8000`);
      await new Promise((r) => setTimeout(r, 250));
      const rang = await hit('ring: while a poll is parked', 'POST', `/api/kin/${HELD}/ring`,
        JSON.stringify({
          to: HELD, from: 'asha', room: 'RVROOMROOMROOMROOM55',
          t: Math.floor(Date.now() / 1000), sig: 's'.repeat(86) + '==', k: DEV2.k,
        }));
      eq(rang.status, 200, '(k3) the ring is accepted while somebody is parked on the mailbox');
      const r = await parked;
      const took = Date.now() - t0;
      const body = await r.json();
      console.log(`  held poll returned after ${took} ms with ${body.rings?.length} ring(s)`);
      eq(r.status, 200, '(k3) the held poll returns 200');
      eq(body.rings?.length, 1, '(k3) carrying the ring that woke it');
      eq(body.rings?.[0].room, 'RVROOMROOMROOMROOM55', '(k3) the right ring, intact');
      ok(took < 3000, `(k3) and it returned in ${took} ms, not at its 8 s deadline — the DO really woke it`);
      ok(took >= 250, `(k3) CONTROL: it did not return BEFORE the ring (${took} ms >= 250)`);
      ok(body.waitedMs >= 250, `(k3) and it reports how long it was held (${body.waitedMs} ms)`);
    }

    // 2. Held to the deadline. Nothing rings, so the answer must be a 204 that
    //    arrives at the deadline and not before — an immediate 204 would be a
    //    server that answered without holding, which is the failure this whole
    //    change is trying not to be.
    {
      await new Promise((r) => setTimeout(r, 1100));   // clear the arming window
      const t0 = Date.now();
      const r = await mf.dispatchFetch(`http://x/api/kin/${HELD}/poll?tok=${TOKH}&wait=1500`);
      const took = Date.now() - t0;
      console.log(`  unrung held poll returned ${r.status} after ${took} ms`);
      eq(r.status, 204, '(k3) an unrung held poll ends in 204');
      eq(await r.text(), '', '(k3) with no body at all');
      ok(took >= 1400, `(k3) after the full wait (${took} ms), not immediately — proof it was really held`);
      ok(took < 4000, `(k3) and it does end (${took} ms) — the deadline is a deadline, not a leak`);
    }

    // 3. An OLD client, unchanged. Same handle, no `wait`, and the body must be
    //    the shape that shipped — including no `waitedMs`, which is the field a
    //    new client reads to decide whether to trust this server at all.
    {
      await new Promise((r) => setTimeout(r, 2100));   // clear the plain poll gap
      const old = await hit('poll: an OLD client, no wait param', 'GET', `/api/kin/${HELD}/poll?tok=${TOKH}`);
      eq(old.status, 200, '(k3) an old client still polls this worker');
      deep(Object.keys(old.body).sort(), ['leaseMs', 'pollMs', 'quiet', 'rings', 'to'],
        '(k3) and gets exactly the keys it always got');
      ok(!('waitedMs' in old.body), '(k3) with no waitedMs, so nothing about its behaviour changes');
    }

    // 4. A wait it cannot honour is not an error. `wait=50` is below the floor
    //    and must degrade to an ordinary poll rather than a 400 — a client that
    //    guessed the parameter slightly wrong must not stop receiving calls.
    {
      await new Promise((r) => setTimeout(r, 2100));
      const t0 = Date.now();
      const r = await hit('poll: wait=50, below the floor', 'GET', `/api/kin/${HELD}/poll?tok=${TOKH}&wait=50`);
      eq(r.status, 200, '(k3) a sub-floor wait is answered, not refused');
      ok(Date.now() - t0 < 500, '(k3) and answered at once rather than held');
      ok(!('waitedMs' in r.body), '(k3) and honestly reports that it did not wait');
    }

    // ── (k4) TWO HOLDERS: THE GHOST MUST NOT SWALLOW THE RING ────────────────
    //
    // This is the bug the design nearly shipped, and no single-listener test can
    // see it. Two processes listen for one person: the menu-bar resident and the
    // app. One of them is killed while its poll is parked — the server has no
    // way to know, and a socket that is still open is not a live peer. The next
    // ring wakes it, it DRAINS THE MAILBOX DESTRUCTIVELY, and the listener that
    // is actually alive gets nothing.
    //
    // Reproduced here as two overlapping held polls where the FIRST is the
    // ghost: it stays parked, the second arrives after it, and the ring must go
    // to the second. Measured against the real thing before the fix, the app was
    // killed mid-hold and the resident received nothing at all.
    {
      sec('(k4) two held polls on one handle: the ring goes to the live one');
      const GH = 'ghostone';
      const TOKG = '5'.repeat(64);
      const G1 = await device('g1');
      eq((await hit('register: ghostone', 'POST', `/api/kin/${GH}/register`,
        await reg(G1, { to: GH, tok: TOKG, t: Math.floor(Date.now() / 1000) }))).status, 200,
        '(k4) the owner claims ghostone');

      // The ghost parks first and is never read again by anybody.
      const gT0 = Date.now();
      const ghost = mf.dispatchFetch(`http://x/api/kin/${GH}/poll?tok=${TOKG}&wait=9000`);
      await new Promise((r) => setTimeout(r, 1200));    // clear the arming window
      // The live listener arrives second. Its very arrival is the only evidence
      // the server has that anyone is alive, and it is what evicts the ghost.
      const live = mf.dispatchFetch(`http://x/api/kin/${GH}/poll?tok=${TOKG}&wait=9000`);
      await new Promise((r) => setTimeout(r, 400));
      eq((await hit('ring: with one ghost and one live holder', 'POST', `/api/kin/${GH}/ring`,
        JSON.stringify({
          to: GH, from: 'asha', room: 'RVROOMROOMROOMROOM66',
          t: Math.floor(Date.now() / 1000), sig: 's'.repeat(86) + '==', k: DEV2.k,
        }))).status, 200, '(k4) the ring is accepted');

      const liveRes = await live;
      const liveBody = liveRes.status === 200 ? await liveRes.json() : null;
      const ghostRes = await ghost;
      const ghostMs = Date.now() - gT0;
      const ghostBody = ghostRes.status === 200 ? await ghostRes.json() : null;
      console.log(`  live holder -> ${liveRes.status} with ${liveBody?.rings?.length ?? 0} ring(s);`
        + `  ghost -> ${ghostRes.status} with ${ghostBody?.rings?.length ?? 0} ring(s) after ${ghostMs} ms`);
      eq(liveRes.status, 200, '(k4) the LIVE holder gets a 200');
      eq(liveBody?.rings?.length, 1, '(k4) carrying the ring — this is 0 when the ghost drains it first');
      eq(ghostRes.status, 204, '(k4) and the ghost was evicted with a 204');
      eq(ghostBody, null, '(k4) having taken NOTHING out of the mailbox — an eviction that drained would lose the call');
      // TIMING IS THE ASSERTION THAT CAN FAIL. Status 204 alone is also what a
      // ghost left to rot produces when its own deadline finally expires, so
      // without this the two are indistinguishable and the eviction could be
      // deleted with every other line here still green. It was evicted the
      // moment a live poll arrived — about 1.2 s in, not at its 9 s deadline.
      ok(ghostMs < 4000,
        `(k4) and was evicted when the live poll ARRIVED (${ghostMs} ms), not left until its own 9 s deadline`);
    }

    // ── (k5) a watcher heartbeat is storable and is NOT a call ──────────────
    //
    // The background agent now reports what it did about updates, because a Mac
    // that stops calling is exactly the Mac somebody asks about and it had no
    // way to say anything. Every listing here groups by `call`, so the danger is
    // the opposite of silence: a heartbeat every half hour showing up as a
    // zero-length call and burying the real ones.
    {
      const beat = (phase, extra) => JSON.stringify({
        install: 'testmac000001', call: 'wbeat' + phase, version: '0.70.0',
        model: 'Mac16,10', phase, ...extra,
      });
      eq((await hit('mac beat: a watcher heartbeat', 'POST', '/api/mac/beat',
        beat('watch', { update_stage: 'blocked', update_blocked: 'not writable' }))).status, 200,
        '(k5) a watch beat is accepted');
      eq((await hit('mac beat: a real call', 'POST', '/api/mac/beat',
        beat('final', { durationS: 12 }))).status, 200, '(k5) a call beat is accepted');

      const recent = await hit('mac: recent calls', 'GET', '/api/mac/recent?n=50');
      eq(recent.status, 200, '(k5) recent reads');
      const calls = (recent.body?.calls ?? []).map((c) => c.call);
      ok(!calls.includes('wbeatwatch'),
        '(k5) the watcher heartbeat is NOT listed as a call — this is 1 zero-length call per Mac per half hour when it breaks');
      ok(calls.includes('wbeatfinal'),
        '(k5) and the real call still is — a filter that hid both would pass the line above and lose the dashboard');

      const macs = await hit('mac: one row per Mac', 'GET', '/api/mac/macs');
      eq(macs.status, 200, '(k5) /api/mac/macs reads');
      const mine = (macs.body?.macs ?? []).find((m) => m.install === 'testmac000001');
      ok(!!mine, '(k5) the Mac appears once, by install');
      eq(mine?.version, '0.70.0', '(k5) carrying the version it last reported');
      eq(mine?.update_stage, 'blocked', '(k5) and WHY it is not updating, which is the whole question');
      eq(mine?.update_blocked, 'not writable', '(k5) with the reason, not just the verdict');
      eq(mine?.watches, 1, '(k5) heartbeats counted');
      eq(mine?.calls, 1, '(k5) and calls counted separately');
    }
  } finally {
    await mf.dispose();
  }
}

console.log(failures === 0
  ? '\nAll contact/doorbell/TURN cases passed.'
  : `\n${failures} assertion(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
