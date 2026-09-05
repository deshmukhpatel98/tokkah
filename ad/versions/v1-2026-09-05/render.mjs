#!/usr/bin/env node
/**
 * Kin Ad Renderer (ad/render.mjs)
 * Headless Brave CDP frame capture & ffmpeg muxer.
 *
 * Implements §8 of ad/BRIEF.md:
 * - Node 22, zero npm dependencies
 * - Brave headless over CDP using Node's global WebSocket
 * - Frame-exact capture via kinAd.seek(t) + Page.captureScreenshot
 * - Score via kinAd.renderScoreOffline(48000) pulled out as chunked base64 WAV
 * - ffmpeg mux (ffmpeg on PATH or ~/.local/bin/ffmpeg)
 * - Hero cut (26.0–38.0s, muted, 1280x720, -crf 22)
 * - Flags: --fps, --from, --to, --stills, --keep-frames, --page
 * - Always kill Brave on exit, error and SIGINT
 * - Progress every 60 frames with ETA
 * - Exit non-zero on any failure
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import { spawn, spawnSync, execSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const BRAVE_BIN = '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser';

function parseArgs(args) {
  const options = {
    fps: 60,
    from: 0,
    to: null,
    stills: null,
    keepFrames: false,
    page: 'ad/kin-ad.html',
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--fps') {
      const val = parseFloat(args[++i]);
      if (isNaN(val) || val <= 0) throw new Error(`Invalid --fps value: ${args[i]}`);
      options.fps = val;
    } else if (arg.startsWith('--fps=')) {
      const val = parseFloat(arg.slice(6));
      if (isNaN(val) || val <= 0) throw new Error(`Invalid --fps value: ${arg}`);
      options.fps = val;
    } else if (arg === '--from') {
      const val = parseFloat(args[++i]);
      if (isNaN(val) || val < 0) throw new Error(`Invalid --from value: ${args[i]}`);
      options.from = val;
    } else if (arg.startsWith('--from=')) {
      const val = parseFloat(arg.slice(7));
      if (isNaN(val) || val < 0) throw new Error(`Invalid --from value: ${arg}`);
      options.from = val;
    } else if (arg === '--to') {
      const val = parseFloat(args[++i]);
      if (isNaN(val) || val <= 0) throw new Error(`Invalid --to value: ${args[i]}`);
      options.to = val;
    } else if (arg.startsWith('--to=')) {
      const val = parseFloat(arg.slice(5));
      if (isNaN(val) || val <= 0) throw new Error(`Invalid --to value: ${arg}`);
      options.to = val;
    } else if (arg === '--stills') {
      const val = parseInt(args[++i], 10);
      if (isNaN(val) || val <= 0) throw new Error(`Invalid --stills value: ${args[i]}`);
      options.stills = val;
    } else if (arg.startsWith('--stills=')) {
      const val = parseInt(arg.slice(9), 10);
      if (isNaN(val) || val <= 0) throw new Error(`Invalid --stills value: ${arg}`);
      options.stills = val;
    } else if (arg === '--keep-frames') {
      options.keepFrames = true;
    } else if (arg === '--page') {
      options.page = args[++i];
    } else if (arg.startsWith('--page=')) {
      options.page = arg.slice(7);
    } else if (arg === '--help' || arg === '-h') {
      console.log(`Usage: node ad/render.mjs [options]
Options:
  --fps <number>      Frame rate (default: 60)
  --from <seconds>    Start time in seconds (default: 0)
  --to <seconds>      End time in seconds (default: full duration)
  --stills <N>        Export N evenly spaced still PNGs to ad/out/stills/ and exit
  --keep-frames       Do not delete ad/out/frames/ after muxing
  --page <path>       Target HTML page (default: ad/kin-ad.html)
`);
      process.exit(0);
    } else {
      throw new Error(`Unknown option: ${arg}`);
    }
  }
  return options;
}

function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
  });
}

function findFfmpeg() {
  const localFfmpeg = path.join(os.homedir(), '.local/bin/ffmpeg');
  if (fs.existsSync(localFfmpeg)) {
    return localFfmpeg;
  }
  return 'ffmpeg';
}

function formatETA(sec) {
  if (sec <= 0) return '0s';
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = Math.floor(sec % 60);
  if (h > 0) return `${h}h ${m}m ${s}s`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

class CDPClient {
  constructor(ws) {
    this.ws = ws;
    this.id = 1;
    this.pending = new Map();

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        if (msg.id !== undefined && this.pending.has(msg.id)) {
          const handler = this.pending.get(msg.id);
          this.pending.delete(msg.id);
          if (msg.error) {
            handler.reject(new Error(msg.error.message || JSON.stringify(msg.error)));
          } else {
            handler.resolve(msg.result);
          }
        }
      } catch (err) {
        // ignore parse error
      }
    };

    ws.onerror = (err) => {
      for (const [id, handler] of this.pending) {
        handler.reject(err);
      }
      this.pending.clear();
    };

    ws.onclose = () => {
      for (const [id, handler] of this.pending) {
        handler.reject(new Error('CDP WebSocket closed'));
      }
      this.pending.clear();
    };
  }

  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = this.id++;
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    try {
      this.ws.close();
    } catch {}
  }
}

// Global cleanup tracking
let braveProcess = null;
let bravePort = null;
let tempDir = null;
let isCleaningUp = false;

function cleanup() {
  if (isCleaningUp) return;
  isCleaningUp = true;
  if (braveProcess) {
    try {
      process.kill(-braveProcess.pid, 'SIGKILL');
    } catch {
      try {
        braveProcess.kill('SIGKILL');
      } catch {}
    }
    braveProcess = null;
  }
  if (bravePort) {
    try {
      execSync(`pkill -9 -f "remote-debugging-port=${bravePort}" 2>/dev/null`);
    } catch {}
  }
  if (tempDir) {
    try {
      fs.rmSync(tempDir, { recursive: true, force: true });
    } catch {}
    tempDir = null;
  }
}

process.on('SIGINT', () => {
  console.error('\nInterrupted (SIGINT). Terminating Brave and cleaning up...');
  cleanup();
  process.exit(130);
});

process.on('SIGTERM', () => {
  console.error('\nTerminated (SIGTERM). Terminating Brave and cleaning up...');
  cleanup();
  process.exit(143);
});

process.on('exit', () => {
  cleanup();
});

process.on('uncaughtException', (err) => {
  console.error('\nFatal error (uncaught exception):', err.message);
  cleanup();
  process.exit(1);
});

process.on('unhandledRejection', (reason) => {
  console.error('\nFatal error (unhandled rejection):', reason);
  cleanup();
  process.exit(1);
});

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`Error: ${err.message}`);
    process.exit(1);
  }

  if (!fs.existsSync(BRAVE_BIN)) {
    console.error(`Error: Brave browser binary not found at "${BRAVE_BIN}"`);
    process.exit(1);
  }

  // Resolve page path
  let resolvedPagePath = path.resolve(process.cwd(), options.page);
  if (!fs.existsSync(resolvedPagePath)) {
    const altPath = path.resolve(import.meta.dirname, '..', options.page);
    if (fs.existsSync(altPath)) {
      resolvedPagePath = altPath;
    } else {
      const baseAlt = path.resolve(import.meta.dirname, path.basename(options.page));
      if (fs.existsSync(baseAlt)) {
        resolvedPagePath = baseAlt;
      } else {
        console.error(`Error: Target HTML page not found at "${options.page}" (resolved to "${resolvedPagePath}")`);
        process.exit(1);
      }
    }
  }

  bravePort = await getFreePort();
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'brave-render-'));

  const braveArgs = [
    '--headless=new',
    `--remote-debugging-port=${bravePort}`,
    `--user-data-dir=${tempDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-gpu',
    '--hide-scrollbars',
    '--disable-component-update',
    '--disable-background-networking',
    '--window-size=1920,1080',
    'about:blank'
  ];

  braveProcess = spawn(BRAVE_BIN, braveArgs, {
    detached: true,
    stdio: 'ignore'
  });

  braveProcess.on('error', (err) => {
    console.error(`Error starting Brave process: ${err.message}`);
    cleanup();
    process.exit(1);
  });

  // Connect over CDP
  let targetWsUrl = null;
  const connectStart = Date.now();
  while (Date.now() - connectStart < 15000) {
    try {
      const res = await fetch(`http://127.0.0.1:${bravePort}/json/list`);
      if (res.ok) {
        const list = await res.json();
        const pageTarget = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
        if (pageTarget) {
          targetWsUrl = pageTarget.webSocketDebuggerUrl;
          break;
        }
      }
    } catch {
      // waiting for port
    }
    await new Promise((r) => setTimeout(r, 100));
  }

  if (!targetWsUrl) {
    throw new Error(`Timed out connecting to Brave CDP on port ${bravePort}`);
  }

  const ws = new WebSocket(targetWsUrl);
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = reject;
  });

  const cdp = new CDPClient(ws);

  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width: 1920,
    height: 1080,
    deviceScaleFactor: 1,
    mobile: false
  });

  const pageUrl = pathToFileURL(resolvedPagePath).href + '?render=1';
  console.log(`[render] Navigating to: ${pageUrl}`);
  await cdp.send('Page.navigate', { url: pageUrl });

  // Wait for document.fonts.ready and window.kinAd
  const waitExpr = `(async () => {
    if (document.readyState !== 'complete') {
      await new Promise(r => window.addEventListener('load', r, { once: true }));
    }
    if (document.fonts && document.fonts.ready) {
      await document.fonts.ready;
    }
    const tStart = Date.now();
    while (typeof window.kinAd === 'undefined' || typeof window.kinAd.seek !== 'function') {
      if (Date.now() - tStart > 15000) {
        throw new Error("Timed out waiting for window.kinAd API");
      }
      await new Promise(r => setTimeout(r, 20));
    }
    return {
      duration: window.kinAd.duration || 75
    };
  })()`;

  const initRes = await cdp.send('Runtime.evaluate', {
    expression: waitExpr,
    awaitPromise: true,
    returnByValue: true
  });

  if (initRes.exceptionDetails) {
    throw new Error(`Page initialization error: ${initRes.exceptionDetails.text || JSON.stringify(initRes.exceptionDetails)}`);
  }

  const pageDuration = initRes.result?.value?.duration || 75;
  const from = options.from;
  const to = options.to !== null ? options.to : pageDuration;
  if (from >= to) {
    throw new Error(`Invalid time range: --from (${from}) must be less than --to (${to})`);
  }

  const outDir = path.resolve(import.meta.dirname, 'out');
  fs.mkdirSync(outDir, { recursive: true });

  // Stills mode
  if (options.stills !== null) {
    const numStills = options.stills;
    const stillsDir = path.join(outDir, 'stills');
    fs.mkdirSync(stillsDir, { recursive: true });

    // Clean existing PNGs in stillsDir
    const existing = fs.readdirSync(stillsDir);
    for (const f of existing) {
      if (f.endsWith('.png')) fs.unlinkSync(path.join(stillsDir, f));
    }

    console.log(`[render] Exporting ${numStills} stills from ${from}s to ${to}s...`);
    for (let k = 0; k < numStills; k++) {
      const t = numStills === 1 ? from : from + (k / (numStills - 1)) * (to - from);
      const seekRes = await cdp.send('Runtime.evaluate', {
        expression: `window.kinAd.seek(${t})`,
        awaitPromise: true
      });
      if (seekRes.exceptionDetails) {
        throw new Error(`Seek error at t=${t}: ${seekRes.exceptionDetails.text || JSON.stringify(seekRes.exceptionDetails)}`);
      }
      const snap = await cdp.send('Page.captureScreenshot', { format: 'png' });
      const stillFile = `still_${String(k + 1).padStart(2, '0')}.png`;
      fs.writeFileSync(path.join(stillsDir, stillFile), Buffer.from(snap.data, 'base64'));
      console.log(`[render] Still ${k + 1}/${numStills} (t = ${t.toFixed(2)}s) -> ad/out/stills/${stillFile}`);
    }

    console.log(`[render] Finished: ${numStills} stills exported to ${path.relative(process.cwd(), stillsDir)}/`);
    cdp.close();
    cleanup();
    process.exit(0);
  }

  // Video render mode
  const fps = options.fps;
  const totalDuration = to - from;
  const totalFrames = Math.round(totalDuration * fps);
  const framesDir = path.join(outDir, 'frames');
  fs.mkdirSync(framesDir, { recursive: true });

  // Clean existing frames
  const existing = fs.readdirSync(framesDir);
  for (const f of existing) {
    if (f.endsWith('.png')) fs.unlinkSync(path.join(framesDir, f));
  }

  console.log(`[render] Capturing ${totalFrames} frames at ${fps} fps (span: ${from}s - ${to}s)...`);

  const captureStart = performance.now();
  for (let i = 0; i < totalFrames; i++) {
    const t = from + i / fps;

    const seekRes = await cdp.send('Runtime.evaluate', {
      expression: `window.kinAd.seek(${t})`,
      awaitPromise: true
    });
    if (seekRes.exceptionDetails) {
      throw new Error(`Seek error at frame ${i} (t=${t}): ${seekRes.exceptionDetails.text || JSON.stringify(seekRes.exceptionDetails)}`);
    }

    const snap = await cdp.send('Page.captureScreenshot', { format: 'png' });
    const frameFile = `${String(i + 1).padStart(5, '0')}.png`;
    fs.writeFileSync(path.join(framesDir, frameFile), Buffer.from(snap.data, 'base64'));

    const done = i + 1;
    if (done === 1 || done % 60 === 0 || done === totalFrames) {
      const elapsedSec = (performance.now() - captureStart) / 1000;
      const avgMs = (elapsedSec * 1000) / done;
      const remainingFrames = totalFrames - done;
      const etaSec = Math.round((remainingFrames * avgMs) / 1000);
      const pct = ((done / totalFrames) * 100).toFixed(1);
      console.log(`[render] Frame ${done}/${totalFrames} (${pct}%) | ${avgMs.toFixed(1)} ms/frame | ETA: ${formatETA(etaSec)}`);
    }
  }

  const totalCaptureTime = (performance.now() - captureStart) / 1000;
  const avgCaptureMs = (totalCaptureTime * 1000) / totalFrames;
  console.log(`[render] Frame capture complete: ${totalFrames} frames in ${totalCaptureTime.toFixed(2)}s (avg ${avgCaptureMs.toFixed(1)} ms/frame)`);

  // Audio score rendering
  console.log(`[render] Rendering offline score at 48000 Hz...`);

  const scoreExpr = `(async () => {
    if (!window.kinAd || typeof window.kinAd.renderScoreOffline !== 'function') {
      throw new Error("window.kinAd.renderScoreOffline is not defined");
    }
    const sampleRate = 48000;
    const channels = await window.kinAd.renderScoreOffline(sampleRate);
    if (!channels || !channels.length) {
      throw new Error("renderScoreOffline returned empty channels");
    }
    const ch0 = channels[0];
    const ch1 = channels[1] || ch0;

    const startSample = Math.max(0, Math.floor(${from} * sampleRate));
    const endSample = Math.min(ch0.length, Math.floor(${to} * sampleRate));
    const numSamples = Math.max(0, endSample - startSample);
    const dataSize = numSamples * 2 * 2; // 2 channels, 16-bit PCM = 4 bytes per sample frame

    const buffer = new ArrayBuffer(44 + dataSize);
    const view = new DataView(buffer);

    function writeStr(offset, str) {
      for (let i = 0; i < str.length; i++) {
        view.setUint8(offset + i, str.charCodeAt(i));
      }
    }

    // RIFF chunk descriptor
    writeStr(0, 'RIFF');
    view.setUint32(4, 36 + dataSize, true);
    writeStr(8, 'WAVE');

    // fmt sub-chunk
    writeStr(12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true); // PCM format
    view.setUint16(22, 2, true); // Stereo (2 channels)
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * 4, true); // ByteRate
    view.setUint16(32, 4, true); // BlockAlign
    view.setUint16(34, 16, true); // BitsPerSample

    // data sub-chunk
    writeStr(36, 'data');
    view.setUint32(40, dataSize, true);

    let offset = 44;
    for (let i = startSample; i < endSample; i++) {
      let s0 = ch0[i] || 0;
      if (s0 > 1) s0 = 1; else if (s0 < -1) s0 = -1;
      view.setInt16(offset, s0 < 0 ? s0 * 0x8000 : s0 * 0x7FFF, true);
      offset += 2;

      let s1 = ch1[i] || 0;
      if (s1 > 1) s1 = 1; else if (s1 < -1) s1 = -1;
      view.setInt16(offset, s1 < 0 ? s1 * 0x8000 : s1 * 0x7FFF, true);
      offset += 2;
    }

    window.__wavData = new Uint8Array(buffer);
    return window.__wavData.byteLength;
  })()`;

  const scoreRes = await cdp.send('Runtime.evaluate', {
    expression: scoreExpr,
    awaitPromise: true,
    returnByValue: true
  });

  if (scoreRes.exceptionDetails) {
    throw new Error(`Score rendering failed: ${scoreRes.exceptionDetails.text || JSON.stringify(scoreRes.exceptionDetails)}`);
  }

  const totalWavBytes = scoreRes.result?.value;
  if (typeof totalWavBytes !== 'number' || totalWavBytes < 44) {
    throw new Error(`Invalid WAV data size returned: ${totalWavBytes}`);
  }

  const wavPath = path.join(outDir, 'score.wav');
  const chunkSize = 1024 * 1024; // 1 MB chunks (well within <= 4 MB limit)
  const fd = fs.openSync(wavPath, 'w');

  for (let off = 0; off < totalWavBytes; off += chunkSize) {
    const curSize = Math.min(chunkSize, totalWavBytes - off);
    const chunkRes = await cdp.send('Runtime.evaluate', {
      expression: `(() => {
        const slice = window.__wavData.subarray(${off}, ${off + curSize});
        let binary = '';
        const step = 8192;
        for (let i = 0; i < slice.length; i += step) {
          binary += String.fromCharCode.apply(null, slice.subarray(i, Math.min(i + step, slice.length)));
        }
        return btoa(binary);
      })()`,
      returnByValue: true
    });
    if (chunkRes.exceptionDetails) {
      fs.closeSync(fd);
      throw new Error(`Failed retrieving audio chunk at offset ${off}: ${chunkRes.exceptionDetails.text}`);
    }
    const chunkBuf = Buffer.from(chunkRes.result.value, 'base64');
    fs.writeSync(fd, chunkBuf);
  }
  fs.closeSync(fd);
  await cdp.send('Runtime.evaluate', { expression: 'delete window.__wavData;' });
  console.log(`[render] Score written to ${path.relative(process.cwd(), wavPath)} (${totalWavBytes} bytes)`);

  // Close browser before ffmpeg muxing
  cdp.close();
  cleanup();

  // ffmpeg mux
  const ffmpegBin = findFfmpeg();
  console.log(`[render] Muxing video with ffmpeg...`);

  const mp4Path = path.join(outDir, 'kin-ad.mp4');
  const muxArgs = [
    '-y',
    '-framerate', String(fps),
    '-start_number', '1',
    '-i', path.join(framesDir, '%05d.png'),
    '-i', wavPath,
    '-c:v', 'libx264',
    '-crf', '17',
    '-preset', 'slow',
    '-pix_fmt', 'yuv420p',
    '-movflags', '+faststart',
    '-c:a', 'aac',
    '-b:a', '192k',
    '-shortest',
    mp4Path
  ];

  const muxResult = spawnSync(ffmpegBin, muxArgs, { stdio: 'pipe', encoding: 'utf-8' });
  if (muxResult.status !== 0) {
    throw new Error(`ffmpeg mux failed (status ${muxResult.status}):\n${muxResult.stderr || muxResult.stdout}`);
  }
  console.log(`[render] Video written to ${path.relative(process.cwd(), mp4Path)}`);

  // Hero cut (26.0–38.0 s span, muted, 1280×720, -crf 22)
  const heroMp4Path = path.join(outDir, 'kin-ad-hero.mp4');
  if (from <= 26.0 && to >= 38.0) {
    console.log(`[render] Producing hero cut (26.0s - 38.0s)...`);
    const heroStart = 26.0 - from;
    const heroDuration = 12.0; // 38.0 - 26.0
    const heroArgs = [
      '-y',
      '-ss', String(heroStart),
      '-i', mp4Path,
      '-t', String(heroDuration),
      '-an',
      '-vf', 'scale=1280:720',
      '-c:v', 'libx264',
      '-crf', '22',
      '-preset', 'slow',
      '-pix_fmt', 'yuv420p',
      '-movflags', '+faststart',
      heroMp4Path
    ];
    const heroResult = spawnSync(ffmpegBin, heroArgs, { stdio: 'pipe', encoding: 'utf-8' });
    if (heroResult.status !== 0) {
      throw new Error(`ffmpeg hero cut failed (status ${heroResult.status}):\n${heroResult.stderr || heroResult.stdout}`);
    }
    console.log(`[render] Hero video written to ${path.relative(process.cwd(), heroMp4Path)}`);
  } else {
    console.log(`[render] Note: Rendered span [${from}, ${to}] does not cover hero span [26.0, 38.0]; skipping hero cut`);
  }

  // Frame cleanup
  if (!options.keepFrames) {
    fs.rmSync(framesDir, { recursive: true, force: true });
    console.log(`[render] Temporary frame PNGs cleaned up`);
  } else {
    console.log(`[render] Frames preserved in ${path.relative(process.cwd(), framesDir)}/ (--keep-frames)`);
  }

  console.log(`[render] All done.`);
}

main().catch((err) => {
  console.error(`\n[render error] ${err.message}`);
  cleanup();
  process.exit(1);
});
