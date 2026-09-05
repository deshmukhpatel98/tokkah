#!/usr/bin/env python3
"""Read a Kin tape (mac/TELEMETRY-AUDIO.md, "Tapes") and say what is in it.

    tools/tape-report.py <tape dir> [--lag-ms a:b]
    tools/tape-report.py --selftest

A tape is the audio itself -- the microphone as heard (raw.wav, float32), what
left for the wire (sent.wav, int16), what left the speaker (played.wav, int16) --
plus two timelines: one record per render callback (where every concealed sample
fell, what the playout governor did to the pitch) and one per sent packet (what
the gate did to every word). The beat's numbers answer the questions somebody
thought to ask; this answers the rest, after the fact, from the same call.

numpy only. The rulers here are the same definitions the app applies live
(AudioLab.swift), so a disagreement between this report and a beat is a finding.
"""
import json, os, struct, sys, tempfile, wave
import numpy as np

SR = 48000

# ── files ────────────────────────────────────────────────────────────────────

def read_wav(path):
    """int16 via the stdlib; float32 (format tag 3) by hand -- `wave` refuses it."""
    with open(path, "rb") as f:
        head = f.read(12)
        if head[:4] != b"RIFF" or head[8:12] != b"WAVE":
            raise ValueError(f"{path}: not a WAV")
        fmt = None; data = None
        while True:
            ch = f.read(8)
            if len(ch) < 8: break
            cid, size = ch[:4], struct.unpack("<I", ch[4:8])[0]
            if cid == b"fmt ":
                body = f.read(size)
                tag, nch, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
                fmt = (tag, nch, rate, bits)
            elif cid == b"data":
                data = f.read(size)
            else:
                f.seek(size, 1)
        if fmt is None or data is None:
            raise ValueError(f"{path}: missing fmt or data")
    tag, nch, rate, bits = fmt
    if tag == 3 and bits == 32:
        x = np.frombuffer(data, dtype="<f4").astype(np.float64)
    elif tag == 1 and bits == 16:
        x = np.frombuffer(data, dtype="<i2").astype(np.float64) / 32767.0
    else:
        raise ValueError(f"{path}: unsupported format tag {tag} / {bits} bits")
    if nch > 1: x = x[::nch]
    return x, rate

RENDER = np.dtype([("host_ns", "<u8"), ("pos", "<f8"), ("n", "<u2"), ("concealed", "<u2"),
                   ("rate", "<f4"), ("ear", "<f4"), ("pad", "<u4")])
CAPTURE = np.dtype([("seq", "<i4"), ("cap_ns", "<u8"), ("gain", "<f4"), ("muted", "u1"),
                    ("voiced", "u1"), ("pad2", "<u2"), ("pad8", "<u8"), ("pad4", "<u4")])
assert RENDER.itemsize == 32 and CAPTURE.itemsize == 32

def read_records(path, dtype):
    if not os.path.exists(path): return np.zeros(0, dtype=dtype)
    b = open(path, "rb").read()
    n = len(b) // 32
    return np.frombuffer(b[:n * 32], dtype=dtype)

# ── rulers (the app's definitions) ───────────────────────────────────────────

def frame_db(x, frame=2400):
    n = len(x) // frame
    if n == 0: return np.zeros(0)
    fr = x[:n * frame].reshape(n, frame)
    rms = np.sqrt(np.mean(fr * fr, axis=1))
    return 20 * np.log10(rms + 1e-9)

def bandwidth_khz(x):
    """Highest 1/6-octave band within 40 dB of the 300-3000 Hz core, on Hann 2048
    at 50% overlap. None when there is nothing to measure."""
    N, hop = 2048, 1024
    if len(x) < N: return None
    w = np.hanning(N)
    segs = (len(x) - N) // hop + 1
    if segs < 6: return None
    idx = np.arange(N)[None, :] + hop * np.arange(segs)[:, None]
    spec = np.fft.rfft(x[idx] * w, axis=1)
    power = np.mean(np.abs(spec) ** 2, axis=0)
    if np.sum(power[1:]) / 1.0 < 1e-6 * segs: return None
    bin_hz = SR / N
    centres, bands = [], []
    k = 0
    while True:
        fc = 100.0 * 2 ** (k / 6.0)
        lo, hi = fc / 2 ** (1 / 12), fc * 2 ** (1 / 12)
        if hi >= SR / 2: break
        b0, b1 = max(1, int(lo / bin_hz)), min(N // 2 - 1, int(hi / bin_hz))
        if b1 >= b0:
            centres.append(fc); bands.append(np.mean(power[b0:b1 + 1]))
        k += 1
    core = [b for fc, b in zip(centres, bands) if 300 <= fc <= 3000]
    if not core: return None
    thresh = np.mean(core) * 1e-4
    for fc, b in reversed(list(zip(centres, bands))):
        if b >= thresh: return fc / 1000.0
    return None

def decimate8(x):
    n = len(x) // 8
    return x[:n * 8].reshape(n, 8).mean(axis=1)

def echo_return(sent, recv, lag_min, lag_max):
    """Normalised cross-correlation of `sent` (W) against `recv` (>= W + lag_max),
    return of sent[i] at lag L being recv[i + L]. (corr, gain_db, lag) or None."""
    W = len(sent)
    if W == 0 or len(recv) < W + lag_max or lag_max < lag_min: return None
    sE = float(np.dot(sent, sent))
    if sE <= 0: return None
    # num[L] = sum_i sent[i] * recv[i+L] for L in 0..lag_max, via FFT correlation.
    L = lag_max + 1
    n = 1
    while n < len(recv) + W: n <<= 1
    S = np.fft.rfft(sent, n); R = np.fft.rfft(recv, n)
    num = np.fft.irfft(np.conj(S) * R, n)[:L]
    sq = np.concatenate([[0.0], np.cumsum(recv * recv)])
    rE = sq[W:W + L] - sq[:L]
    with np.errstate(divide="ignore", invalid="ignore"):
        corr = num / np.sqrt(sE * np.maximum(rE, 1e-12))
    corr[rE <= 1e-12] = -1
    lags = np.arange(L)
    ok = lags >= lag_min
    if not np.any(ok): return None
    best = int(np.argmax(np.where(ok, corr, -2)))
    gain = num[best] / sE
    return float(corr[best]), float(20 * np.log10(max(abs(gain), 1e-9))), best

def glitch_scan(x, rr, thresh_rel=0.35, floor=0.01, win=2048, merge_ms=5.0):
    """The app's own definition (AudioLab.seam): at every SEAM -- a callback where
    concealment began or ended, located from render.bin -- the worst sample step
    within +-64 samples, against max(0.01, 0.35 x RMS of the 42 ms before the
    seam). Only seams: real speech is heavy-tailed (a plosive burst measured 48
    step-sigmas on a clean tape) and any per-sample statistic flagged hundreds of
    'glitches' the ear never heard. Without concealment there is no seam, and
    the honest count is zero."""
    if len(rr) == 0 or len(x) < win + 130: return []
    n = rr["n"].astype(np.int64)
    starts = np.concatenate([[0], np.cumsum(n)[:-1]])
    conc = rr["concealed"] > 0
    edges = np.flatnonzero(conc[1:] != conc[:-1]) + 1      # callbacks where the state flips
    steps = np.abs(np.diff(x))
    out = []
    merge = int(merge_ms / 1000 * SR)
    for e in edges:
        p = int(starts[e])
        lo, hi = max(1, p - 64), min(len(steps), p + 64)
        if hi <= lo: continue
        pre = x[max(0, lo - win):lo]
        rms = float(np.sqrt(np.mean(pre * pre))) if len(pre) else 0.0
        step = float(np.max(steps[lo:hi]))
        if step > max(floor, thresh_rel * rms):
            if out and p - out[-1][0] <= merge: out[-1] = (out[-1][0], max(out[-1][1], step))
            else: out.append((p, step))
    return [(p / SR, s) for p, s in out]

# ── the report ───────────────────────────────────────────────────────────────

def report(d, lag_ms=(20, 1500), out=print):
    meta = json.load(open(os.path.join(d, "meta.json"))) if os.path.exists(os.path.join(d, "meta.json")) else {}
    out(f"tape {d}")
    if meta:
        out(f"  call {meta.get('call')}  version {meta.get('version')}  started {meta.get('started_wall')}"
            f"  duration {meta.get('duration_s', float('nan')):.1f} s  full {meta.get('full')}")
        f = meta.get("facts") or {}
        if f:
            out(f"  devices in \"{f.get('in_dev')}\" {f.get('in_transport')} · out \"{f.get('out_dev')}\" {f.get('out_transport')}"
                f" · phone-mode {f.get('bt_hfp')} · route {f.get('output_route')}")
    streams = {}
    for name in ("raw.wav", "sent.wav", "played.wav"):
        p = os.path.join(d, name)
        if not os.path.exists(p): out(f"  {name}: missing"); continue
        x, rate = read_wav(p)
        streams[name] = x
        fdb = frame_db(x)
        voiced = fdb > -50
        hist, edges = np.histogram(fdb[np.isfinite(fdb)], bins=np.arange(-100, 5, 5))
        top = ", ".join(f"{int(edges[i])}:{hist[i]}" for i in np.argsort(hist)[::-1][:4] if hist[i])
        # The bandwidth ruler over the voiced frames only; the last partial frame
        # has no verdict and is left out.
        mask = np.zeros(len(x), dtype=bool)
        mask[:len(voiced) * 2400] = np.repeat(voiced, 2400)
        bw = bandwidth_khz(x[mask]) if voiced.any() else None
        out(f"  {name:10s} {len(x)/rate:7.1f} s  level p50 {np.median(fdb[voiced]) if voiced.any() else float('nan'):6.1f} dBFS"
            f"  noise p10 {np.percentile(fdb[~voiced], 10) if (~voiced).any() else float('nan'):6.1f}"
            f"  band {bw if bw is None else round(bw, 1)} kHz"
            f"  clip {np.mean(np.abs(x) >= 0.997) * 100:.3f}%  knee {np.mean(np.abs(x) > 0.80) * 100:.3f}%"
            f"  dc {np.mean(x):+.4f}  frames(dB:count) {top}")
    rr = read_records(os.path.join(d, "render.bin"), RENDER)
    if len(rr):
        conc = int(rr["concealed"].sum())
        played = streams.get("played.wav")
        cv = cq = 0
        if played is not None and conc:
            # Locate concealed samples in played.wav by cumulative callback length.
            starts = np.concatenate([[0], np.cumsum(rr["n"].astype(np.int64))[:-1]])
            fdb = frame_db(played)
            for s, n, c in zip(starts[rr["concealed"] > 0], rr["n"][rr["concealed"] > 0], rr["concealed"][rr["concealed"] > 0]):
                fi = min(len(fdb) - 1, int(s // 2400)) if len(fdb) else 0
                if len(fdb) and fdb[fi] > -50: cv += int(c)
                else: cq += int(c)
        fast = int(rr["n"][rr["rate"] > 1.004].sum())
        out(f"  render.bin {len(rr)} callbacks · concealed {conc / SR * 1000:.0f} ms"
            + (f" (voiced {cv / SR * 1000:.0f} ms, quiet {cq / SR * 1000:.0f} ms)" if conc else "")
            + f" · pitch-up (rate > 1.004) {fast / SR:.1f} s · max rate {rr['rate'].max():.4f}"
            + f" · ear closed {np.mean(rr['ear'] < 0.5) * 100:.0f}% of callbacks")
    cr = read_records(os.path.join(d, "capture.bin"), CAPTURE)
    if len(cr):
        v = cr["voiced"] == 1
        m = v & (cr["gain"] < 0.5)
        ranges = []
        if m.any():
            i = np.flatnonzero(m)
            breaks = np.flatnonzero(np.diff(i) > 1)
            starts = np.concatenate([[i[0]], i[breaks + 1]]); ends = np.concatenate([i[breaks], [i[-1]]])
            t0 = cr["cap_ns"][0]
            ranges = [((cr["cap_ns"][a] - t0) / 1e9, (cr["cap_ns"][b] - t0) / 1e9) for a, b in zip(starts, ends)]
        out(f"  capture.bin {len(cr)} packets · voiced {v.sum() * 32 / SR:.1f} s"
            f" · voiced under half gain {m.sum() * 32 / SR:.1f} s in {len(ranges)} stretch(es)"
            + (": " + ", ".join(f"{a:.1f}-{b:.1f}s" for a, b in ranges[:8]) + (" …" if len(ranges) > 8 else "") if ranges else "")
            + f" · muted packets {int(cr['muted'].sum())}")
    if "sent.wav" in streams and "played.wav" in streams:
        # The two streams do not start at the same instant: capture and render
        # begin on their own callbacks. The timelines say when sample 0 of each
        # was at the transducer, so a lag measured between file positions is
        # corrected to a lag in TIME before it is searched or reported.
        shift_s = 0.0
        if len(rr) and len(cr):
            shift_s = (int(rr["host_ns"][0]) - int(cr["cap_ns"][0])) / 1e9   # played0 - sent0
        s8, r8 = decimate8(streams["sent.wav"]), decimate8(streams["played.wav"])
        W = 6000
        shift = int(round(shift_s * 6000))
        lag_min = max(0, int(lag_ms[0] / 1000 * 6000) - shift)
        lag_max = max(lag_min + 1, int(lag_ms[1] / 1000 * 6000) - shift)
        talk = found = 0
        hits = []
        for start in range(0, len(s8) - W - lag_max, W):
            seg = s8[start:start + W]
            if np.sqrt(np.mean(seg * seg)) <= 0.0056: continue
            talk += 1
            r = echo_return(seg, r8[start:start + W + lag_max], lag_min, lag_max)
            if r and r[0] >= 0.20:
                found += 1; hits.append((start / 6000.0, r[0], r[1], (r[2] + shift) / 6.0))
        if talk:
            line = f"  echo return: heard myself in {found} of {talk} talking seconds"
            if abs(shift_s) > 0.0005: line += f" (streams offset {shift_s * 1000:+.1f} ms, corrected)"
            if hits:
                med_db = float(np.median([h[2] for h in hits])); med_lag = float(np.median([h[3] for h in hits]))
                line += f" · level {med_db:.1f} dB · lag {med_lag:.0f} ms · e.g. " + ", ".join(f"{t:.0f}s({c:.2f})" for t, c, _, _ in hits[:5])
            out(line)
        else:
            out("  echo return: this end never talked loudly enough to measure")
    if "played.wav" in streams:
        g = glitch_scan(streams["played.wav"], rr)
        out(f"  glitches in played.wav: {len(g)} (at concealment seams, the app's definition)"
            + (" · " + ", ".join(f"{t:.2f}s(step {s:.2f})" for t, s in g[:10]) + (" …" if len(g) > 10 else "") if g else ""))
    return {"streams": streams, "render": rr, "capture": cr}

# ── selftest: a fake tape with known faults, and a clean one ─────────────────

def write_wav(path, x, float32):
    if float32:
        data = x.astype("<f4").tobytes(); tag, bps = 3, 4
    else:
        data = np.clip(np.round(x * 32767), -32767, 32767).astype("<i2").tobytes(); tag, bps = 1, 2
    hdr = (b"RIFF" + struct.pack("<I", 4 + 26 + 8 + len(data)) + b"WAVE" + b"fmt " + struct.pack("<I", 18)
           + struct.pack("<HHIIHHH", tag, 1, SR, SR * bps, bps, bps * 8, 0) + b"data" + struct.pack("<I", len(data)))
    open(path, "wb").write(hdr + data)

def voice_like(seconds, f0=140.0, seed=1, harmonics=11):
    """A voice-shaped test signal that is NOT periodic: harmonics of a wobbling
    pitch under a random syllable envelope. A perfectly periodic 'voice' correlates
    with itself at every multiple of its period, and the first version of this
    selftest found its planted 350 ms echo at 600 ms with a straight face."""
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    t = np.arange(n) / SR
    # Pitch wobble: a slow random walk of +-8%.
    wob = np.cumsum(rng.standard_normal(n)) ; wob = wob / (np.max(np.abs(wob)) + 1e-9) * 0.08
    phase = 2 * np.pi * np.cumsum(f0 * (1 + wob)) / SR
    x = np.zeros(n)
    for h in range(1, harmonics + 1):
        x += np.sin(h * phase + rng.uniform(0, 6.28)) / h
    # Syllable envelope: low-passed noise, never below 0.15 so every second talks.
    e = rng.standard_normal(n)
    k = np.ones(int(0.06 * SR)) / int(0.06 * SR)
    e = np.convolve(e, k, mode="same"); e = np.convolve(e, k, mode="same")
    e = 0.15 + 0.85 * (e - e.min()) / (e.max() - e.min() + 1e-9)
    x = x * e
    return 0.2 * x / np.max(np.abs(x)) + 0.0005 * rng.standard_normal(n)

def lowpass(x, cutoff, taps=601):
    n = np.arange(taps) - (taps - 1) / 2
    h = 2 * cutoff / SR * np.sinc(2 * cutoff / SR * n) * np.blackman(taps)
    h /= h.sum()
    return np.convolve(x, h, mode="valid")

def selftest():
    fail = 0
    def say(ok, what):
        nonlocal fail
        print(f"  {'ok   ' if ok else 'FAIL '} {what}")
        if not ok: fail += 1
    print("tape-report selftest")
    lines = []
    def build(d, faulty):
        secs = 20
        sent = voice_like(secs, 140.0, 1)
        far = voice_like(secs, 190.0, 2)                                    # equal level, unrelated voice
        played = far.copy()
        lag = int(0.350 * SR)
        if faulty:
            played[lag:] += 0.30 * sent[:-lag]
        n_cb = secs * 3000
        rr = np.zeros(n_cb, dtype=RENDER)
        rr["n"] = 16; rr["rate"] = 1.0; rr["ear"] = 1.0
        rr["host_ns"] = np.arange(n_cb) * 333_333
        rr["pos"] = np.arange(n_cb) * 16.0
        if faulty:
            # 400 ms concealed starting at 5.0 s: 1200 callbacks of 16 samples.
            c0 = 5 * 3000
            rr["concealed"][c0:c0 + 1200] = 16
            played[5 * SR:5 * SR + 19200] = 0
            # two zero-fill glitches: a 32-sample gap at 8.0 s and 12.0 s, aligned
            # to a callback boundary and MARKED as concealed in render.bin -- in the
            # app every concealed sample is marked, so a seam is where a glitch
            # can be. Placed on the loudest callback within 10 ms so the edge is
            # a real edge.
            for g in (8, 12):
                cb0 = g * 3000
                cb = cb0 + int(np.argmax([np.max(np.abs(played[(cb0 + k) * 16:(cb0 + k) * 16 + 16])) for k in range(30)]))
                played[cb * 16:cb * 16 + 32] = 0
                rr["concealed"][cb:cb + 2] = 16
            rr["rate"][10 * 3000:12 * 3000] = 1.010
        cr = np.zeros(secs * 1500, dtype=CAPTURE)
        cr["seq"] = np.arange(len(cr)); cr["cap_ns"] = np.arange(len(cr)) * 666_666
        cr["gain"] = 1.0; cr["voiced"] = 1
        if faulty:
            cr["gain"][3 * 1500:int(4.5 * 1500)] = 0.2
        write_wav(os.path.join(d, "raw.wav"), sent * 1.5, True)
        write_wav(os.path.join(d, "sent.wav"), sent, False)
        write_wav(os.path.join(d, "played.wav"), played, False)
        rr.tofile(os.path.join(d, "render.bin")); cr.tofile(os.path.join(d, "capture.bin"))
        json.dump({"call": "selftest", "version": "0", "duration_s": secs, "full": {}}, open(os.path.join(d, "meta.json"), "w"))
    with tempfile.TemporaryDirectory() as tmp:
        fd = os.path.join(tmp, "faulty"); os.makedirs(fd); build(fd, True)
        text = []
        report(fd, out=text.append)
        joined = "\n".join(text)
        er = [l for l in text if l.startswith("  echo return")]
        say(er and "heard myself in" in er[0] and " 0 of" not in er[0], f"echo return found: {er[0].strip() if er else 'no line'}")
        import re
        m = re.search(r"level (-?[\d.]+) dB · lag (\d+) ms", er[0]) if er else None
        say(m and abs(float(m.group(1)) - (-10.46)) <= 2 and abs(int(m.group(2)) - 350) <= 5, f"return level/lag within tolerance ({m.groups() if m else None})")
        rl = [l for l in text if l.startswith("  render.bin")][0]
        m = re.search(r"concealed (\d+) ms", rl)
        say(m and abs(int(m.group(1)) - 400) <= 10, f"concealed ms 400 ± 10 ({m.group(1) if m else None})")
        m = re.search(r"pitch-up \(rate > 1.004\) ([\d.]+) s", rl)
        say(m and abs(float(m.group(1)) - 2.0) <= 0.1, f"pitch-up seconds 2.0 ± 0.1 ({m.group(1) if m else None})")
        cl = [l for l in text if l.startswith("  capture.bin")][0]
        m = re.search(r"under half gain ([\d.]+) s", cl)
        say(m and abs(float(m.group(1)) - 1.5) <= 0.05, f"voiced under half gain 1.5 ± 0.05 s ({m.group(1) if m else None})")
        gl = [l for l in text if l.startswith("  glitches")][0]
        m = re.search(r"glitches in played.wav: (\d+)", gl)
        # 2 planted gaps (each an entry and an exit), plus the 400 ms hole's two edges.
        times = [float(x) for x in re.findall(r"(\d+\.\d+)s\(step", gl)]
        say(m and int(m.group(1)) >= 2 and any(abs(t - 8.0) < 0.02 for t in times) and any(abs(t - 12.0) < 0.02 for t in times),
            f"glitches at the planted seams ({gl.strip()[:140]})")
        say(m and int(m.group(1)) <= 8, f"and no glitches away from the seams ({m.group(1) if m else None} total, 6 seams planted) -- REJECT row")
        # bandwidth rulers on known inputs: a voice with harmonics to the top of the
        # band reads full; the same voice through a 3.4 kHz low-pass reads 3-4.
        white = np.random.default_rng(3).uniform(-0.3, 0.3, SR)
        say((bandwidth_khz(white) or 0) >= 18, f"bandwidth: white noise {bandwidth_khz(white)} kHz (>= 18)")
        rich = voice_like(2, 140.0, 4, harmonics=160)
        say((bandwidth_khz(rich[:SR]) or 0) >= 15, f"bandwidth: a harmonic-rich voice {bandwidth_khz(rich[:SR])} kHz (>= 15)")
        lp = lowpass(rich, 3400)
        say(3 <= (bandwidth_khz(lp[:SR]) or 0) <= 4.1, f"bandwidth: the same through a 3.4 kHz low-pass {bandwidth_khz(lp[:SR])} kHz (3-4)")
        say(bandwidth_khz(np.zeros(SR)) is None, "bandwidth: silence reports None -- REJECT row")
        cd = os.path.join(tmp, "clean"); os.makedirs(cd); build(cd, False)
        text = []
        report(cd, out=text.append)
        er = [l for l in text if l.startswith("  echo return")]
        say(er and re.search(r"heard myself in 0 of \d+", er[0]) is not None, f"clean tape: no echo return ({er[0].strip() if er else 'no line'}) -- REJECT row")
        rl = [l for l in text if l.startswith("  render.bin")][0]
        say("concealed 0 ms" in rl and "pitch-up (rate > 1.004) 0.0 s" in rl, "clean tape: no concealment, no pitch-up -- REJECT row")
        cl = [l for l in text if l.startswith("  capture.bin")][0]
        say("under half gain 0.0 s" in cl, "clean tape: no words under half gain -- REJECT row")
        gl = [l for l in text if l.startswith("  glitches")][0]
        say("glitches in played.wav: 0" in gl, "clean tape: no glitches -- REJECT row")
    print(f"tape-report selftest: {'PASS' if fail == 0 else f'FAIL ({fail})'}")
    return fail == 0

if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--selftest":
        sys.exit(0 if selftest() else 1)
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    lag = (20, 1500)
    if "--lag-ms" in sys.argv:
        a, b = sys.argv[sys.argv.index("--lag-ms") + 1].split(":"); lag = (float(a), float(b))
    report(sys.argv[1], lag_ms=lag)
