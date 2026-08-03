# TAPE — Human Validation Protocol (~30 min, two people)

Validates that the fatigue fixes behave as designed with real humans, that latency
feels right, and that the telemetry agrees with what you felt. Print this page.

## 1. Setup (5 min)

- Two devices (laptops best), each in a **different room** — if you can hear each
  other through the air you cannot judge latency or breaths.
- **Chrome, Edge, or Brave only.** Safari/Firefox can't do the fixed-quality video lane.
- Open `https://room.tokkah.com` (must be https; don't open inside another app's
  built-in browser — those block the connection).
- Both of you type the **same room code** (any made-up word, e.g. `maple42`) and
  press **Join**. Whoever joins first can also copy the share link shown in the app.
- **Both wear headphones. This is mandatory, and here is why:** echo cancellation is
  switched off *on purpose* — it is the thing that deletes the inhale before someone
  speaks, and that breath is the design's biggest latency win. Without headphones your
  mic hears your speaker and your partner hears themselves echoed back.
- Allow camera + mic. Check the lobby: you should see a badge like
  `720p · 30 · lossless audio`. **The number is your own camera's resolution, so
  720p on a typical laptop is correct and not a fault** — the app sends exactly
  what the sensor produces and never inflates it. It must say `lossless audio`;
  if it says `compressed audio`, stop and note it.
- Note your room code: __________   Date: __________

## 2. The 15-minute conversation script

Follow the clock loosely. The games exist to produce the exact situations the design
targets — fast turns, interruptions, double-talk, laughter, breaths.

- **0–2 min · Hello & settle.** Small talk (breakfast, weather). The video may be
  choppy for the first ~20 seconds — that is a designed warmup, not a bug. Look at
  face size and eye position (checklist 6–8).
- **2–5 min · Rapid-fire questions.** Take turns asking one-sentence questions
  (coffee or tea? last trip? favorite movie?). Answer as fast as you can — cutting
  the silence short is the point. This produces the fast turn transitions we measure.
- **5–7 min · Interruption game.** Person A tells a 2-minute story (last vacation).
  Person B's job is to interrupt constantly with questions. Then swap.
- **7–8 min · Talk over each other.** Count 1→20 out loud *together*, then both
  describe your day at the same time for 15 seconds. Neither voice should duck,
  drop, or get quieter — that's the fail we're hunting.
- **8–10 min · Make each other laugh.** Jokes, embarrassing stories. Laughter should
  sound like laughter, not static or robot.
- **10–12 min · Thinking questions + the breath test.** Ask things that need thought
  ("live anywhere for a year — where?"). **Listen for the other person's inhale
  before they start answering.** Then deliberately: each of you takes one clearly
  audible breath in before answering the next question. Did you hear it?
- **12–14 min · Move around.** Lean back, turn sideways, look away, come back.
  The picture's brightness and color should not pump or re-adjust as you move.
- **14–15 min · Free chat, then score.** Fill in section 3 together. Hang up.

## 3. What to notice — each person ticks their own sheet

1. **Breaths:** I heard the other person inhale before speaking, at least once. ☐
2. **Voice:** they sounded like themselves — not thin, not "phone voice", no
   robot warble, even during laughter. ☐
3. **Double-talk:** when we spoke at the same time, both voices stayed full and
   clear; nobody got ducked or cut out. ☐
4. **Endings:** no clipped final syllables. ☐
5. **Steady picture:** brightness/color never hunted or pumped when they moved. ☐
6. **Size:** their face looked person-sized, not a giant face filling the screen. ☐
7. **Eye contact:** looking at their eyes felt close to real eye contact. ☐
8. **No mirror:** I could not see my own face. ☐
9. **Speed:** the silence between turns felt short — closer to face-to-face than
   to a normal video call. ☐
10. **Clean picture:** no blockiness, smearing, or frozen-then-jumping frames. ☐

Any unticked box → go to section 6.

## 4. Pull the numbers afterward (one person, any computer)

Replace `maple42` with your room code:

```sh
CODE=maple42
curl -s "https://room.tokkah.com/api/room/$CODE/summary"          > summary.json
curl -s "https://room.tokkah.com/api/room/$CODE/log?kind=transition" > transitions.ndjson
curl -s "https://room.tokkah.com/api/room/$CODE/log?kind=transition-update" > tr-updates.ndjson
curl -s "https://room.tokkah.com/api/room/$CODE/log?kind=tape-stats" > tape-stats.ndjson
curl -s "https://room.tokkah.com/api/room/$CODE/log?kind=onset"     > onsets.ndjson
curl -s "https://room.tokkah.com/api/room/$CODE/log?kind=capture"   > capture.ndjson
curl -s "https://room.tokkah.com/api/room/$CODE/log?kind=camlock"   > camlock.ndjson
curl -s "https://room.tokkah.com/api/room/$CODE/log?kind=stats"     > stats.ndjson
```

Notes: `transition-update` lines patch the `transition` with the same `n` field
(join on `n`) — they carry `openedWith`, `breathLeadMs`, `gapToWordMs`. Two roles,
`a` and `b`, appear in every file — one per person.

## 5. Pass / fail thresholds

**Fatigue levers (the point of the test):**

| Check | Where | Pass |
|---|---|---|
| Audio DSP off | `capture.ndjson` | `echoCancellation`, `noiseSuppression`, `autoGainControl` all `false` |
| Camera locked | `camlock.ndjson` | `{"ok":true}` present from both roles |
| Breath survived the network | `onsets.ndjson` | remote-side events with `type:"classified", kind:"breath"` exist |
| Breath rate | transitions joined with updates | `openedWith:"breath"` on ≥ 40% of usable transitions |
| Breath lead | joined transitions | `breathLeadMs` median 100–350 ms (design: ~200) |
| Human gap | transitions | median `gapMs` where `metric:"human"`, not overlap/lull/backchannel: 150–600 ms — see the baseline note below |
| Perceived gap | transitions | median `gapMs` where `metric:"perceived"`: **< 700 ms** (Zoom measures 976) |
| Consistency | transitions + `stats.ndjson` RTT | perceived ≈ human + RTT, roughly; if wildly off, save everything |

**Latency & video lane (from the LAST lines of `tape-stats.ndjson`, per role):**

| Number | Pass |
|---|---|
| `fullAgeP50` + `presentLagP50` (≈ glass-to-glass) | < 100 ms same city · < 200 ms cross-country. (Our loopback floor is 23.0 ± 1.7 ms. The "Zoom: 130–250 ms" that used to sit here is **unsourced** — see `MEASURED.md`.) |
| `framesLost` | 0 |
| `keyReqSent` | 0 on a healthy network |
| `fecRepaired` | > 0 is fine — that's the repair working; `fecUnrepairable` > 0 is worth a look |
| `admitFps` | ~30 after the first minute; a 5→30 climb in the first ~20 s is the normal warmup |

Minimum data for a valid run: ≥ 20 total transitions, ≥ 10 usable after removing
overlaps/lulls/backchannels. The script is designed to produce well above that.

### Which face-to-face baseline to compare against — read this before scoring

There is no single "face-to-face gap", and this page used to imply one by saying
"face-to-face is 297". That number is the **local control of a structured Q&A
task** (Boland et al. 2022, Exp 1, whose Zoom arm is the 976 ms figure). It is
the right comparison **only for the 2–5 min rapid-fire questions segment**,
which is the matched task.

| segment of the script | baseline to score against | source |
|---|---|---|
| rapid-fire questions (2–5 min) | **297 ms** | Boland 2022 Exp 1, local control |
| free conversation, interruptions, laughter | **135 ms** | Boland 2022 Exp 2, face-to-face |
| general cross-linguistic reference | **~208 ms** | Stivers 2009 (range +7 to +469) |

Scoring free conversation against 297 ms is **too lenient by roughly 160 ms** —
a call sitting at 250 ms would pass while being far slower than real
conversation. Score each segment against its own row.

## 6. "If X feels wrong, capture Y"

| What felt wrong | Capture |
|---|---|
| I heard myself echoed | Someone skipped headphones — fix and rerun. (`capture` showing `echoCancellation:false` is by design, not the bug.) |
| Robot voice / warble | Last lines of `stats.ndjson` (audio concealment counters) + `fecUnrepairable`, `framesLost` in `tape-stats.ndjson` |
| Picture froze, then hard-cut back | `keyReqSent`, `framesLost`, `ageP95` in tape-stats — and whether the app showed "holding · audio live" (that message means the stall machine worked as designed) |
| Choppy video only in the first ~20 s | Expected warmup — confirm `admitFps` climbing in tape-stats; report only if it never reaches ~30 |
| Blocky or soft picture | Should be impossible by design — screenshot + `mbpsAtFps` / `frameBytesMean` in tape-stats |
| Voice ducking when both speak | Should be impossible (no echo canceller) — phone recording of the moment + the `capture` event |
| Brightness pumping when moving | Camera lock failed — check `camlock.ndjson` for `{"ok":true}`; note OS/browser version |
| Face wrong size / gaze way off | Screenshot + `geometry` / `peer-geom` events (append `&kind=geometry` / `&kind=peer-geom` to the log URL) |
| Replies felt slow but every number passes | Compare perceived vs human medians against RTT (section 5 consistency row) and save all files — a mismatch there is itself the finding |

Done. Keep the eight files plus this sheet together, one folder per session.
