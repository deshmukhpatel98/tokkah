# Audio telemetry: the lab the calls run in

The goal, in the owner's words (2026-09-05): *"I just do the calls, and you look at
the data and keep improving the product. I don't even have to tell you how the
audio felt."*

That sets the bar for every number in this file: it must answer a question a
**listener** would answer, per direction, from a real call, without anybody
describing anything. The counters that already exist (`conceal_*`, `jit`, `aec_*`,
`floor_*`, `turn_*`) describe what the machinery did. The fields below describe
what a person heard, and what left their machine. Both are needed; only the
second kind can replace an ear.

Everything here rides in the ordinary beat (`/api/mac/beat`, and the local copy
at `~/Library/Logs/Kin/beats.ndjson`). Nothing is computed on the audio threads
beyond a counter increment or a memcpy into a preallocated ring; every analysis
runs on the reporter thread or a background thread. Adding a metric may not add
a microsecond to mouth-to-ear.

## Conventions

- Prefix `a_` = audio. `rx` = what this end HEARD (the far voice, as played).
  `tx` = what LEFT this end (this microphone, as it reached the wire).
- `_ms` / `_s` fields are **cumulative** over the call (read the last beat).
- `_db`, `_khz`, `_p50/_p90`, `_swing`, `_corr`, `_lag` fields are **per beat
  window** (the seconds since the previous beat); read them as a series. A window
  with nothing to measure sends **no field** (absent), never 0 — absent and zero
  are different answers (`blind-instruments-report-negatives`).
- Levels are dBFS of a 50 ms RMS frame. "Voiced" is defined per side below.
- Every value is finite; `Telemetry.finite` already guards, but do not rely on it.
- The Durable Object stores `fields` up to **12,000 bytes** (was 8,000; the
  request cap is 16,384). Past that it drops whole fields largest-first and writes
  `fields_dropped`; the reader must shout when it sees that key.

## What this end HEARD (`a_rx_*`)

Far voice activity: `farEnv > 0.004` on the played stream — the same envelope the
duplex gate already keeps (`DuplexGate.noteFar`). Frames: 50 ms, 20/s.

| field | kind | meaning |
|---|---|---|
| `a_rx_voice_ms` | cumul | ms the far voice was active at this speaker. Denominator for the two below. |
| `a_rx_conceal_voiced_ms` | cumul | ms of concealed samples while the far voice was active — the audible kind. |
| `a_rx_conceal_quiet_ms` | cumul | ms concealed while the far end was quiet — free. |
| `a_rx_glitches` | cumul | seams whose worst sample step, within ±64 samples of the seam (`edgeWinMax`, already measured), exceeded `max(0.01, 0.35 × RMS of the last 42 ms of played audio)`. A cross-faded seam on real speech does not count; a zero-fill does. |
| `a_rx_silence_ms` | cumul | ms of received DIGITAL silence (every sample of a packet with abs < 1e-5) while the call is up and not muted by this end — the far end's mute or floor, heard as dead air. |
| `a_rx_clip_pct` | cumul | % of received samples with abs ≥ 0.997 — the far end sent clipped or soft-limited peaks. |
| `a_rx_level_db_p50` | window | median dBFS of voiced 50 ms frames. Absent if fewer than 6 voiced frames. |
| `a_rx_level_db_p90` | window | 90th percentile of the same. |
| `a_rx_level_swing_db` | window | largest abs difference in dB between ADJACENT 1 s voiced means inside the window (needs ≥ 2 such seconds). This is the makeup-gain pumping detector; natural speech at 1 s averaging moves ~3 dB. |
| `a_rx_noise_db` | window | 10th percentile dBFS of frames where the far voice is NOT active and the frame is not digital silence — their room and mic noise as heard here. |
| `a_rx_bw_khz` | window | bandwidth of the far voice (estimator below). Absent if < 300 ms voiced in the window. |
| `a_rate_fast_ms` | cumul | ms the playout governor ran above 1.004 (pitch raised past ~5 cents). |
| `a_rate_max_pct` | lifetime max | largest governor deviation seen, in % (1.012 → 1.2). |

## What LEFT this end (`a_tx_*`)

Near voice: the gate's own decision per block — `aboveEcho && aboveRoom`
(`DuplexGate.process`). A 50 ms frame is voiced if more than half its blocks were.
Measured on the samples AFTER trim, HPF, canceller and gate — i.e. what is handed
to `wire.send` — except where a row says otherwise.

| field | kind | meaning |
|---|---|---|
| `a_tx_voice_ms` | cumul | ms this person was voicing (per the gate's decision). |
| `a_tx_voice_muted_ms` | cumul | ms of that voice during which the effective transmit gain (`gain × yieldGain × floorGain`) was < 0.5 — words that never left. THE walkie-talkie cost, exact. |
| `a_tx_softlimit_pct` | cumul | % of samples with abs > 0.80 as they entered `Wire.softLimit` (the knee) — this voice reached the far end bent. Counted on the float wire format too: a sample past 0.80 meets the same bend at their converter. |
| `a_tx_level_db_p50` | window | median dBFS of voiced frames (post-gate). |
| `a_tx_noise_db` | window | 10th percentile dBFS of UNvoiced frames, measured BEFORE the gate (the trimmed, filtered microphone) — the room noise this microphone sends when open, after makeup. |
| `a_tx_snr_db` | window | `a_tx_level_db_p50 − a_tx_noise_db`. |
| `a_tx_bw_khz` | window | bandwidth of this microphone's voiced audio (pre-gate). Absent if < 300 ms voiced. |

## Did I hear MYSELF (`a_echo_return_*`)

The echo the far end's room sends back: my own voice, inside the stream I
receive, a round trip later. This is the symptom a person reports; `echo_corr` and
`aec_*` are the local cause, not the symptom.

Cross-correlate the last second of what LEFT this end (a new 4 s history of the
post-gate samples handed to the wire) against the received stream (`played`, the
decoded far stream before this end's ear mute, `echoHist` already has it), both
decimated ×8 to 6 kHz by averaging (as `echoEstimator` does), over a lag window of
`[1.2 × m2e_p50 + 10 ms, 3.0 × m2e_p50 + 150 ms]` clamped to `[20, 1500] ms`; if
`m2e_p50` is unknown use `[20, 600] ms`. Once per second, on the estimator thread.
Only when the sent window contains voice (RMS > −45 dBFS).

| field | kind | meaning |
|---|---|---|
| `a_echo_talk_s` | cumul | seconds of 1 s windows in which this end was voicing (denominator). |
| `a_echo_return_s` | cumul | seconds of those in which a return was detected: normalised correlation peak ≥ 0.20 (see below). |
| `a_echo_return_corr` | window | the peak normalised correlation of the latest computation. |
| `a_echo_return_db` | window | level of the returning copy relative to the sent voice: `20·log10(|regression gain at the peak lag|)`. Absent if not detected. |
| `a_echo_return_lag_ms` | window | lag of the peak, ms. Absent if not detected. |

Known inputs it must pass (`--selftest-audiolab`): sent = 3 s of `realA.wav`,
received = 0.30 × sent delayed 350 ms + `realB.wav` at equal level → detected,
lag 350 ± 5 ms, level −10.5 ± 2 dB. Received = `realB.wav` alone → NOT detected.
Received = silence → not detected, and no field. Two rejects, because a detector
that cannot say no is not a detector. The detection line is a normalised
correlation of **0.20**: a −10 dB return under an equal-level far voice can only
reach ~0.29, and the null (an unrelated voice, best of 9000 lags over one
second) measured 0.06.

## The bandwidth ruler (`*_bw_khz`)

On ≥ 300 ms of voiced audio in the window: Hann 2048-point FFTs at 50% overlap
over segments at least half inside the voice's envelope, averaged power spectrum, 1/6-octave
bands from 100 Hz to the last band under 24 kHz. The reference is the mean band
power of the voice's own core, 300–3000 Hz. Report the highest band centre (kHz)
whose power is within 40 dB of that core, searching downward. (A first version
also admitted any band 15 dB above the quietest band; on a 3.4 kHz low-passed
voice the quietest band was the filter's −90 dB stopband at 20 kHz, so −60 dB
transition residue at 5 kHz counted and a telephone band read 5.1 kHz. Inaudible
energy is not bandwidth.) Known inputs: `realA.wav` untouched → ≥ 8 kHz; the same
file through a 7 kHz windowed-sinc low-pass → 6–8 kHz; through a 3.4 kHz low-pass
→ 3–4 kHz; white noise → ≥ 18 kHz; digital silence → absent (must not report a
number); under 300 ms of voice → absent. The last two are the rejects.

The flag the ruler runs under is the voice's own **envelope** (peak, 35 ms release,
above 0.004), not the gate's verdict: the gate calls "voice" on the loud cores of
syllables, and a ruler fed only vowels read 4.0 kHz live on speech the whole-second
ruler read at 9 — the consonants carry the bandwidth. On the rx side that envelope
is `farEnv`; on the tx side it is kept beside the tx analysis ring (`txEnv`). A
segment counts when at least half of it is inside the envelope (the quiet half is
the same voice trailing off), and the window needs 300 ms of envelope in total.
The selftest holds this with a row that runs the same speech under the live flag.
This is the ruler that tells a Bluetooth headset in phone mode (16 kHz mono, band
to 7–8 kHz; or CVSD, 4 kHz) from a real microphone, from the data alone.

## What it was running on (facts, strings)

Into `Metrics.fact` so they land in `facts` beside `output_route`, `cam`, `venc`:

| fact | example |
|---|---|
| `in_dev` / `out_dev` | `MacBook Air Microphone` / `EarPods` |
| `in_transport` / `out_transport` | `builtin`, `usb`, `bluetooth`, `bluetooth-le`, `hdmi`, `displayport`, `aggregate`, `virtual`, `thunderbolt`, `other:<hex>` |
| `in_rate_hw` / `out_rate_hw` | the device's nominal rate as READ BACK after `forceSampleRate` |
| `in_ch` / `out_ch` | channels in the device's stream configuration |
| `in_rates` | the device's available nominal rates, e.g. `8000,16000,44100,48000` |
| `bt_hfp` | `yes` if either device is Bluetooth and its stream is mono or its nominal rate ≤ 16000 — the headset-profile trap that turns every listening test into a telephone; else `no` |

And fix the numbers that already exist and read 0 on live calls: `in_rate` /
`out_rate` (`hwInRate` / `hwOutRate`) are set only in the first start path
(Audio.swift ~4848) and never in the `openUnit`-style path at ~4980 that every
live call takes. Set them in both.

## Tapes: the audio itself, on the lab machines (`lab`)

Numbers answer the questions somebody thought to ask. The audio answers the rest.
When **lab mode** is on, every call is taped to
`~/Library/Logs/Kin/tapes/<callId>/` (override: `TK_TAPES_DIR`) and never leaves
the machine:

| file | content |
|---|---|
| `raw.wav` | 48 kHz mono **float32** WAV: the microphone after trim and HPF, before echo-sim, canceller and gate — what the mic heard. Float because a hot mic peaks above 1.0 and that is information. |
| `sent.wav` | 48 kHz mono **int16** WAV: exactly the samples handed to the wire per packet, after gate/floor/mute, after `softLimit` and quantisation (`histPtr` when `sendPcm16`, else the float clamped). What they heard of me, before the network. |
| `played.wav` | 48 kHz mono **int16** WAV: `emitted` — what left this speaker (after presence and the ear ramp; the rig flags `mute`/`roomSpeakerOff` do NOT zero it). What I heard. |
| `render.bin` | one 32-byte little-endian record per render callback: `u64 host_ns, f64 ring_pos, u16 n, u16 concealed_n, f32 rate, f32 ear_gain, 4 bytes pad`. Marks every concealed sample and the governor's pitch, so network damage can be located inside `played.wav`. |
| `capture.bin` | one 32-byte record per sent packet: `i32 seq, u64 cap_host_ns, f32 tx_gain_mean, u8 muted, u8 voiced, 14 bytes pad`. Locates every word the floor or gate removed inside `raw.wav`. |
| `meta.json` | call id, install, version, start host time and wall time, SR, device facts, `record_formats` describing the two binaries, and at the end: duration, samples per stream, `dropped` per stream, `full` flags. |

Rules:
- Audio threads only memcpy into preallocated 2 s rings (one per stream, plus the
  two record rings). One background thread (QoS utility) drains every 250 ms.
- A ring that fills STOPS that stream and counts it (`tape_full` in the beat,
  `full` in meta). It never wraps — a wrapped tape splices two moments into one
  and reads as a glitch that never happened (same rule as `startDump`).
- Retention at call start: keep the newest **3** tape directories and at most
  **3 GB** total; delete the oldest first. One call stops taping at **60 min**.
- Enable: `lab.json` in `Identity.dir` (`TK_KIN_DIR` honoured), shape
  `{"tapes": true, "source": "cli"|"server", "at": "<iso>"}`.
  `tk --lab on|off` writes it and exits 0 printing the state; `tk --lab` alone
  prints the state. `--no-tapes` disables taping for that process (the rig's
  control arm). The call process reads the file once at start.
- The server can flip it: the reply to `/api/mac/beat` is `{"ok":true,"lab":0|1}`
  and `Telemetry.post` applies a change (`Lab.set(tapes:source:"server")`), so
  the owner's Macs need no command typed on them. Only the allowlisted installs in
  `tape-app/src/worker.ts` (`LAB_INSTALLS`) ever receive `lab:1`; everyone else
  receives `lab:0`, and a Mac never in lab mode is unaffected by `0`.
- Beat: facts `lab` (`on`/`off`), `tapes` (`recording`/`off`/`full`/`failed`),
  `tape_dir`; numbers `tape_bytes`, `tape_full` (0/1).

Consumer surface: nothing. No row, no icon, no word.

## The reader

`mac/tools/telemetry.sh pair <id>` prints, per end, after the existing groups:

```
HEARD     clean 99.2% of their voice · 0.4 glitches/min · dead air 3.1 s · level -24 dBFS (swing 2 dB) · band 14 kHz · pitch-up 0 s
SAID      talked 142 s · 2.3 s of your words never left · soft-limited 0.0% · noise -58 dBFS (SNR 34 dB) · band 12 kHz · trim 0.42
RETURN    heard yourself 0% of your talking
DEVICES   in "MacBook Air Microphone" builtin 48000/1ch · out "EarPods" usb 48000/2ch · phone-mode no · mic mode standard · route headphones
VERDICT   you heard them: clear · they heard you: 2.3 s of words lost to the floor
```

First-cut verdict rules (in `telemetry.py`, one place, easy to move):

| direction | word | rule |
|---|---|---|
| heard | clear | conceal_voiced/voice < 1% and glitches/min < 2 and swing ≤ 6 dB and band ≥ 8 kHz and clip < 0.1% |
| heard | a few patches | conceal_voiced/voice 1–3% |
| heard | patchy | > 3% |
| heard | clicks | glitches/min ≥ 3 |
| heard | pumping | swing > 6 dB |
| heard | telephone-grade | band < 4.5 kHz (no "dull" word: the ruler moves one band with content; a wideband headset is caught by `bt_hfp`) |
| heard | distorted | clip ≥ 0.1% |
| heard | dead air N s | silence_ms |
| heard | sped up N s | rate_fast_ms > 2000 |
| said | N s of words lost to the floor | tx_voice_muted_ms |
| said | went out distorted | softlimit ≥ 0.5% |
| said | noisy mic | snr < 20 dB |
| said | telephone-grade mic | tx band < 4.5 kHz |
| return | heard yourself N% at −X dB | return_s/talk_s ≥ 5% |

The `recent` table gains one column, `heard`, = clean % of their voice (blank when
the build predates the field — "not in this build" is a different answer from 0).
`fields_dropped` present → a line in capitals: the server truncated this record.

`mac/tools/tape-report.py <tape dir>` (numpy) reads a tape and prints: per stream
duration, level histogram, noise floor, bandwidth, clip/knee counts, DC offset;
from `render.bin` the concealed ms split by voiced/quiet and the governor's
pitch-up time; from `capture.bin` the seconds of voiced audio with `tx_gain_mean`
< 0.5 and where they are; the echo return between `sent.wav` and `played.wav`
(same estimator as the app, lag window given or `--lag-ms a:b`); a glitch scan of
`played.wav` (sample steps > 0.35 × local RMS, listed with timestamps).

## Rigs that hold this

`tk --selftest-audiolab`: every ruler above on its known inputs, including the
rejects, plus the WAV writer round trip (1 s written, read back sample-exact for
both formats), `lab.json` round trip, and retention pruning (5 fake dirs → 3).

`mac/tools/audiolab-check.sh`: two real ends of a live loopback call
(`--audio realA.wav` / `--audio realB.wav`, `--mute`, `--no-floor`, `--no-aec`,
`--route speakers`, beats to `beat-sink.py`), end B with `--echo-sim 22:0.55`, tapes
on through `TK_KIN_DIR` + `TK_TAPES_DIR`. Asserts: every field in this file is
present and finite on both ends; `a_rx_voice_ms` and `a_tx_voice_ms` grow;
`a_rx_bw_khz` and `a_tx_bw_khz` ≥ 8; end A's `a_echo_return_s` > 1 and end B's
< 0.5 (B's voice never returns — the reject); tapes exist for both ends with
durations within 2 s of the call, `render.bin` record count within 5% of
duration × 3000, concealed samples in `render.bin` equal to the beat's
`conceal_total × FPP` within 1%; a third end run with `--no-tapes` writes no
directory, and a fourth with no `lab.json` writes none; callback cost with tapes
on stays under 100 µs p99 (the stat line already prints it).
