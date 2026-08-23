#!/usr/bin/env python3
"""What was said against what was played, sample by sample.

Every audio quality number in this project has been a proxy: the step at a
concealment seam, the count of concealed packets, the recovery rate. Proxies are
what you use when you cannot see the thing itself -- and here the thing itself is
available, because the source is a known file and `--dump-playout` writes the
samples that reached the speaker.

Alignment has to be per-chunk, not once. The two machines' audio clocks differ by
tens of parts per million and the rate governor deliberately resamples to track
that, so a single offset found at the start is wrong by the end. Each chunk finds
its own offset by cross-correlation, which also makes the reported drift a
measurement rather than an assumption.

  python3 testbed/playout-snr.py <played.f32> <said.wav> [chunk_s]
"""
import sys, os, struct, wave
import numpy as np

def read_wav(p):
    with wave.open(p, 'rb') as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2, "want 16-bit mono"
        sr = w.getframerate()
        a = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(np.float64) / 32768.0
    return a, sr

played = np.fromfile(sys.argv[1], dtype='<f4').astype(np.float64)
said, sr = read_wav(sys.argv[2])
chunk = int((float(sys.argv[3]) if len(sys.argv) > 3 else 0.05) * sr)

# Skip the first 3 s: the jitter buffer is still descending and the rate governor
# is still converging, and a quality number taken before the inputs settle is a
# measurement of the transient (startup poisons estimators).
skip = int(float(os.environ.get('SKIP_S', '3')) * sr)
played = played[skip:]
if len(played) < chunk * 3:
    print(f"only {len(played)/sr:.1f} s of playout after the warm-up skip -- need more"); sys.exit(1)

# One coarse alignment over a long window to find where in the looping source the
# playout begins, then per-chunk refinement around it.
probe = played[:min(len(played), 4 * sr)]
src2 = np.concatenate([said, said])            # the source loops, so allow wrap
c = np.correlate(src2 - src2.mean(), probe - probe.mean(), mode='valid')
base = int(np.argmax(c))

rows = []
rejected = 0
transient = []
STEP_TOL = float(os.environ.get('STEP_TOL', '2'))
# THE SEARCH WINDOW TRACKS, it does not stay put. Clock drift moves the true
# offset continuously -- tens of ppm, a few samples per chunk -- so centring every
# chunk's search on the PREVIOUS chunk's answer keeps the window tight. A wide
# fixed window instead lets self-similar speech win with the wrong peak, which is
# how a first version of this reported 238 samples of "drift" in one chunk and an
# SNR to match. The ruler has to be checked before the thing it measures.
W = 64
carry = 0
for k in range(len(played) // chunk):
    seg = played[k*chunk:(k+1)*chunk]
    if np.sqrt((seg**2).mean()) < 3e-3: continue      # silence proves nothing
    lo = base + k*chunk + carry - W
    if lo < 0 or lo + chunk + 2*W >= len(src2): break
    win = src2[lo:lo+chunk+2*W]
    cc = np.correlate(win - win.mean(), seg - seg.mean(), mode='valid')
    off = int(np.argmax(cc))
    # An ambiguous peak is a REJECTED chunk, not a bad score. Scoring an alignment
    # this code is not sure of would report the analyser's confusion as the app's
    # distortion.
    peak = cc[off]
    mask = np.ones(len(cc), bool); mask[max(0,off-8):off+9] = False
    runner = cc[mask].max() if mask.any() else 0.0
    if peak <= 0 or runner / peak > 0.85:
        rejected += 1
        continue
    stepped = off - W
    carry += stepped
    # A BUFFER TRANSITION IS NOT AN INTERPOLATOR. When the jitter buffer changes
    # level the read cursor slews by a whole packet -- 32 samples, which is 660 ppm
    # over one second where honest clock drift is 30 -- and the resampling ratio
    # during that slew is nothing like the steady state. Chunks containing one are
    # counted separately, because mixing them in makes the reported SNR a
    # measurement of how many times the buffer happened to move.
    if abs(stepped) > STEP_TOL:
        transient.append(k)
        continue
    ref = src2[lo+off:lo+off+chunk]
    if len(ref) != len(seg): break

    # FRACTIONAL alignment, and it is not optional. The playout is resampled by a
    # rate governor tracking a clock tens of ppm away, so the true offset is almost
    # never a whole sample -- and a half-sample misalignment produces EXACTLY the
    # signature a bad interpolator does: error at high frequencies, SNR in the
    # thirties. Without this, the measurement cannot tell its own error from the
    # thing it is measuring.
    #
    # Two ways this was wrong, both caught by validating the ruler against known
    # inputs before believing it:
    #
    #  1. An FFT phase rotation is an exact fractional delay for a PERIODIC signal.
    #     A one-second excerpt of speech is not periodic, so the shift wrapped the
    #     segment's end into its start and the edge artifact capped the analyser at
    #     57 dB -- which is precisely the "57 dB" it then reported for the app. So
    #     the reference is taken from a PADDED window, shifted, and the centre is
    #     used; the wrap lands in the padding.
    #  2. At 30 ppm a one-second chunk drifts 1.4 samples from start to end, and a
    #     single offset cannot correct a moving one. That residual is identical for
    #     any interpolator, which is why linear and cubic scored the same to 0.1 dB.
    #     Chunks are short now: 50 ms is 0.07 samples of intra-chunk drift.
    PAD = 512
    lo2 = lo + off - PAD
    if lo2 < 0 or lo2 + chunk + 2*PAD >= len(src2): break
    wide = src2[lo2:lo2+chunk+2*PAD]
    n = len(wide)
    R = np.fft.rfft(wide)
    freq = np.fft.rfftfreq(n)
    def resid(d):
        w = np.fft.irfft(R * np.exp(-2j*np.pi*freq*d), n)
        shifted = w[PAD:PAD+chunk]
        g = float(np.dot(shifted, seg) / max(np.dot(shifted, shifted), 1e-20))
        e = seg - g*shifted
        return float(np.dot(e, e)), g, shifted
    # Golden-section over one sample: the integer peak is within half a sample of
    # the truth, and the residual is unimodal there.
    a, b = -1.0, 1.0
    gr = (5**0.5 - 1) / 2
    c_, d_ = b - gr*(b-a), a + gr*(b-a)
    fc, fd = resid(c_)[0], resid(d_)[0]
    for _ in range(28):
        if fc < fd: b, d_, fd = d_, c_, fc; c_ = b - gr*(b-a); fc = resid(c_)[0]
        else:       a, c_, fc = c_, d_, fd; d_ = a + gr*(b-a); fd = resid(d_)[0]
    dbest = (a+b)/2
    _, g, shifted = resid(dbest)
    err = seg - g*shifted
    snr = 10*np.log10(max(np.dot(shifted, shifted)*g*g, 1e-20) / max(np.dot(err, err), 1e-20))
    rows.append((k, snr, g, carry + dbest, float(np.abs(err).max())))

if not rows:
    print("no chunk aligned -- the dump and the source may not correspond"); sys.exit(1)

snrs = np.array([r[1] for r in rows])
drift = np.array([r[3] for r in rows], dtype=float)
print(f"{len(rows)} chunks of {chunk/sr*1000:.0f} ms scored, {rejected} ambiguous,"
      f" {len(transient)} skipped as buffer transitions, after a {skip/sr:.0f} s warm-up")
print(f"  SNR   p50 {np.percentile(snrs,50):6.1f} dB   p05 {np.percentile(snrs,5):6.1f} dB"
      f"   min {snrs.min():6.1f} dB   max {snrs.max():6.1f} dB")
print(f"  gain  p50 {np.percentile([r[2] for r in rows],50):.4f}  (1.0000 = untouched)")
step = np.diff(drift)
print(f"  alignment walked {drift.min():+.2f} .. {drift.max():+.2f} samples"
      f"  ({(drift.max()-drift.min())/sr*1000:.2f} ms across the run,"
      f" worst single-chunk step {np.abs(step).max() if len(step) else 0:.1f} samples)")
if '--series' in sys.argv:
    print("  per-chunk SNR (dB), in order:")
    for i in range(0, len(rows), 12):
        print("    " + " ".join(f"{r[1]:5.1f}" for r in rows[i:i+12]))
worst = sorted(rows, key=lambda r: r[1])[:5]
print("  worst chunks: " + ", ".join(f"#{r[0]} {r[1]:.1f} dB (peak err {r[4]:.4f})" for r in worst))
