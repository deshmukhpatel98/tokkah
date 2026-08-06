# Interpreter — live speech-to-speech translation in Tokkah

**The product in one line:** you talk in your language, the other person hears
your voice speaking theirs, fast enough to do business. This is the feature
100M people will pay $20–50/month for; the call itself is not.

Status (2026-08-06): **Vendor switched — Gemini 3.5 Live Translate
(`gemini-3.5-live-translate-preview`) is now the DEFAULT interpreter on
room.tokkah.com.** One Live API session per speaking side replaces the whole
Scribe→MT→TTS chain: 16 kHz PCM up (unchanged tap), translated 24 kHz PCM +
transcripts down, upsampled ×2 to 48 kHz in the Worker so the client is
byte-identical. Translation is CONTINUOUS (streams ~a phrase behind the
speaker; probe measured end-of-phrase→translated-audio 164 ms vs ~730–800 ms
T_tail for the legacy chain) and preserves intonation/pacing per vendor docs.
`echoTargetLanguage=false` gives the same-language-pair captions-only rule
for free. Session resumption handles are stored for the vendor's session cap;
idle/lazy reconnect mirrors the Scribe pattern. The ElevenLabs pipeline
remains fully intact behind `?xlvendor=el` (rig: `--vendor=el`) as the A/B
control. Default vendor = gemini whenever GEMINI_API_KEY is set (it is, on
both workers). Measured on prod 2026-08-06 (`testbed/xlate-call.mjs`, flag
and button arms): captions OK (correct Spanish), 32–34 s of translated 48 kHz
audio per 40 s run, 0 failures. Caveats: per-segment msStt/msMt/msTts are
null by design (stages collapsed — the rig's T_tail sum is not meaningful on
this vendor; delivery + caption correctness + the probe's 164 ms gap are the
metrics); rare preview-model artifact observed once (a refusal string
surfaced as a caption on audiobook-style content).

Previous status (2026-08-05, evening): **P0+P1 SHIPPED to room.tokkah.com as a
one-tap 🌐 button** — no URL flags, no setup. One side taps the globe, both
sides come up translated (peer gets `xlate-on` over signaling); the speaker's
language is auto-detected per phrase (Scribe `include_language_detection`;
note: detection doubles every commit — handle only the `_with_timestamps`
variant); each listener hears their own `navigator.language`; a same-language
pair gets captions only, never TTS parroting. Button-path measured on prod:
7/7 segments, T_tail p50 730 ms / p95 824 ms. `?xlate=<lang>` remains as the
rig's listening-language override (`testbed/xlate-call.mjs --button=1` is the
no-flags arm). Measured on prod via `testbed/xlate-call.mjs` (n=7 segments):
7/7 captions correct, 7/7 TTS segments delivered, T_tail server-side
p50 794 ms / p95 889 ms (STT 668 + MT 0 + TTS-first-byte 112), 27.3 s of
translated 48 kHz audio delivered clean. MT is passthrough until an
`ANTHROPIC_API_KEY` secret is set (then Claude Haiku, no code change).
Voice cloning (P2) and ducking/turn-yielding (P3) not started.

---

## 1. What the user experiences

- In the lobby (or mid-call), each side picks **"I speak …"** — one tap.
  Everything else is automatic; there is no "enable translation" ceremony.
- You hear the remote person's **own voice** speaking **your** language,
  slightly behind their lips. Their original voice stays audible underneath
  at −18 dB (configurable to full duck) so cadence, laughter, and emotion
  still come through and the translation never feels like a phone menu.
- Live captions run in both languages as a free byproduct (they are the
  intermediate product of the pipeline, not extra work).
- If the pipeline ever falls behind, it **degrades to captions**, never to
  stalled audio. The lossless lane is never touched (see §4, Law 0).
- Optional self-monitor: hear your own translation at low volume, so you can
  trust what the other side is getting.

## 2. Why this can be better here than in Meet/FaceTime/Galaxy AI

1. **Clean input.** Translation quality is gated by ASR quality, which is
   gated by capture quality. We hand Scribe 48 kHz lossless PCM, not
   Opus-decoded, echo-cancelled mush. Nobody else in consumer calling can.
2. **We own the playout clock.** Translated speech has to be *placed* —
   ducked under the original, aligned to phrase boundaries, never colliding
   with the next utterance. Our SAB-ring playout worklet gives sample-level
   control; stock-WebRTC products get an `<audio>` element and a prayer.
3. **Browser link, both engines, bad networks.** The paying pool
   (Manila–Dubai, Lagos–London, Mexico City–Houston) is on cheap Androids
   and Safari iPhones on lossy links — exactly where our FEC/latency work
   already lives, and where Apple/Google's versions are platform-locked.

## 3. Vendor facts the design rests on (checked 2026-08-05)

| Stage | Model | Latency (vendor) | Notes |
|---|---|---|---|
| STT | **Scribe v2 Realtime** (websocket) | ~150 ms median, ~250 p95, ~400 p99, last-chunk→transcript | partials + committed segments, word timestamps |
| MT | streaming LLM (Claude Haiku 4.5 first candidate; DeepL/Gemini as A/B arms) | first token 150–300 ms | translate *committed* Scribe segments + speculative partials |
| TTS | **Flash v2.5** (websocket, chunk streaming) | ~75 ms model time; first audible byte ~150–250 ms end-to-end | 32 languages, 0.5 credits/char ($0.05/1k chars API) |
| Voice | **Instant Voice Clone** | built once at call start | cloned from the first ~20 s of *our lossless capture* |

"Highest quality" tension, stated honestly: Eleven **Multilingual v2 / v3**
sound better than Flash v2.5 but are not realtime-priced in latency
(~250–400 ms model time). The spec ships Flash v2.5 as the realtime arm and
keeps model id as a flag (`?xlvoice=flash|m2`) so quality-vs-lag is an A/B
**measured on the rig, not argued** (MEASURED.md discipline). Sources:
[Scribe v2 Realtime](https://elevenlabs.io/realtime-speech-to-text),
[realtime STT API](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime),
[TTS websocket](https://elevenlabs.io/docs/eleven-api/guides/how-to/websockets/realtime-tts),
[latency guide](https://elevenlabs.io/docs/eleven-api/guides/how-to/best-practices/latency-optimization).

## 4. Architecture

One direction (mirrored for the other side):

```
mic (existing pcm-capture worklet, 48k/24-bit, 8 ms frames)
  └─ TAP: downmix→16 kHz int16 mono (in a small resampler worklet sibling)
      → WS to OUR Worker  /xlate  (key never reaches the browser)
        → Scribe v2 Realtime  ── partial/committed text + word times
        → MT stream (committed-prefix translation; re-translate only the tail)
        → Flash v2.5 WS (voice = caller's instant clone, target language)
      ← translated PCM chunks + caption events, over the same WS
  └─ translated audio goes INTO THE SENDER'S Worker session, but is played
     on the RECEIVER: worker relays TTS audio + captions to the peer's WS.
     Receiver writes it to a second, independent playout ring ("xlate ring")
     mixed after the Lane-A ring with the ducking gain applied to Lane A.
```

**Law 0 (inviolable):** the existing lossless lane is never modified, paced,
or blocked by translation. The tap is read-only; the xlate ring is a separate
worklet mix input; if translation dies mid-call the call is bit-identical to
today. Flag-off (`?xlate` absent) must be byte-for-byte current behaviour.

Key placement: `ELEVENLABS_API_KEY` is a Worker secret on BOTH configs
(remember: bare `wrangler deploy` hits the shadow worker — prod needs
`-c wrangler.prod.jsonc`). The Worker holds the three vendor sockets per
speaking side and does the STT→MT→TTS orchestration server-side, so the
browser has exactly one extra WS and zero credentials.

Segmentation policy (the real latency lever): translate on Scribe
**committed** segments immediately; additionally force a flush when the
onset detector (already running in the capture path) reports ≥300 ms of
floor-quiet — our turn-taking machinery becomes the interpreter's ear.

## 5. Latency budget — the number we tune

Two honest metrics (never conflate them):

- **Tail lag** `T_tail`: end of a spoken phrase → onset of its translated
  audio at the far ear. Target **p50 ≤ 900 ms, p95 ≤ 1.5 s**.
  Budget: quiet-flush 300 + Scribe commit 150–250 + MT first token ~200 +
  TTS first byte ~200 + our transport/playout ~100–150.
- **Running lag** `T_run`: how far the interpretation trails continuous
  speech. Floor is semantic, not technical — you cannot translate words not
  yet spoken. Target **≤ 2.5 s** sustained, matching good human simultaneous
  interpreters (2–4 s ear-voice span).

Rig discipline (all from hard-won memory): per-stage timestamps stamped at
capture-tick origin; quote the **last third** of the run, not the median;
unknown flags fatal; missing telemetry fields throw, never `?? 0`; n=8
interleaved A/Bs via the ab.mjs pattern; cross-engine (real Safari via
safari-call.mjs) before any claim — Chrome-to-Chrome is not a test.

## 6. Phases (each independently shippable, each measured before the next)

- **P0 — captions-only.** Tap → Scribe → MT → bilingual captions on both
  sides. No TTS, no clone. Proves STT+MT quality/latency on real calls and
  ships visible value in days. Exit: caption `T_tail` p95 < 800 ms on the
  shaped-link rig, both engines.
- **P1 — spoken translation, stock voice.** Flash v2.5 with a fixed voice
  per language. Ducking at −18 dB. Exit: `T_tail` p50 ≤ 900 ms; conceal/
  latency deltas on Lane A vs control = **zero** (Law 0 proof).
- **P2 — voice preservation.** Instant clone from first 20 s of lossless
  capture; rebuilt if the clone confidence is low. Blind AB against stock
  voice for "who is speaking" recognition.
- **P3 — interpreter manners.** Phrase placement vs turn-taking (never talk
  over the speaker's next utterance: TTS chunks yield to live onsets),
  self-monitor, full-duck mode, per-call language memory.

## 7. Cost model (per hour of actual speech, one direction)

~150 wpm ≈ 750 chars/min: TTS $0.05/1k × 45k chars/h ≈ **$2.25/h**;
Scribe realtime ≈ **$0.3–0.5/h**; MT (Haiku-class) ≈ **$0.1–0.3/h**.
Both directions, typical 50/50 talk share → **≈ $3/h of call**. A $20/mo
plan with 10 interpreted hours ≈ 70% gross margin before infra; a $50 plan
is comfortable. Fair-use metering per account from day one, in the Worker.

## 8. Test plan / instruments

- `testbed/xlate-call.mjs` — two synthetic speakers (fixed multilingual WAV
  scripts with known ground-truth translations), shaped link, per-stage
  latency histograms, BLEU/chrF against ground truth for MT drift.
- Mock vendor mode (`XLATE_MOCK=1` in the Worker): echoes STT/TTS with
  configurable synthetic delays, so the *plumbing's* latency share is
  measurable independently of ElevenLabs — the instrument gets an alibi.
- Live: same telemetry.js channel, new `xlate` section; watchdog rule —
  a stage that reports a plausible constant is treated as broken (the
  watchdog must be able to see).

## 9. Open questions parked for data, not debate

1. Flash v2.5 vs Multilingual v2: is +150–250 ms worth the voice quality?
2. Duck depth: −18 dB vs full duck, by listener comprehension test.
3. MT vendor: Haiku vs DeepL vs Gemini Flash on `T_tail` and chrF, n=8.
4. Where TTS audio crosses: relay via Worker (simplest, +1 hop) vs peer
   datagram lane (lowest latency, more client code). P1 ships the relay;
   the datagram lane is an A/B only if relay eats >80 ms of budget.
