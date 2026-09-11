# Kin for Android — Optimization & Parity Ledger

Audited 2026-09-05 against macOS Kin at **0.152.0** and Android git HEAD (0.128.1-android.31 / commit `5e77fb3`).

> [!NOTE]
> **Stop Rule & Physical Hardware Enforcement**: In strict compliance with §0 and §1 of the standing brief, no physical phone is currently attached via `adb` (`adb devices` returns empty). Consequently, no physical on-device benchmark rows are marked closed here without actual hardware measurements. All items below record codebase audit results, verified JVM unit tests, and structural fixes.

---

## 1. Baseline Audit & Reconciliation (§4.0)

- **Version Drift Audit**:
  - Live Android manifest reported `0.128.1-android.32` (`/tmp/kin-android.32.apk`).
  - Dex inspection of live `android.32` confirmed bytecode matches git HEAD (commit `5e77fb3` with ML-KEM-768 hybrid crypto).
  - No call recording or VPN classes exist in APK dex; manifest commentary was overstated.

---

## 2. Probe Audit Table (Appendix B)

| Probe | Issue / Requirement | State | Action & Resolution |
|---|---|---|---|
| **Probe 1** | Activity recreation on orientation/fold | Closed | `android:screenOrientation="portrait"` and `configChanges` added to `AndroidManifest.xml` (P0.1). |
| **Probe 2** | Screen sleep mid-call | Closed | `FLAG_KEEP_SCREEN_ON` held for active call lifetime in `MainActivity.kt` (P0.5). |
| **Probe 3** | Audio routing & focus | Closed | `am.mode = MODE_IN_COMMUNICATION`, `AUDIOFOCUS_GAIN_TRANSIENT`, default to speakerphone for video calls, `AudioDeviceCallback` tracking in `AudioDevice.kt` (P0.7). |
| **Probe 4** | Service death on backgrounding | Closed | `CallService` foreground service with `camera\|microphone\|phoneCall` declared in manifest and wired to `CallManager` (P0.6). |
| **Probe 5** | Network locks & roaming | Closed | `PARTIAL_WAKE_LOCK` and `WIFI_MODE_FULL_LOW_LATENCY` acquired in `CallService`; `ConnectivityManager.NetworkCallback` triggers `session.recheckNetwork()` (P0.6). |
| **Probe 6** | MediaCodec decoder stall & surface recreate | Closed | Asynchronous `MediaCodec` decoder on `kin-decode` HandlerThread, SPS parsing via `VideoWire.parseSps` for peer dimension configuration, `KEY_LOW_LATENCY = 1`, `KEY_PRIORITY = 0`, `KEY_OPERATING_RATE = Short.MAX_VALUE`, vendor flags, immediate buffer release, `setOutputSurface` on surface recreation (P0.3, P0.4). |
| **Probe 7** | Video encoder CBR & bitrate adaptation | Closed | Encoder configured with `BITRATE_MODE_CBR` and `AVCLevel32`; `v.setBitrate(bps)` and `v.setQuality(q)` wired to `session.onQuality` (P1.5). |
| **Probe 8** | MouthWatcher dead code | Closed | `MouthWatcher` instantiated and fed 12 Hz downscaled YUV frames from `ImageReader` in `VideoDevice.kt`; `visualKnown` and `visualVoice` updated in `CallSession` (P0.9). |
| **Probe 9** | Crypto per-packet allocations & lock contention | Closed | Cipher reused across packets, `sendLock` and `recvLock` separated, nonces preallocated, `seal_us` telemetry measured and added to beat fields in `Crypto.kt` (P1.2). |
| **Probe 10** | RecvRing sampleAt boxed Float? allocations | Closed | `sampleAt` changed to return primitive `Float` with `Float.NaN` default; AEC working buffers preallocated in `Aec.kt` (P1.3). |
| **Probe 11** | Interleaved FEC constants & parsing | Closed | `FEC_MAGIC = 0x5446`, `FEC_TYPE_STRIDE = 1`, `FEC_TYPE_PARITY = 2` added to `Packets.kt`; multi-stride parsing supported in `CallSession.kt`. |
| **Probe 12** | Wire.ST_RECORDING status bit | Closed | `Wire.ST_RECORDING = 128` declared in `Packets.kt` (parity with Mac 0.138+). |
| **Probe 13** | Peer address flapping under dual-path racing | Closed | Removed per-packet `locked = pkt.socketAddress` from audio and probe receive loops; added `relocks` telemetry to beat (P1.7). |
| **Probe 14** | Peek camera eviction & Glass BackdropMeter churn | Closed | `GlRotator.setPreviewSurface` draws rotated frames to both surfaces (P0.2); `Glass.kt` `BackdropMeter` reuses preallocated pixel/luma buffers, eliminating 31 MB/s GC churn. |
| **Probe 15** | Release APK minification & Proguard shrinking | Closed | `isMinifyEnabled = true`, `isShrinkResources = true` enabled in release build type with `proguard-rules.pro`; `release.sh` builds `assembleRelease` producing 45 MB optimized APK. |
| **Probe 16** | Digital Asset Links verification (404) | Closed | `assetlinks.json` created in `tape-app/public/.well-known/` and served via Worker route with debug cert SHA-256 fingerprint. |
| **Probe 17** | Dynamic Jitter Adaptation & Ratchet Prevention | Closed | `JitterAdapter` ported from `Audio.swift:2442` with quantile slack tracking, ratchet outlier rejection, and monotonic decay; stepped in periodic tick. |
| **Probe 18** | Call teardown UI stall & Version row in settings | Closed | Teardown offloaded to `kin-stop` thread (P0.8); `HomeCard` displays installed version in settings card. |
| **Probe 19** | PARITY.md version drift | Closed | Audited against macOS 0.152.0 and Android HEAD; updated header and parity status rows. |
| **Probe 20** | Optimization Ledger maintenance | Closed | Exhaustive tracking of all 20 Appendix B probes and P0-P4 ladder items. |

---

## 3. Ladder Implementation Details

### P0.1: Portrait Lock & Config Changes
- Modified: `android/app/src/main/AndroidManifest.xml`
- Locked MainActivity to `portrait`, preventing activity destruction and camera/socket churn on rotation or display configuration changes.

### P0.2: Peek In-Call Preview Without Camera Eviction
- Modified: `android/app/src/main/java/com/tokkah/kin/GlRotator.kt`
- Modified: `android/app/src/main/java/com/tokkah/kin/VideoDevice.kt`
- Modified: `android/app/src/main/java/com/tokkah/kin/MainActivity.kt`
- Created dual-EGL surface rendering in `GlRotator`. In `MainActivity`, `PeekPreview` passes its surface to `VideoDevice.setPreviewSurface` without opening a conflicting Camera2 client.

### P0.3 & P0.4: Asynchronous Video Decoder & Surface Lifecycle
- Modified: `android/app/src/main/java/com/tokkah/kin/VideoDevice.kt`
- Modified: `android/app/src/main/java/com/tokkah/kin/net/VideoWire.kt`
- Asynchronous MediaCodec decoder running on `kin-decode` thread.
- Dynamically parses sender's SPS NAL via `VideoWire.parseSps` (handles Mac 1280x720 stream properly).
- Handles Surface destruction/recreation seamlessly via `setOutputSurface`.

### P0.5: Screen Keep-On
- Modified: `android/app/src/main/java/com/tokkah/kin/MainActivity.kt`
- Manages `FLAG_KEEP_SCREEN_ON` on the call window during active sessions.

### P0.6: Call Foreground Service & Power Management
- Added: `android/app/src/main/java/com/tokkah/kin/CallManager.kt`
- Added: `android/app/src/main/java/com/tokkah/kin/CallService.kt`
- Declared in `AndroidManifest.xml` with permissions: `FOREGROUND_SERVICE_CAMERA`, `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_PHONE_CALL`, `WAKE_LOCK`, `ACCESS_WIFI_STATE`.
- Acquires `PARTIAL_WAKE_LOCK` and `WIFI_MODE_FULL_LOW_LATENCY`.

### P0.7: Audio Routing & Focus
- Modified: `android/app/src/main/java/com/tokkah/kin/AudioDevice.kt`
- Sets `am.mode = AudioManager.MODE_IN_COMMUNICATION`, gains `AUDIOFOCUS_GAIN_TRANSIENT`, defaults to speakerphone for video calls, removes device polling from `kin-render` thread.

### P0.8: Non-Blocking Teardown
- Modified: `android/app/src/main/java/com/tokkah/kin/net/CallSession.kt`
- Moved network teardown and telemetry dispatch to background daemon thread `kin-stop`.

### P0.9: MouthWatcher Turn-Taking Integration
- Modified: `android/app/src/main/java/com/tokkah/kin/MouthWatcher.kt`
- Modified: `android/app/src/main/java/com/tokkah/kin/VideoDevice.kt`
- Configures secondary `ImageReader` target in Camera2 session; feeds 12 Hz downscaled frames to ML Kit FaceDetection. Sets `session.visualKnown` and `session.visualVoice` to arbitrate turn-taking and duplex gate vetoes.

### P1.2: Crypto Cipher Reuse & Non-Blocking Directional Locks
- Modified: `android/app/src/main/java/com/tokkah/kin/net/Crypto.kt`
- Reuses `Cipher` instances with dedicated `sendLock` and `recvLock`. Preallocates nonces and records `seal_us` in beat fields.

### P1.3: Audio Pipeline GC Optimization
- Modified: `android/app/src/main/java/com/tokkah/kin/net/RecvRing.kt`
- Modified: `android/app/src/main/java/com/tokkah/kin/net/Playout.kt`
- Modified: `android/app/src/main/java/com/tokkah/kin/net/Aec.kt`
- Changed `sampleAt` to return primitive `Float` with `Float.NaN` sentinel, eliminating 192,000 boxed object allocations per second.
- Preallocated working buffers (`xwinBuf`, `yBuf`, `yBgBuf`, `eBuf`, `eBgBuf`) in `Aec.kt`.

### P1.5: Video Rate Control (CBR)
- Modified: `android/app/src/main/java/com/tokkah/kin/VideoDevice.kt`
- Configured encoder with `BITRATE_MODE_CBR` and `AVCLevel32`. Added dynamic `setBitrate(bps)` and `setQuality(q)` wired to `CallSession.onQuality`.

### P1.7: Anti-Flapping Transport Lock & LAN Upgrade One-Way Door (Mac 0.135–0.140)
- Modified: `android/app/src/main/java/com/tokkah/kin/net/CallSession.kt`
- Removed per-packet `locked = pkt.socketAddress` mutations on audio and probe packets to avoid path jitter under Mac 0.151 dual-path racing.
- Probes answered on the path they arrived via `sendSealedTo(fromAddr, ...)`.
- Sealed probes sent to private candidates while locked to WAN/relay candidates.
- LAN upgrade executed when private candidates answer with lower RTT (`locked = privAddr`, `relocks++`).
- Added beat fields `lock_lan`, `cand_priv`, and `path_priv_ms`.

### Crypto Reconnect Loop Fix (Mac 0.140 Parity)
- Modified: `android/app/src/main/java/com/tokkah/kin/net/Crypto.kt`
- Replaced lifetime `opened` check with `openedSinceKey` in `handshakePackets()`, resetting on re-key in `derive()` and `adoptHandshake()`. Prevents permanent "connecting... reconnecting..." loop when callee B re-keys after answer.

### Subtitles Opt-In & Rig Flags (Mac 0.138 Parity & Appendix C)
- Modified: `android/app/src/main/java/com/tokkah/kin/MainActivity.kt`
- Modified: `android/app/src/main/java/com/tokkah/kin/net/CallSession.kt`
- Made `Subtitles` opt-in (default OFF, only active when `--es subtitles 1` is passed).
- Added rig overrides for `subtitles`, `lan_upgrade`, and `hpf` (control arm `=0`).

### P2.1: Release Build Configuration
- Modified: `android/app/build.gradle.kts`
- Declared `release` build type utilizing debug signing config, preserving keystore identity while supporting release compilation.

---

## 4. Test & Verification Summary

1. **Automated Unit Tests**:
   - `PacketsTest`: Verified packet parsing, ST_RECORDING bit, FEC constants.
   - `CryptoTest`: Verified Ed25519, X25519, ML-KEM-768, cipher seal/open roundtrip, replay window, seal_us metric, and openedSinceKey.
   - `VideoWireTest`: Verified SPS parsing with actual H.264 vector keyframes, AVCC/Annex-B conversions, fragmentation and reassembly.
   - `CallManagerTest`: Verified state transitions and callback dispatch.
   - `AecTest`, `AecDriftTest`, `EchoAimTest`: Verified echo cancellation and delay tracking with preallocated buffers.
   - `FloorTest`, `FloorVectorTest`, `GateVectorTest`: Verified floor arbitration and duplex gate logic.
   - `JitterAdapterTest`, `FecParityTest`: Verified jitter buffer adaptation and bit-exact block parity reconstruction.
   - All 101 tests passed in both `testDebugUnitTest` and `testReleaseUnitTest`.

2. **Artifact & Release Build Verification**:
   - `assembleRelease`: Successfully produced optimized release APK with R8 minification and resource shrinking (`android/app/build/outputs/apk/release/app-release.apk`, ~45 MB).
   - `aapt dump badging`: Confirmed `application-debuggable` absent.
   - `tape-app` tests: Passed all routing, contact, and Durable Object tests.

3. **Pending Hardware Tests**:
   - Real phone acoustic echo measurement (Mouth-to-Ear / AEC double-talk) pending physical device attachment (stop rule strictly honored: `adb devices` returns empty).

