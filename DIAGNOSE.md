# Self-diagnosing calls

Goal (2026-08-24): when the user says "a call is bad", the system already knows WHAT is
wrong — per direction, per end — with zero added call latency.

## Status (2026-08-24)

**Server half: built, tested, deployed.** `GET /api/mac/diagnose` is live behind the
existing `MAC_DASH_KEY` gate, `pair` has its own indexed column, and the verdict rules are
pure exported functions so they can be tested without a deploy — `tape-app/diagnose.test.mjs`,
wired into `npm test`. Against today's production beats it returns `unknown` and names the
instruments it lacks; it never returns `healthy` from a rule that could not run.

**Client half: not built.** The exact patch, the field names the server already reads, and
the minimum subset that would have settled the pixelation report are in **VIDEOLOSS.md**,
along with the confirmed root cause of it.

Two corrections to what follows. `probes` was never missing — it has been in every beat
since 0.20.1; the server's `no_probe_count` came from windows holding only `pre_connect`
beats, and that is fixed server-side. And the beat's real size limit was never the request
cap: a truncating `slice` on the fields blob produced *invalid* JSON, which the reader
turned into an empty object, so one oversized beat read as a fully blind end. Both fixed
and covered by tests.

## The finding that unlocks it

The peer's own receive report is ALREADY ON THE WIRE and thrown away.
`Wire.peerRxLost` / `peerRxRecovered` / `peerReportsLoss` (Net.swift:758, set :1028-1030),
piggybacked on every time-sync packet by `appendRxReport` (Net.swift:764-770, offsets
TPKT/TPKT+4, request :651 and reply :1044). It steers picture quality at main.swift:2344-2358
and is then discarded. Putting `peer_rx_lost`, `peer_rx_recovered`, `peer_reports` in the beat
makes every beat carry BOTH directions — one end's beat can then say "the damage is on the
path OUT of me". Highest-value single change in this document.

## Directional rule (why a symmetric rig can never show these)

Receiver-side, measures the INBOUND path: m2e_*, g2g_*, conceal_*, late, near_late, dup,
too_old, recv, accepted, jit, snaps, v_frames_lost, v_partial_drops, v_dec_fails, v_dq_*,
v_shown, v_glass_*, v_dec_ms_p50.
Sender's own view of its OUTBOUND path — NOT evidence about that path: cap_ps, v_enc_ps,
v_mbps, v_bytes_frame, v_quality, v_q_level, v_enc_ms_*, up_mbps, lp_in/out.

## Fields to add (all existing scalars, read once/sec on reportLoop; no new thread,
## no collection shared with callbacks, nothing allocated in a callback)

WIRE (<=9 bytes on the time-sync packet only, ~100 B/s, no new packet type):
  peer_rx_lost, peer_rx_recovered, peer_reports   — already computed, Net.swift:764-770
  peer_played      4 B of the peer's ring.played  — ONE-WAY AUDIO, unanswerable today
  peer_q_level     1 B of the peer's vq.level     — INBOUND pixelation, from either end

BEAT (pure reads of existing globals):
  sig_rms          Audio.swift:257 — mic captured but SILENT (cap_ps counts packets, not sound)
  cap_callbacks    Audio.swift:743 — permission/device vs firing-but-empty (main.swift:2300-2304)
  render_ticks :716, last_render_err :749, mic_muted (Audio.swift:12), cam_off (main.swift:388),
  cam_access (main.swift:570-577)
  echo_corr / echo_delay_ms / erle_db / aec_on / aec_freezes  Audio.swift:377-379, :404-406, :413
    MUST travel with `mute` — main.swift:2016-2024: with no speaker there is no acoustic path
  in_rate / out_rate  Audio.swift:878-883, :952 — the hardcoded-48kHz-went-deaf class
  in_dev_hash / out_dev_hash  32-bit hash of deviceName() (Audio.swift:793), never the name
  v_w / v_h  Video.swift:338-339 (constants) ; v_rx_w / v_rx_h from the decode callback
    (main.swift:1204 already touches the pixel buffer — two Int stores)
  dec_luma  gDecLuma, main.swift:854 — frozen-black vs frozen-picture
  peer_status  0 connected / 1 reconnecting / 2 peer-left (main.swift:774/793/823)
  route  0 LAN / 1 direct-STUN / 2 TURN-relay (Net.swift:718-725, :790) ; turn_ok (main.swift:678-681)
  beat_us_p50 / beat_us_p99  self-cost, same idiom as plcSearchUs (Audio.swift:231)

## Joining the two ends — the blocker

No shared id today: Telemetry.call is per-PROCESS random (Telemetry.swift:34-36) and the
worker DELETES room/secret/peer (worker.ts:1837). Add `pair` = first 8 hex of
SHA-256("tk-pair-v1" || sharedKey), computed ONCE at handshake (Net.swift:959). Both ends
compute the same value; no path back to the room or the key. Do NOT send safetyCode itself —
it is what the two humans read aloud. Worker must allow `pair` past the strip-list and index it.

## Verdicts — server-side in the Health DO, zero client cost

Window = last 3 beats (~15 s). expected = SR/FPP = 1500 pkt/s. Every rule a FRACTION or RATE;
every latency rule subtracts prop = rtt_ms/2 (as calls.js:23-25 already does). No absolute-ms
threshold may contain propagation.

never_connected · no_route · mic_denied · mic_muted · mic_silent · capture_broken · device_wrong
one_way_out (cap_ps healthy AND peer_played ~0) · one_way_in · audio_dropouts_in (conceal/expected
>0.005) · audio_dropouts_out ((peer_rx_lost+recovered)/sent >0.02, same line as main.swift:2378-2383)
starved · high_latency (m2e_p50-prop >40ms) · jittery_audio · echo (corr>0.45 AND mute==0 AND
erle<6) · aec_thrashing · video_frozen_in · video_black_in · video_pixelated_in (peer_q_level at
floor, or v_bytes_frame<1500 with high v_motion) · video_stutter_in · video_low_res_in · video_lag
(g2g_p50-prop >90ms) · path_flapping · peer_left · reconnecting · dropped · crypto_broken ·
version_skew · internal_defect · healthy

## Blindness gate — evaluated FIRST; `healthy` requires passing it

<2 beats -> unknown:insufficient_beats. rtt_ms absent or probes<20 -> latency rules SKIPPED, never
prop=0 (that turns a 300ms antipodal call into a fault). peer_reports==0 -> all *_out verdicts
unknown:no_peer_report, never healthy. v_glass_cov<0.5 -> discard v_glass_ms_p50 (main.swift:2286-2294).
v_encodes==0 and v_frags==0 -> video unknown:video_not_running (a controller once ran 87 of 98 s
with video off, main.swift:2322-2325). Every verdict carries `coverage`; green with
coverage.audio_out=false is not green.

Attribution: one_way_out at end A must appear as one_way_in at end B. If the ends disagree, the
DISAGREEMENT is the finding — say so, do not pick a side.

## Reading it

GET /api/mac/diagnose — fourth entry in the allowlist at worker.ts:2378, behind the existing
dashOK()/MAC_DASH_KEY gate (worker.ts:2329-2334). Optional ?call= / ?pair=; default = calls live
in the last 90 s. Per call: ends[] x {verdict, severity, directions{audio_in,audio_out,video_in}
each with evidence + source, latency{m2e,rtt,prop,overhead,g2g,probes}, coverage{}, agree}.
Privacy unchanged: no room code, no names, device names hashed, install stays a random number.

## Cost proof (must show ZERO)

1. beat_us_p50/p99 self-reported; accept p99 < 200 us against a 1 s cadence.
2. Instruments allocations: render-callback allocation count IDENTICAL beat-on vs --no-telemetry.
3. NULL A/B first (beat-on vs beat-on, arms rotated) on the far-away rig; only a delta exceeding
   that spread counts.
4. Release builds only (-Onone fabricated two 200 ms stalls release did not have).
5. m2e A/B: off/on/off/on, >=5 min arms, real sensors + jitter+loss+bw (never a constant-delay
   pipe), CUMULATIVE counters not moving averages (a 30 s average once INVERTED a result).
6. Prove the flags aren't no-ops (read the new keys back off /api/mac/call?id=), and validate the
   ruler (5 s vs 100 ms cadence must rank differently, else the rig can't certify 1x is free).
7. Wire cost: assert up_mbps unchanged to 2 dp and probes/rtt_ms unchanged — a bigger probe packet
   that shifted the RTT estimate would corrupt the prop term every latency verdict subtracts.
