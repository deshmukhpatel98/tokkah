#!/usr/bin/env python3
"""The lossless cross-check of the bandwidth ruler, on the SAME seconds.

    audiolab-bw.py <tapes of the end that SENT> <tapes of the end that HEARD> <realA.wav> <selftest reading kHz>

The rig used to compare the median of one end's per-beat `a_tx_bw_khz` against
the median of the other end's per-beat `a_rx_bw_khz` and ask for one 1/6-octave
band of agreement. Each beat value is itself a median of five per-second
readings, and on real speech those readings swing between 3.6 and 10.2 kHz from
one second to the next (a sibilant second against a vowel second), so a median
of five sits on a knife edge between two modes; the two ends' beat windows start
at different moments and their final beats do not even agree on how many values
there are (measured 2026-09-11: A's last beat read 3.59, B's had none). The
rulers agreed; the statistic did not, about half the time.

What the wire being lossless actually promises is that the SAME second reads
the same at both ends. The tapes hold that second: `sent.wav` at the end that
spoke and `played.wav` at the end that heard, int16 at 48 kHz, aligned here by
cross-correlating their envelopes. The ruler is the app's definition (Hann 2048
at 50% overlap, 1/6-octave bands from 100 Hz, the highest band within 40 dB of
the 300-3000 Hz core, under a 35 ms-release peak envelope above 0.004 with
segments at least half inside it and 300 ms of envelope per window), and before
it is believed it is CALIBRATED against the shipping binary: fed the second of
realA.wav the app's own `--selftest-audiolab` reads, it must return the same
band centre -- a re-implemented ruler that is not checked against the real one is
a rig that can pass over a broken product.

Rows: calibration; alignment found; at least 90% of aligned seconds within one
band and the median ratio within one band; and the REJECT row -- the heard tape
low-passed at 3.4 kHz must NOT pass the same comparison, or the comparison
cannot see a band-limited copy and a pass means nothing.
"""
import sys, os, glob, math
import numpy as np

SR = 48000
fail = 0
def say(ok, what):
    global fail
    print(f"  {'OK   ' if ok else 'FAIL '} {what}")
    if not ok: fail += 1

def wav_i16(p):
    b = open(p, "rb").read()
    # RIFF: find the data chunk rather than assuming a 44/46-byte header
    i = 12
    while i + 8 <= len(b):
        cid = b[i:i + 4]; n = int.from_bytes(b[i + 4:i + 8], "little")
        if cid == b"data":
            d = b[i + 8:i + 8 + n]; d = d[: len(d) - (len(d) % 2)]
            return np.frombuffer(d, dtype="<i2").astype(np.float32) / 32768.0
        i += 8 + n + (n & 1)
    raise SystemExit(f"no data chunk in {p}")

def envelope_flag(x):
    dec = math.exp(-1.0 / (SR * 0.035))
    ax = np.abs(x).astype(np.float64)
    env = np.empty(len(x)); e = 0.0
    for i in range(len(x)):
        v = ax[i]; e = v if v > e else e * dec; env[i] = e
    return (env > 0.004).astype(np.uint8)

def bandwidth(x, flag):
    N, hop = 2048, 1024
    if len(x) < N or int(flag.sum()) < 14400: return None
    w = np.hanning(N); power = np.zeros(N // 2); segs = 0
    for pos in range(0, len(x) - N + 1, hop):
        if int(flag[pos:pos + N].sum()) * 2 < N: continue
        sp = np.fft.rfft(x[pos:pos + N] * w)[: N // 2]
        power += np.abs(sp) ** 2; segs += 1
    if segs < 6 or power[1:].sum() / segs <= 1e-6: return None
    bin_hz = SR / N; centres, bands = [], []; k = 0
    while True:
        fc = 100.0 * 2 ** (k / 6.0); lo, hi = fc / 2 ** (1 / 12), fc * 2 ** (1 / 12)
        if hi >= SR / 2: break
        b0, b1 = max(1, int(lo / bin_hz)), min(N // 2 - 1, int(hi / bin_hz))
        if b1 >= b0: centres.append(fc); bands.append(power[b0:b1 + 1].mean())
        k += 1
    core = [b for fc, b in zip(centres, bands) if 300 <= fc <= 3000]
    th = np.mean(core) * 1e-4
    for fc, b in reversed(list(zip(centres, bands))):
        if b >= th: return fc / 1000.0
    return None

def lowpass(x, cutoff_hz, taps=601):
    """The selftest's windowed-sinc (Blackman), so the reject row is the app's own known input."""
    M = (taps - 1) // 2; fc = cutoff_hz / SR
    n = np.arange(taps); k = n - M
    sinc = np.where(k == 0, 2 * fc, np.sin(2 * np.pi * fc * k) / (np.pi * np.where(k == 0, 1, k)))
    w = 0.42 - 0.5 * np.cos(2 * np.pi * n / (taps - 1)) + 0.08 * np.cos(4 * np.pi * n / (taps - 1))
    h = sinc * w; h /= h.sum()
    return np.convolve(x, h, mode="same").astype(np.float32)

def rms_env(x, frame=480):
    n = len(x) // frame
    return np.sqrt((x[: n * frame].reshape(n, frame) ** 2).mean(axis=1))

def align(a, b, max_lag_s=8.0):
    """Lag (samples) such that a[k + lag] lines up with b[k], by envelope correlation."""
    ea, eb = rms_env(a), rms_env(b); L = int(max_lag_s * 100)
    n = min(len(ea), len(eb)); ea = ea[:n] - ea[:n].mean(); eb = eb[:n] - eb[:n].mean()
    best, bl = -2.0, 0
    for lag in range(-L, L + 1):
        x, y = (ea[lag:], eb[: n - lag]) if lag >= 0 else (ea[: n + lag], eb[-lag:])
        if len(x) < 100: continue
        c = float(np.dot(x, y) / (np.linalg.norm(x) * np.linalg.norm(y) + 1e-12))
        if c > best: best, bl = c, lag
    return bl * 480, best

def per_second(x, flag):
    n = len(x) // SR
    return [bandwidth(x[k * SR:(k + 1) * SR], flag[k * SR:(k + 1) * SR]) for k in range(n)]

def compare(sent, heard, label, want_pass):
    off, corr = align(sent, heard)
    if want_pass:
        say(corr >= 0.9, f"{label}: the two tapes align (envelope correlation {corr:.2f} at {off / SR:+.3f} s)")
    s2, h2 = (sent[off:], heard) if off >= 0 else (sent, heard[-off:])
    n = min(len(s2), len(h2)) // SR
    s2, h2 = s2[: n * SR], h2[: n * SR]
    fs, fh = envelope_flag(s2), envelope_flag(h2)
    ps, ph = per_second(s2, fs), per_second(h2, fh)
    pairs = [(a, b) for a, b in zip(ps, ph) if a is not None and b is not None]
    if len(pairs) < 10:
        say(False, f"{label}: only {len(pairs)} seconds had a reading at both ends -- nothing to compare"); return
    ratios = [b / a for a, b in pairs]
    within = sum(0.84 <= r <= 1.19 for r in ratios)
    med = float(np.median(ratios))
    ok = within * 10 >= len(pairs) * 9 and 0.84 <= med <= 1.19
    detail = f"{within} of {len(pairs)} aligned seconds within one band, median ratio {med:.3f}"
    if want_pass:
        say(ok, f"{label}: sent and heard read the same second the same way -- {detail}")
    else:
        say(not ok, f"{label}: the heard tape low-passed at 3.4 kHz does NOT read the same -- {detail} -- REJECT row")
    return ps, ph

ta, tb, real_a, want = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
# ── the ruler, against the shipping binary's own reading ─────────────────────
a_file = wav_i16(real_a)
cal = bandwidth(a_file[SR:2 * SR], np.ones(SR, dtype=np.uint8))
say(cal is not None and abs(cal - want) < 0.005,
    f"this ruler reads realA.wav's second second at {cal} kHz; tk --selftest-audiolab read {want} (must be equal)")
say(bandwidth(np.zeros(SR, dtype=np.float32), np.ones(SR, dtype=np.uint8)) is None,
    "and it reports nothing on digital silence -- REJECT row")
# ── the same second at both ends, both directions ────────────────────────────
sentA = wav_i16(glob.glob(os.path.join(ta, "*", "sent.wav"))[0])
playB = wav_i16(glob.glob(os.path.join(tb, "*", "played.wav"))[0])
sentB = wav_i16(glob.glob(os.path.join(tb, "*", "sent.wav"))[0])
playA = wav_i16(glob.glob(os.path.join(ta, "*", "played.wav"))[0])
compare(sentA, playB, "realA, sent by A and heard at B", True)
compare(sentB, playA, "realB, sent by B and heard at A", True)
# ── and the comparison can see a band-limited copy ───────────────────────────
compare(sentA, lowpass(playB, 3400), "realA against a telephone-band copy", False)
print(f"RESULT {fail}")
sys.exit(1 if fail else 0)
