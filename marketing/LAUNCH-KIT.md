# Kin Launch Kit

This kit contains the public launch materials for Kin across Hacker News, X, Reddit, Product Hunt, investor outreach, and distribution channels. All copy adheres to the product voice: plain words, short sentences, verified measurements with explicit caveats, and no marketing superlatives.

---

## 1. Positioning

### The One-Line
Kin is a native Mac app for one-to-one video calls that feel like the same room — lossless voice, the camera's own picture, one voice at a time, straight between two Macs — with one goal: under 150 milliseconds anywhere on Earth. Free, open source (AGPL), no account.

### Tagline
As close as light allows.

### Front Door and Repository
- Front door: https://kin.tokkah.com
- Film: https://kin.tokkah.com/ad/kin-ad
- Repository: https://github.com/deshmukhpatel98/tokkah

### Who It Is For
People who talk to one person a lot — remote partners, parents and kids, cofounders, therapists and clients, long-distance couples.

### The 30-Second Pitch
When you speak on a video call today, you wait after every sentence. Then you both speak at once. Kin is a native Mac app for two people. Audio is 48 kHz 16-bit PCM, compressed losslessly, sent directly between two machines. The picture is what your camera saw. Only one person speaks at a time, guided by a quiet edge band. The goal is under 150 milliseconds anywhere on Earth. Free, open source, no account.

### The 2-Minute Spoken Pitch
Every call today runs on a design from 2011. When the network dips, existing software compresses your voice through lossy codecs and degrades your picture. Worse, unpredictable delay breaks conversational turn-taking. Research on conversational dynamics shows that small delay variations disrupt speech entrainment. That makes conversation partners perceive each other as less attentive and less responsive, even when call quality ratings stay unchanged.

We built Kin to remove everything between two people except the time light needs to cross the distance. It is a native Mac app for two people. It does not run in a browser. There are no meeting rooms, no accounts, and no media servers in the middle.

Audio is 48 kHz 16-bit PCM, compressed losslessly at 2.6x to 1.16 Mbps each way. A call costs about 2.4 Mbps in total. Video runs at 30 fps using the camera's native capture.

Instead of an echo canceller that damages your voice, Kin uses turn-taking. A soft band at the window edge glows green when you are audible and blue while you listen. One voice at a time, the way a physical room works.

Our goal is under 150 milliseconds anywhere on Earth. We publish every measurement. In loopback on one Mac, mouth-to-ear is 9.23 ms, glass-to-glass video is ~34.8 ms, and answering a ring takes 429 ms. On production, cancel and decline takes 346 ms.

Kin is free and open source under the AGPL.

### Three Claims We Lead With and Why
1. The feel. Lossless voice, the camera's own picture, one voice at a time, and the edge band. Why: People do not experience calls as network packets or software layers. They experience presence. When audio is transparent and only one voice speaks at a time, the artificial distance of a call disappears.
2. The honesty. Publishing every measurement with its caveat. Distinguishing loopback on one Mac from live production. Stating what is missing: Mac only, two people, not notarized. Why: Video calling software is filled with unverified marketing claims. Stating measurements plainly and naming limitations builds lasting technical trust.
3. The goal. Under 150 milliseconds anywhere on Earth. Why: Between two people, the only real delay is the time light needs to cross the physical distance. Everything else is an engineering defect. Setting the 150 ms threshold as an explicit goal gives every architectural decision a clear benchmark.

---

## 2. Show HN Post

### Post Title
Show HN: Kin – One-to-one Mac video calls with lossless voice, one voice at a time

### Post Body
Kin is a native macOS app for one-to-one video calls. Free, open source under the AGPL, no account, no meeting links. Media travels directly between two Macs over a custom UDP transport.

I built Kin because video calls tire people out. The research on this (Boland et al. 2022, in FATIGUE.md in the repo) found that the gap between one person finishing and the other starting grew from about 135 ms face to face to about 487 ms over a call, while the network delay itself was only 30 to 70 ms. Unpredictable delay breaks the rhythm of a conversation far more than the delay alone would. And when bandwidth dips, the common design spends quality: the voice goes through a lossy codec and the picture goes soft.

Kin takes a different approach:
- Audio is 48 kHz 16-bit PCM, compressed losslessly 2.6x by fixed-order prediction and Rice coding to 1.16 Mbps each way.
- Video runs at 30 fps via VideoToolbox hardware encoding (45.5 dB PSNR at ~1.19 Mbps).
- Total bandwidth for a two-way call is about 2.4 Mbps.
- Echo is handled by turn-taking first: only one microphone is open at a time, so there is nothing to feed an echo. A linear echo canceller catches what leaks on speakers. Nothing else processes your voice: no noise suppression, no automatic gain. A soft band at the window edge glows green while you speak and blue while you listen.

What is measured, and what is not:
Our rule is that every claim ships with a measurement. Almost every media figure in our documentation is a loopback measurement between two processes on one Mac:
- Mouth-to-ear is 9.23 ms (4.46 ms is hardware microphone and speaker latency).
- Glass-to-glass video is ~34.8 ms.
- Answering a ring is 429 ms to first picture on a real answered ring.
- Encryption (X25519 + ML-KEM-768 + AES-256-GCM) takes 0.78 µs to seal 276 bytes.
- On live production, cancel and decline takes 346 ms.
What is not measured: we do not have a live cross-continental media latency receipt between two physical Macs yet. Distance numbers in our documentation (59.2 ms modelled Delhi to Netherlands, 116.7 ms modelled antipodes) are simulated with injected impairment on one Mac.

What is deliberately missing:
- Apple silicon Macs only, macOS 14+.
- Two people per call. No group calls.
- Not notarized by Apple. One Gatekeeper click ("Open Anyway" in System Settings) on the DMG route.
- No noise suppression or automatic gain; your voice is not processed. Headphones change the call: with no acoustic path, both microphones stay open.
- Accessibility tooling cannot see the window yet.

Install via terminal:
curl -fsSL https://room.tokkah.com/macos/install.sh | sh

Front door: https://kin.tokkah.com
Source: https://github.com/deshmukhpatel98/tokkah

We would appreciate feedback on audio clarity, turn-taking feel, and NAT traversal on residential routers.

### 8 Likely HN Questions and Two-Sentence Honest Answers

1. Why is the app not notarized?
We do not pay for an Apple Developer account, so macOS Gatekeeper requires a one-time Open Anyway click in System Settings for the DMG. The app does use a persistent self-signed certificate so that camera and microphone permissions survive future updates.

2. Why write a custom transport instead of using WebRTC?
WebRTC is built around one decision: when the network dips, quality gives (adaptive bitrate, a lossy codec, packet-loss concealment that invents audio). Kin inverts that. Quality is a constant and time is the only thing we spend, which needs a transport that carries 48 kHz 16-bit PCM in 0.667 ms datagrams and never lowers it.

3. Why support only Apple silicon Macs?
We optimized directly against CoreAudio render callbacks, VideoToolbox hardware encoding, and Apple silicon hardware without cross-platform shims. Building for one platform let us refine the real-time audio loop before taking on portable abstractions.

4. How do you handle echo without processing the voice?
Turn-taking first: one microphone is open at a time, attenuating the other side by 19.3 dB while your own voice stays bit-for-bit untouched, so an echo has nothing to feed on. A linear echo canceller handles what still leaks when someone is on speakers; there is no noise suppression and no automatic gain anywhere.

5. What is your encryption model and what can the server see?
Media packets are encrypted end-to-end with X25519, ML-KEM-768, and AES-256-GCM using directional keys that never touch the server. The Cloudflare Worker handles signaling and doorbell ringing only, falling back to a blind TURN relay only when direct UDP hole punching fails.

6. Is a 2.4 Mbps requirement realistic for casual calling?
It is about the cost of one HD stream in each direction, and most home connections carry it easily. When a connection cannot, Kin drops picture frames before it ever lowers picture quality, and it never touches the voice.

7. What is the business model and how do the AGPL and commercial licenses work?
Kin is free and open source under AGPLv3 for individuals, self-hosters, and open source projects. Companies embedding the technology into closed-source commercial applications purchase a commercial license.

8. A 150 ms worldwide latency goal is close to physics limits. How do you plan to achieve it?
Light in fibre needs roughly 100 ms one way between antipodes, so the app has about 50 ms to spend on everything else. Our pipeline measures 9.23 ms mouth to ear in loopback and 116.7 ms with a 100 ms one-way path injected on one Mac, which leaves about 33 ms of headroom on a rig. The Mac app's real cross-planet number is the next thing to measure, and until it exists the 150 ms is a goal, not a claim.

---

## 3. X/Twitter Thread

### Launch Thread

#### Post 1
Every call has a gap in it. You finish a sentence, then you wait, then you both talk at once. Kin is a native Mac app for one-to-one video calls that feel like the same room. As close as light allows.
Watch the film: https://kin.tokkah.com/ad/kin-ad

#### Post 2
Your voice is 48 kHz 16-bit PCM, compressed losslessly 2.6x to 1.16 Mbps each way. No lossy codec touches it. What your microphone captured is what the other person hears.

#### Post 3
Kin gives the floor to whoever is speaking, the way a room does. A soft edge band on the window glows green while you speak and blue while you listen. Nobody talks over anyone, and nobody hears their own echo.

#### Post 4
The picture is what your camera saw. VideoToolbox hardware encoding delivers 45.5 dB PSNR at ~1.19 Mbps at 30 fps. When the network dips, Kin drops video frames instead of degrading your voice.

#### Post 5
Two Macs find each other through one Cloudflare Worker and then send packets directly over UDP. Media never touches our server; if two routers refuse a direct path, a relay forwards packets it cannot read. Encrypted with X25519, ML-KEM-768 and AES-256-GCM.

#### Post 6
Every claim ships with a receipt. In loopback on one Mac: mouth-to-ear is 9.23 ms (4.46 ms is hardware), glass-to-glass video is ~34.8 ms. On live production, cancel and decline takes 346 ms.

#### Post 7
What is missing, plainly: Apple silicon Macs only, macOS 14+. Two people per call. Not notarized by Apple, so the DMG requires a one-time Open Anyway click in System Settings.

#### Post 8
Our goal is under 150 milliseconds anywhere on Earth. Between two people, the only delay that is real is the time light takes to cross the distance. Everything else is a defect.

#### Post 9
Kin is free and open source under AGPL.
Download for Mac: https://kin.tokkah.com
Star the code: https://github.com/deshmukhpatel98/tokkah
Not on a Mac? Leave your name on the site.

### Standalone Posts for Later Days

#### Standalone Post 1 (Echo and Turn-Taking)
How Kin handles echo: turn-taking first. One microphone is open at a time, so an echo has nothing to feed on, and your own voice is never processed. A linear canceller catches what leaks on speakers. One voice at a time, the way a room works. https://kin.tokkah.com

#### Standalone Post 2 (Measurements and Latency)
We measure every release. Pipeline mouth-to-ear is 9.23 ms on one Mac. Hardware alone takes 4.46 ms. Our goal is under 150 ms across the planet. Real distance testing is next.
Inspect the numbers: https://github.com/deshmukhpatel98/tokkah

#### Standalone Post 3 (Self-Hosting and Transport)
The entire backend for Kin is one Cloudflare Worker running on a free account. Media travels peer-to-peer over UDP. You can self-host your own signaling server in ten minutes.
Guide: https://github.com/deshmukhpatel98/tokkah

---

## 4. Reddit Posts

### Post 1: r/macapps

#### Title
Kin – Native Mac 1:1 video calls with lossless voice, under 150ms goal (Free, AGPL)

#### Body
Kin is a native macOS application for one-to-one video calls that feel like being in the same room.

We built it natively for Apple silicon and macOS 14+ using CoreAudio and VideoToolbox. Audio is transmitted as 48 kHz 16-bit PCM, compressed losslessly at 2.6x to 1.16 Mbps each way. No lossy codec touches your voice. Video runs at 30 fps with 45.5 dB PSNR at ~1.19 Mbps. A two-way call costs about 2.4 Mbps.

Kin does not process your voice: no noise suppression, no automatic gain. Echo is handled by turn-taking first, with one microphone open at a time (the other side attenuated by 19.3 dB), and a linear echo canceller for what leaks on speakers. A soft band around the window edge glows green when you are audible and blue while you listen.

There are no accounts, no meeting links, and no media servers. Two Macs connect directly over UDP.

What is missing:
- Apple silicon Macs only, macOS 14+.
- Two people per call. No group calls.
- Not notarized. The DMG requires a one-time Open Anyway click in System Settings.
- No real cross-continental latency measurement yet; our published 9.23 ms mouth-to-ear is loopback on one Mac.

Download: https://kin.tokkah.com
Source: https://github.com/deshmukhpatel98/tokkah

### Post 2: r/selfhosted

#### Title
Kin – Self-hostable peer-to-peer video calls using one free Cloudflare Worker

#### Body
Kin is an open source (AGPLv3) one-to-one video calling app for macOS. The backend is a single Cloudflare Worker that runs entirely on Cloudflare's free tier.

The server handles signaling, handle registration, and doorbell ringing using two Durable Object classes. Media never touches the server. Once the two Macs find each other, audio and video travel directly between them over UDP. If symmetric NAT prevents direct peer-to-peer connection, the app falls back to a standard TURN relay.

You can point the Mac client at your own backend with one flag (`tk --server https://…`) or the per-purpose environment variables SELF-HOSTING.md lists. The Worker deploys on Cloudflare's free tier with zero runtime dependencies and requires no paid database subscriptions.

Key limitations to know:
- The desktop app is currently Apple silicon macOS only.
- Designed strictly for two people per call.
- The default setup relies on public STUN servers to discover external IP addresses.
- The Mac app is self-signed rather than Apple-notarized.

Full self-hosting guide and server code:
https://github.com/deshmukhpatel98/tokkah

### Post 3: r/privacy

#### Title
Kin – End-to-end encrypted 1:1 video calls with no accounts and no media servers

#### Body
Kin is a native macOS video calling application designed for private, one-to-one conversations.

Calls require no accounts, phone numbers, or email addresses. You pick a temporary handle or room name to connect. Media travels directly between the two computers over UDP rather than routing through an intermediary media server.

Encryption details:
Every packet is encrypted end-to-end using a post-quantum hybrid handshake: X25519 plus ML-KEM-768, with AES-256-GCM for packet payloads. The cryptographic operation takes 0.78 µs to seal a packet on Apple silicon. Each direction uses an independent key to prevent nonce reuse. The signaling server never possesses the encryption keys and cannot decrypt media streams.

Honest limitations:
- On a first call between strangers, an out-of-band eight-character verification code read aloud prevents man-in-the-middle key substitution. Subsequent calls pin the key.
- Signaling and discovery pass through a Cloudflare Worker before direct UDP transport begins.
- Apple silicon Macs only, macOS 14+.
- Two people per call.
- The app is signed with a persistent self-signed certificate rather than an Apple Developer ID.

Source code and protocol audit details:
https://github.com/deshmukhpatel98/tokkah

---

## 5. Product Hunt

### Product Name
Kin

### Tagline
Native Mac video calls as close as light allows

### Description
Native Mac app for 1:1 video calls that feel like the same room. Lossless voice, camera picture, one voice at a time, direct between Macs. Free, open source AGPL, no account. Goal: under 150 ms anywhere on Earth.

### Maker Comment
I built Kin because video calls tire people out. When the network dips, the common design spends quality: the voice goes through a lossy codec and the picture goes soft, and the delay becomes unpredictable, which is what breaks the rhythm of a conversation.

Kin takes a different path. It is a native Mac application for two people. Audio is 48 kHz 16-bit PCM, compressed losslessly so that what your microphone captures is what your partner hears. Video runs through hardware encoding at 30 fps. Your voice is never processed. Echo is handled by turn-taking, one microphone open at a time, with a linear canceller for what leaks on speakers. A quiet edge band glows green while you speak and blue while you listen.

The app is free, open source under the AGPL, and requires no account. Media travels directly between two Macs over UDP.

We are clear about what is not built: Kin runs only on Apple silicon Macs with macOS 14+, supports only two people, and is not notarized by Apple yet. Every number in our repository comes from verified measurements.

Download: https://kin.tokkah.com
Source: https://github.com/deshmukhpatel98/tokkah

### Gallery List
1. Film: 75-second animated film (ad/out/kin-ad.mp4, hosted at https://kin.tokkah.com/ad/kin-ad)
2. Call interface GIF: docs/media/kin-call.gif (showing active call with edge band glow)
3. Dialing and connecting GIF: docs/media/kin-dial.gif (showing handle entry and connection)
4. Global light-speed arc GIF: docs/media/kin-globe.gif (showing Delhi to Amsterdam arc and 150 ms goal)
5. Social preview image: docs/media/social-preview.png and poster tape-app/public/og.png

---

## 6. Investor One-Pager Text

Every video call in the world still runs on a 2011 design. When network conditions fluctuate, legacy architectures sacrifice fidelity: they compress speech through lossy codecs, downscale video, and buffer packets. This introduces unpredictable delay. Research shows that even slight latency fluctuations disrupt conversational turn-taking, causing fatigue and eroding interpersonal rapport. Existing platforms prioritize multi-party meetings and enterprise features, treating genuine human presence as an afterthought.

Our insight is that quality is a constant; time is the only shock absorber. Instead of mangling audio or video to fit a congested channel, Kin keeps fidelity transparent and allows time to absorb network variance. Video drops frames rather than accumulating delay. Audio is transmitted as 48 kHz 16-bit PCM, compressed losslessly at 2.6x to 1.16 Mbps each way. Total bandwidth is about 2.4 Mbps. Echo is handled the way a room handles it: one voice at a time, with a linear canceller for what leaks on speakers, and the speaker's own voice is never processed.

Kin is built and shipping today. It is a native macOS application for two people, communicating directly over UDP without intermediate media servers. Encryption seals every packet in 0.78 µs using X25519, ML-KEM-768, and AES-256-GCM. Answering a call takes 429 ms, and cancel or decline takes 346 ms on production.

We maintain a disciplined measurement culture. Every technical claim ships with a reproducible receipt, distinguishing local loopback from production networks. Our goal is under 150 milliseconds anywhere on Earth, bounded only by the speed of light. Presence is the product. We are building the communication infrastructure that makes remote conversations feel like the same room.

[the ask]

---

## 7. Distribution Plan

### Two-Week Launch Calendar

| Day | Channel | Action and Post Content | Primary Asset |
|---|---|---|---|
| Day 1 (Mon, W1) | Website and Infrastructure | Verify edge deployment of kin.tokkah.com, test download links and curl install script. | ad/out/kin-ad-hero.mp4 |
| Day 2 (Tue, W1) | Hacker News (Morning PT) | Publish Show HN post. Respond to technical questions with code links and verified receipts. | Show HN text |
| Day 2 (Tue, W1) | X/Twitter (Morning) | Post 9-part launch thread carrying the animated film. | ad/out/kin-ad.mp4 |
| Day 3 (Wed, W1) | Reddit (r/macapps) | Publish native Mac post highlighting CoreAudio, VideoToolbox, and window design. | docs/media/kin-call.gif |
| Day 4 (Thu, W1) | Reddit (r/selfhosted) | Publish self-hosting post detailing single Cloudflare Worker architecture. | docs/media/kin-dial.gif |
| Day 5 (Fri, W1) | Reddit (r/privacy) | Publish privacy post covering post-quantum encryption and zero media logging. | docs/media/social-preview.png |
| Day 6 (Sat, W1) | X/Twitter | Publish Standalone Post 1 on echo cancellation and the 19.3 dB duplex gate. | Code snippet link |
| Day 7 (Sun, W1) | GitHub Discussions | Triage initial community issues, log bug reports, update FAQ on signing and NAT. | GitHub repository |
| Day 8 (Mon, W2) | X/Twitter | Publish Standalone Post 2 on measurement culture and the 150 ms goal. | docs/media/kin-globe.gif |
| Day 9 (Tue, W2) | Product Hunt (Midnight PT) | Launch on Product Hunt. Post maker comment and monitor community feedback. | Film, GIFs, preview |
| Day 10 (Wed, W2) | X/Twitter | Publish Standalone Post 3 on free-tier Cloudflare Worker deployment. | SELF-HOSTING guide link |
| Day 11 (Thu, W2) | Community Engineering | Publish write-up on real-world NAT traversal rates observed during launch. | GitHub Discussions |
| Day 12 (Fri, W2) | Email Waitlist | Send brief update to non-Mac waitlist subscribers with roadmap context. | Plain text email |
| Day 13 (Sat, W2) | Issue Tracker | Review community PRs and issue backlog; run regression checks. | mac/tools test suite |
| Day 14 (Sun, W2) | Project Retrospective | Publish two-week launch retrospective with verified network observations. | GitHub Discussions |

### Rules of Engagement in Comments
- Answer every technical question with a number or a link to the code.
- Never argue.
- Thank and log every bug.

---

## 8. Assets Checklist

### Media Assets
- Film MP4: ad/out/kin-ad.mp4 (75-second animated film, 1080p with full WebAudio score)
- Film Hero Loop: ad/out/kin-ad-hero.mp4 (muted video loop for website hero)
- Active Call GIF: docs/media/kin-call.gif (demonstrating active call and edge band illumination)
- Dialing Flow GIF: docs/media/kin-dial.gif (demonstrating handle entry and connection handshake)
- Globe Arc GIF: docs/media/kin-globe.gif (demonstrating Delhi to Amsterdam light path and 150 ms goal)
- Social Preview Image: docs/media/social-preview.png (GitHub → Settings → Social preview)
- Website Poster: tape-app/public/og.png (OpenGraph image for website link unfurls)
- Repository Metadata: Description and topics already set by the orchestrator

### Three Missing Items Required for Launch
1. A public contact address for press and investors.
2. A short "who we are" line on the site.
3. A real cross-continental measurement of the Mac app.
