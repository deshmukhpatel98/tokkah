# GATE-READINESS — the human turn-taking gate (`/turns`)

*Audit and dry-run, 2026-08-01. Scope: `fatigue-lab/` only.*

The gate exists to falsify or confirm the design's central inference (DESIGN.md
§1.1c): that Zoom loses far more turn-taking time than its own transport delay
explains, and that restoring the destroyed turn-end cues wins some of it back.

**The size of that residual was restated.** The old "179 ms" here rested on an
unsourced 500 ms Zoom round trip; Boland measured actual audio delay at
30–70 ms, which makes the unexplained residual ~609 ms — *larger*, so the
argument is stronger but the lever is unsized. Do not quote 179 ms.

Pass criteria (§19, phase 3): human-only median within 120 ms of the 297 ms
control — which is Boland Exp 1's **local structured-Q&A** control, valid only
for a matched task, see `README.md` — >50% of turns opening with an audible
breath, ≥100 ms breath head start, first evidence under Zoom's 976 ms (the same
experiment's Zoom arm, which is what makes the pairing legitimate).

## Verdict

**The harness implements Boland's paradigm correctly and now produces trustworthy
numbers — after one blocking fix.** It runs the right experiment (timed yes/no Q&A,
raw vs processed arms), measures the right thing (turn-end to first evidence and to
first word, all on the asker's clock, no clock sync needed), discards the right rows
(interruptions, distractions), and judges the right four checks. Two non-technical
people can run it — once it is deployed somewhere with HTTPS (one-time, 5 minutes,
needs the Cloudflare login).

## What was broken and is now fixed

1. **BLOCKING — t0 was stamped on message delivery, not on the event's actual time.**
   The detector only emits `end` after 350 ms of accumulated quiet, so delivery is
   ~350 ms after the moment the question ended, while a remote `classified` arrives
   ~35 ms after the breath. Stamping both at receipt shifted t0 ~315 ms late,
   shrinking every measured gap by that much — and pushing genuine ~300 ms
   transitions below zero, where the discard rule would have thrown away exactly the
   fast turns this experiment exists to collect. tape-app's live analyser hit this
   same bug on a real call (its app.js comment is the write-up); the fix here is the
   same: stamp from the worklet's `ctxTime` (both detectors share one AudioContext,
   so one clock), with the `onsetAt` correction for `classified` events.
2. **Forced detector `end` events could anchor t0.** A forced end means the noise
   floor was wrong, not that speech ended. Now ignored, with a log line.
3. **Nothing enforced that both machines ran the same audio mode.** A pair with one
   side raw and one processed produces data that looks fine and means nothing. Now:
   modes are exchanged over the signaling channel, a mismatch gets a loud on-page
   warning, both modes are recorded per row, and the checkbox locks after Join.
4. **No instructions a non-technical pair could follow.** The page now opens with a
   numbered run-sheet card.
5. **UX traps:** the "next question" button actually swapped askers (relabeled
   "swap asker"); "discard" on the answerer side desynced the pair (now asker-only);
   the raw checkbox could be toggled mid-run, silently mixing arms (locked on Join).
6. **README told two people to open `http://localhost:8793` on two machines** —
   impossible (a second machine needs HTTPS for mic access). Corrected, with the
   deploy path documented.

## Dry-run evidence (two headless Chromes, real WebRTC, real recorded speech)

Scripts preserved in `dryrun/` (require `testbed/node_modules` playwright and
`testbed/media/conv/`; run `npx wrangler dev --port 8793` first).

- **Raw arm:** 5 scored turns, gaps constant to ±5 ms, `voice − ttfe = head start`
  holds exactly per row, breath leads recovered at 186–246 ms against 193–258 ms
  baked in (the shortfall is the detector's deliberate −24 ms bias). A ~1.4 s
  constant offset vs the fixture's 620 ms scripted gap is the two fake microphones
  starting 1.4 s apart (the fixture is documented as unsynchronised); a human run
  has no such concept — the reply happens when it happens.
- **Processed arm (NS/AGC/AEC on):** breaths partially gated (2/4 vs 3/5 opened
  with breath, head starts 16–96 ms vs ~200 raw) — the arm toggle bites. (The
  fixture's −58 dBFS room tone gives noise suppression little to chew on; real
  rooms will show a bigger raw/processed split.)
- **Verdict drive (synthetic Boland-shaped events):** 8 turns of 300 ms human gap,
  200 ms lead, 40 ms RTT → every row reads exactly 140/340/200/300 ms and the
  verdict is PASS on all four checks, including the 297±120 ms window.
- **Mode handshake** verified both directions; **CSV export** verified (run label,
  both modes, all columns).

## Remaining gaps, ordered by blocking-ness

1. **No HTTPS deployment yet — the only thing still blocking the human run.**
   `npm run deploy` in `fatigue-lab/` (needs the saved Cloudflare OAuth login),
   then share `https://tape-fatigue-lab.<subdomain>.workers.dev`. ~5 min, once.
   Optional: a custom domain like the app's `room.tokkah.com`.
2. **No face-to-face control arm.** The gate compares against Boland's *published*
   297 ms control, not this pair's own. A same-pair F2F baseline (two people, one
   room, one laptop, one mic, the turntaking analyser from tape-app) would remove
   the cross-study comparison. Optional but valuable. ~half day.
3. **No checked-in automated test for `turns.js`.** Verification is the two
   dry-run scripts above, which depend on testbed's playwright + media. A DOM-shim
   node test of the scoring path would make the gate regression-proof. ~half day.
4. **Statistics are medians-only, on-page.** Fine for a gate, but with 20+ turns
   per arm the CSVs deserve an offline look (spread, per-pair effects, raw vs
   processed delta per turn type). ~2 h of analysis scripting, or do it by eye.
5. **Known measurement floors (documented, not bugs):** RTT comes from the
   candidate-pair handshake (symmetric-path assumption; ms-level on LAN);
   detector events timestamp at the worklet, not the DAC/diaphragm (constant tens
   of ms, mostly cancelling in t1−t0); Chrome's jitter buffer sits inside the
   perceived numbers *by design*. Combined accuracy is comfortably inside the
   120 ms pass window, but don't read better than ±30 ms into any single row.
6. **Protocol honour-system items:** the answerer must answer the instant they
   know (say so, every run); questions cycle in fixed order (anticipation effects
   are small for yes/no answers); roles swap only when someone presses the button
   (the run-sheet says every ~10).

## Run-sheet for the human pair (~35–40 min total)

**Before anything (one time, developer, 5 min):** deploy (gap 1), send the pair
the URL.

**Both people, together on a call or chat (5 min):**
1. Chrome, Edge, or Brave. Headphones on — mandatory, echo cancellation is off on
   purpose in the raw run. Sit in **different rooms**.
2. Open `<the URL>/turns`. Read the run-sheet card at the top — it's the same
   list as here.
3. Same room word (any made-up word), run label `run1`, **raw audio ticked** on
   both. Join. Confirm the line next to Join says *"peer: raw — match"*.

**Run A — raw (~15 min):**
4. Whoever sees **you ask** reads the question aloud, then stops. Whoever sees
   **you answer** says "yes" or "no" **the instant you know** — speed is the
   measurement, politeness ruins it.
5. The page advances by itself. After ~10 questions, either of you presses
   **swap asker**. If a turn goes wrong (sneeze, interruption, someone walks in),
   the asker presses **discard this one**.
6. At **20+ scored turns** (counter at the top), both press **export CSV**.

**Run B — processed (~15 min):**
7. Both reload the page, **untick raw audio**, label `run2`, same room word, Join.
   Confirm *"peer: processed — match"*. Repeat steps 4–6.

**Afterward (2 min):**
8. Send the four CSVs (two per person; the asker's files carry the measurements)
   to whoever is analysing. Gate verdict: the page shows it live after 8 turns,
   but judge on the full 20+ per arm. Compare `human_only_ms` median, run A vs
   run B — that delta *is* the §1.1c experiment.
