# What is actually measured in Kin

Part of [Kin](../README.md). Moved from the main README.

This project's one real rule is that a claim ships with the number that proves
it. **Read the next section before you read this table** — it says what these
numbers are and are not, and it matters more than any single figure in them.

| Claim | Measured | Where |
|---|---|---|
| Mouth to ear | **9.23 ms**, fully attributed with 0.08 ms unaccounted: `cap→send 1.67 · recv→play 3.01 · mic 1.88 · spk 2.58`. **4.46 ms of that 9.23 is the microphone and the speaker** — hardware nobody can optimise | [../DESIGN.md](../DESIGN.md) §17.108 |
| Audio format | 48 kHz **16-bit PCM, losslessly compressed 2.6×** by fixed-order prediction + Rice coding (the FLAC/Shorten subset, no lookahead, so it costs no latency by construction): **1.16 Mbps** each way, was 1.64 uncompressed. 137,005 packets round-tripped with **0 mismatches** | [`../mac/Sources/tk/Lpc.swift`](../mac/Sources/tk/Lpc.swift), `tk --selftest-lpc` |
| Packet cadence | 32 samples per packet = **0.667 ms** of audio per datagram, 1511 packets/s. One UDP socket carries audio and video, so there is one port and one hole to punch | [`../mac/Sources/tk/Net.swift`](../mac/Sources/tk/Net.swift) |
| Encryption costs nothing | X25519 + ML-KEM-768 (post-quantum hybrid) + AES-256-GCM per packet, handshake signed by the device key, replay window: **0.78 µs** to seal 276 bytes, worst of 300,000 at 15 µs, against a 1333 µs deadline — 0.06% typical | [`../mac/Sources/tk/Crypto.swift`](../mac/Sources/tk/Crypto.swift) |
| Your voice is untouched | duplex gate: **19.3 dB** of attenuation while only the far end is talking, **0.0001%** worst-sample difference while you talk — bit-for-bit | `tk --gate-test` |
| Video | H.264 High through VideoToolbox: **45.5 dB PSNR at ~1.19 Mbps, 30 fps sustained**. Glass-to-glass **~34.8 ms** in the shipping default (5.6 ms capture→decoded, 29.2 ms decoded→glass) | [../DESIGN.md](../DESIGN.md), [`../mac/Sources/tk/Video.swift`](../mac/Sources/tk/Video.swift) |
| Loss repair | a second copy of each packet, offset in time: **94.8% recovered at 1% uniform loss for 1.2 ms** of added buffer — and it switches itself off under bursts, where it does not work | [../DESIGN.md](../DESIGN.md) §17.86 |
| Window on screen | **192 ms**, first camera frame **464 ms**, by starting the sensor before the window rather than after. 640 of the ~780 ms to first frame is the sensor itself and is not ours | [`../mac/Sources/tk/main.swift`](../mac/Sources/tk/main.swift) |
| Answering a ring | **429 ms** to first picture on a real answered ring | [`../mac/Sources/tk/main.swift`](../mac/Sources/tk/main.swift) |
| **Cancel and decline** | **346 ms on production**, from the press to the other Mac having it | [../CHANGELOG.md](../CHANGELOG.md) (0.62.0) |

### What these numbers are not

Almost every figure above is a **pipeline** number, measured **between two
processes on one Mac**. The network contributes nothing and both ends share one
clock. That is a deliberate instrument — it isolates the part that is not the
speed of light — but it means they are not a claim about what a call between two
people in two places costs.

Being exact about which is which:

- **Loopback** (two processes, one machine): mouth-to-ear, glass-to-glass, the
  audio format figures, the duplex gate, the video PSNR.
- **Injected impairment** (delay, jitter and loss added on one Mac — never a
  constant-delay pipe): the distance figures. A Delhi↔Netherlands path modelled
  at 45 ms one-way gives **59.2 ms** mouth-to-ear; the antipodes at 100 ms
  one-way give **116.7 ms**, leaving 33 ms of headroom against the project's
  150 ms goal. The download page states plainly that these two are simulated,
  and that real distance "will be worse in ways a rig cannot invent".
- **Real hardware, black box**: camera first frame, launch and window timings.
- **Live production**: the **346 ms** cancel/decline, and the server-side
  measurements in [../RINGING.md](../RINGING.md) (Durable Object cold start 1108 ms
  median over 27 fresh objects; warm round trip 127 ms median).

So: there is currently **one live-production latency receipt for a media
action** in this project, and it is the 346 ms one. A real two-Macs-two-places
mouth-to-ear has not been measured. That is the honest state, it is the next
thing worth measuring, and no number here should be read as if it had been.

Video is *visually* lossless at best and never bit-exact — 1080p60 raw is about
1.5 Gbps, so the audio promise is simply not available for the picture. The
audio deserves the same precision: 16-bit is lossless with respect to **what the
microphone captured**, and lossy with respect to the float the OS hands over.
The project's own word for that is **"transparent, not lossless"**, and it is the
better word.

### The browser-era measurements

The documentation is split by era, and you have to know where the line is.
[../MEASURED.md](../MEASURED.md) is 4,600 lines of genuine lab notebook — every
claim's receipt, every experiment that failed — and it is **entirely the browser
product**, last touched 2026-08-13. [../DESIGN.md](../DESIGN.md) straddles
both: §1–§17.76 are the browser, and **§17.77 onward is the native Mac app**,
which is where most numbers in the table above come from. For the history of that
transition, see [BROWSER-ERA.md](BROWSER-ERA.md).
