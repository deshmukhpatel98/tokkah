/**
 * Situational Echo Detector
 * Correlates mic and playout PCM envelopes on a common 8 ms grid to detect acoustic echo.
 */

export function createEchoDetector() {
  const RING_CAP = 512;
  const micT = new Float64Array(RING_CAP);
  const micRms = new Float64Array(RING_CAP);
  let micHead = 0;
  let micCount = 0;

  const playT = new Float64Array(RING_CAP);
  const playRms = new Float64Array(RING_CAP);
  let playHead = 0;
  let playCount = 0;

  let latched = false;
  let consecutiveLags = [];

  function mic(t, rms) {
    micT[micHead] = t;
    micRms[micHead] = Math.max(0, rms || 0);
    micHead = (micHead + 1) % RING_CAP;
    if (micCount < RING_CAP) micCount++;
  }

  function play(t, rms) {
    playT[playHead] = t;
    playRms[playHead] = Math.max(0, rms || 0);
    playHead = (playHead + 1) % RING_CAP;
    if (playCount < RING_CAP) playCount++;
  }

  function poll(tNow) {
    if (latched) return null;

    // Gate 1: Both rings must hold >= 2 s (2000 ms) of span
    if (playCount < 2 || micCount < 2) return null;

    const playOldestIdx = playCount < RING_CAP ? 0 : playHead;
    const playNewestIdx = (playHead - 1 + RING_CAP) % RING_CAP;
    const playSpan = playT[playNewestIdx] - playT[playOldestIdx];

    const micOldestIdx = micCount < RING_CAP ? 0 : micHead;
    const micNewestIdx = (micHead - 1 + RING_CAP) % RING_CAP;
    const micSpan = micT[micNewestIdx] - micT[micOldestIdx];

    if (playSpan < 2000 || micSpan < 2000) return null;

    // Gate 2: Mean playout RMS over last 2 s >= 1e-3
    let playSum = 0, playN = 0;
    for (let i = 0; i < playCount; i++) {
      const t = playT[i];
      if (t >= tNow - 2000 && t <= tNow) {
        playSum += playRms[i];
        playN++;
      }
    }
    const meanPlay2s = playN > 0 ? playSum / playN : 0;
    if (meanPlay2s < 1e-3) {
      consecutiveLags = [];
      return null;
    }

    // Gate 3: Mean mic RMS over last 2 s >= 1e-4
    let micSum = 0, micN = 0;
    for (let i = 0; i < micCount; i++) {
      const t = micT[i];
      if (t >= tNow - 2000 && t <= tNow) {
        micSum += micRms[i];
        micN++;
      }
    }
    const meanMic2s = micN > 0 ? micSum / micN : 0;
    if (meanMic2s < 1e-4) {
      consecutiveLags = [];
      return null;
    }

    // Resample both rings onto 8 ms grid covering [tNow - 3000, tNow] (375 points)
    const playGrid = new Float64Array(375);
    const micGrid = new Float64Array(375);

    for (let k = 0; k < 375; k++) {
      const targetT = (tNow - 3000) + k * 8;

      let minP = Infinity, valP = 0;
      for (let i = 0; i < playCount; i++) {
        const d = Math.abs(playT[i] - targetT);
        if (d < minP) {
          minP = d;
          valP = playRms[i];
        }
      }
      playGrid[k] = minP <= 12 ? valP : 0;

      let minM = Infinity, valM = 0;
      for (let i = 0; i < micCount; i++) {
        const d = Math.abs(micT[i] - targetT);
        if (d < minM) {
          minM = d;
          valM = micRms[i];
        }
      }
      micGrid[k] = minM <= 12 ? valM : 0;
    }

    // Subtract means
    let sumPGrid = 0, sumMGrid = 0;
    for (let k = 0; k < 375; k++) {
      sumPGrid += playGrid[k];
      sumMGrid += micGrid[k];
    }
    const meanPGrid = sumPGrid / 375;
    const meanMGrid = sumMGrid / 375;
    for (let k = 0; k < 375; k++) {
      playGrid[k] -= meanPGrid;
      micGrid[k] -= meanMGrid;
    }

    // Lags L = 0, 8, 16, ..., 600 ms
    let peakCorr = -Infinity;
    let peakLag = 0;

    for (let L = 0; L <= 600; L += 8) {
      const s = L / 8;
      const N = 375 - s;
      let sumP2 = 0, sumM2 = 0, sumPM = 0;

      for (let i = 0; i < N; i++) {
        const p = playGrid[i];
        const m = micGrid[i + s];
        sumP2 += p * p;
        sumM2 += m * m;
        sumPM += p * m;
      }

      if (sumP2 < 1e-12 || sumM2 < 1e-12) continue;

      const corr = sumPM / Math.sqrt(sumP2 * sumM2);
      if (corr > peakCorr) {
        peakCorr = corr;
        peakLag = L;
      }
    }

    if (peakCorr >= 0.55) {
      consecutiveLags.push(peakLag);
      if (consecutiveLags.length > 3) {
        consecutiveLags.shift();
      }
      if (consecutiveLags.length === 3) {
        const minL = Math.min(...consecutiveLags);
        const maxL = Math.max(...consecutiveLags);
        if (maxL - minL <= 24) {
          latched = true;
          return {
            corr: Number(peakCorr.toFixed(2)),
            lagMs: peakLag,
          };
        }
      }
    } else {
      consecutiveLags = [];
    }

    return null;
  }

  return { mic, play, poll };
}
