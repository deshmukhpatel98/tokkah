import AVFoundation
import AppKit
import CoreImage
import Darwin
import Foundation

// tk -- the latency floor, measured.
//
//   tk --listen 7001 --peer 127.0.0.1:7002            (leg A)
//   tk --listen 7002 --peer 127.0.0.1:7001 --mute     (leg B, loopback on one Mac)
//
// Loopback on one machine is deliberately the FIRST measurement: both ends share
// one host clock, so mouth-to-ear needs no clock sync and no estimate, and the
// network contributes nothing. Whatever it reports is the pipeline, exactly.
// Only once that number is known is it worth putting the Pacific in the middle.

let VERSION = "0.9.4"

// --version must work, exit 0, and touch no hardware: the updater probes a
// candidate binary with it before allowing it to replace a running one, so this
// is the smoke test that keeps a bad release from bricking the far machine.
if CommandLine.arguments.contains("--version") { print(VERSION); exit(0) }

func arg(_ name: String) -> String? {
  let a = CommandLine.arguments
  guard let i = a.firstIndex(of: "--" + name), i + 1 < a.count else { return nil }
  return a[i + 1]
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains("--" + name) }

let listenPort = UInt16(arg("listen") ?? "7001") ?? 7001
let peerSpec = arg("peer") ?? "127.0.0.1:7002"
let parts = peerSpec.split(separator: ":")
guard parts.count == 2, let pPort = UInt16(parts[1]) else {
  fputs("bad --peer, want host:port\n", stderr); exit(2)
}
let peerHost = String(parts[0])

fputs("tk \(VERSION)  listen=\(listenPort) peer=\(peerHost):\(pPort) timebase=\(Clock.timebaseDescription)\n", stderr)
fputs("packet=\(FPP) frames (\(String(format: "%.2f", Double(FPP) / SR * 1000)) ms)  ring=\(RING) pkts\n", stderr)

// UPDATE BEFORE TOUCHING THE AUDIO DEVICES. On launch the check is synchronous
// and cheap; if a newer build exists we re-exec into it and never open a device
// with stale code. --no-update is for bisecting a regression, nothing else.
if !flag("no-update") {
  if let (m, _) = Update.available(current: VERSION) { Update.apply(m) }
  Update.startPolling(current: VERSION, every: 60)
}

guard let wire = Wire(listen: listenPort, peerHost: peerHost, peerPort: pPort) else {
  fputs("socket/bind failed on port \(listenPort)\n", stderr); exit(1)
}

// --stun: print what the outside world sees this socket as, and exit. The
// smallest possible check of the piece everything else depends on.
if flag("stun") {
  // TWO servers on ONE socket, because the answer that matters is not "what is my
  // address" but "does this NAT give the same external port whatever I talk to".
  //   same port  -> endpoint-independent mapping: two peers can punch a hole and
  //                 talk directly, which is the whole latency argument.
  //   different  -> symmetric NAT: direct connection is impossible and every
  //                 packet has to go through a relay, adding a detour to a number
  //                 this project measures in milliseconds.
  // Guessing this wrong means building the wrong transport, so it is measured.
  let a = Stun.discover(fd: wire.fd, server: arg("stunserver") ?? "stun.cloudflare.com")
  let b = Stun.discover(fd: wire.fd, server: "stun.l.google.com", port: 19302)
  guard let m1 = a else { fputs("stun: no answer\n", stderr); exit(1) }
  print("cloudflare: \(m1.ip):\(m1.port)")
  if let m2 = b {
    print("google:     \(m2.ip):\(m2.port)")
    if m1.port == m2.port && m1.ip == m2.ip {
      print("NAT: endpoint-independent mapping -- direct peer-to-peer WILL work")
    } else {
      print("NAT: address/port-dependent (symmetric) -- direct P2P will NOT work from here,")
      print("     a relay is required and it costs a detour on every packet")
    }
  } else {
    print("google:     no answer (cannot classify the NAT)")
  }
  exit(0)
}

// ── --room: find the peer without being told its address ────────────────────
//
// The reason this exists: the two machines under test are in two different
// houses. Neither has a routable address, so "--peer 192.168.x.y" cannot
// possibly work between them. This discovers our own public mapping with STUN,
// swaps it through the room, and points the media at what comes back.
//
// Measured on this network first: the NAT gives the same external port whatever
// it is talking to, so a direct hole-punched path is possible and no relay is
// needed. If that had come back symmetric, this whole approach would have been
// the wrong one and the honest answer would have been a relay.
if let room = arg("room") {
  let me = arg("id") ?? "mac-\(getpid())"
  guard let mapped = Stun.discover(fd: wire.fd, server: arg("stunserver") ?? "stun.cloudflare.com") else {
    fputs("room: STUN found no mapping -- cannot advertise an address\n", stderr); exit(1)
  }
  let mine = "\(mapped.ip):\(mapped.port)"
  let myLocal = localIPv4().map { "\($0):\(listenPort)" }
  fputs("room \(room): I am \(me), public \(mine)\(myLocal.map { ", local " + $0 } ?? "")\n", stderr)
  var found = false
  for attempt in 1...60 {
    // Re-publish every poll: the lease is short on purpose, because an address is
    // only true while the NAT binding behind it lives.
    let peers = Rendezvous.exchange(room: room, me: me, addr: mine, local: myLocal)
    if let p = peers.first {
      // BOTH addresses, and let the network decide. Guessing between them -- same
      // public IP means same LAN, so use the private address -- is right most of
      // the time and produces a call that never starts when it is wrong. Hairpin
      // support, carrier-grade NAT, a VPN on one side: each breaks a different
      // guess. Racing them costs two 32-byte probes.
      wire.addCandidate(ip: p.ip, port: p.port)
      var cands = ["\(p.ip):\(p.port)"]
      if let lip = p.localIP, let lport = p.localPort {
        wire.addCandidate(ip: lip, port: lport)
        cands.append("\(lip):\(lport)")
      }
      // A provisional destination so media has somewhere to go in the moments
      // before a probe comes back; the first packet that arrives replaces it with
      // an address known to work.
      wire.setPeer(ip: p.ip, port: p.port)
      fputs("room \(room): peer \(p.id) (\(p.ageMs) ms old) -- racing \(cands.joined(separator: " and "))\n", stderr)
      found = true
      break
    }
    if attempt == 1 { fputs("room \(room): waiting for the other side...\n", stderr) }
    usleep(2_000_000)
  }
  if !found {
    fputs("room \(room): nobody else arrived in 2 minutes.\n", stderr)
    exit(1)
  }
  // Keep the lease alive and keep re-reading: if the peer restarts, its NAT port
  // changes and the old address goes dead silently.
  //
  // NO RE-STUN after this point, and that is deliberate. STUN reads from the
  // socket, the media loop reads from the same socket, and two threads calling
  // recvfrom on one descriptor steal each other's packets -- the media loop would
  // discard STUN replies as unknown magic while the STUN thread quietly ate
  // audio. The correct fix is to demultiplex STUN inside the media loop, and
  // until that exists the mapping does not need rediscovering: 375 audio packets
  // a second keep the NAT binding alive far more reliably than a probe would.
  // Punch every candidate until one answers. Fast while unresolved, because this
  // is the window the user experiences as "is it connecting?", and both NATs need
  // an outbound packet before either will pass an inbound one.
  Thread {
    var announced = false
    while true {
      if wire.locked {
        if !announced {
          announced = true
          fputs("room \(room): connected via \(wire.lockedFrom)\n", stderr)
        }
        Thread.sleep(forTimeInterval: 1.0)
        continue
      }
      wire.probeAllCandidates()
      Thread.sleep(forTimeInterval: 0.2)
    }
  }.start()

  Thread {
    while true {
      Thread.sleep(forTimeInterval: 20)
      let peers = Rendezvous.exchange(room: room, me: me, addr: mine, local: myLocal)
      // Only worth acting on while unresolved. Once a packet has arrived, the
      // address it came from is better evidence than anything the rendezvous can
      // tell us -- and re-pointing a working call at a directory entry is how a
      // live call gets broken by bookkeeping.
      if let p = peers.first, !wire.locked {
        wire.addCandidate(ip: p.ip, port: p.port)
        if let lip = p.localIP, let lport = p.localPort { wire.addCandidate(ip: lip, port: lport) }
      }
    }
  }.start()
}

var keyAsksOnLoss = 0
var gDumpedMetal = false
var gDecLuma: Double = -1
var gDecLumaTick = 0
var gThetaMs: Double = 0
var gThetaValid = false
let audio = Audio()
audio.wire = wire
// TK_MUTE=1 in the environment silences playout as surely as --mute does.
// This exists because a flag you have to remember on every one of forty test
// commands is a flag you will forget on the forty-first, and here the cost of
// forgetting is landing on someone's speakers while they are asleep. An exported
// variable is remembered once.
// MICROPHONE PERMISSION, ASKED AND ANSWERED BEFORE ANYTHING ELSE.
//
// A denied microphone produces "cap 0/s" and nothing else -- identical to a
// muted mic, a wrong default device, or a bug in this code. That ambiguity has
// already cost me a whole false root cause once in this project, and it is the
// single most likely thing to stop someone the first time they run this on a
// machine I cannot see. So it is checked explicitly and named.
//
// A command-line tool has no bundle, so macOS attributes the grant to the
// terminal that launched it -- which is why the fix names the terminal app and
// not "tk".
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
  break
case .notDetermined:
  let sem = DispatchSemaphore(value: 0)
  var granted = false
  AVCaptureDevice.requestAccess(for: .audio) { granted = $0; sem.signal() }
  fputs("microphone: asking permission (look for a dialog)...\n", stderr)
  _ = sem.wait(timeout: .now() + 60)
  if !granted {
    fputs("microphone: NOT GRANTED. tk will play the other side but send silence.\n"
        + "  Grant it to the app you launched this from (Terminal, iTerm, VS Code...) in\n"
        + "  System Settings > Privacy & Security > Microphone, then run tk again.\n", stderr)
  }
case .denied, .restricted:
  fputs("microphone: DENIED. You will hear the other person and they will hear silence.\n"
      + "  Enable the app you launched this from (Terminal, iTerm, VS Code...) in\n"
      + "  System Settings > Privacy & Security > Microphone, then run tk again.\n", stderr)
@unknown default:
  break
}

// --no-fec exists so redundancy can be A/B'd against itself. A feature that
// cannot be turned off cannot be measured, and this one costs bandwidth.
let fecAllowed = !flag("no-fec")
audio.mute = flag("mute") || (ProcessInfo.processInfo.environment["TK_MUTE"] == "1")
// SAID OUT LOUD, because "played 754/s" is identical whether the samples are
// audio or zeros -- the counter cannot tell me the speaker is silent, and a
// check that cannot fail is not a check.
if audio.mute { fputs("PLAYOUT MUTED (zeros to the speaker; capture and all measurements unaffected)\n", stderr) }
// --jit auto (default) sizes the buffer from measured arrival slack. --jit N
// pins it, which is what an A/B needs and what a bisect needs.
let jitArg = arg("jit") ?? "auto"
audio.jitAuto = (jitArg == "auto")
// Auto starts HIGH and descends. The two directions are not symmetric in what
// they cost a listener: arriving at the right buffer from below means walking
// through it, and every step of that walk is a click in someone's ear (measured:
// 18 concealed packets while the controller learned the level). Arriving from
// above costs a few extra milliseconds for the first fifteen seconds of the call
// and nothing else. So the descent is the default and the growth path is only
// there for a path that degrades mid-call.
audio.jitTarget = audio.jitAuto ? 6 : (Int(jitArg) ?? 2)

// ── Video ───────────────────────────────────────────────────────────────────
//
// --video off | <path.mov> | camera. A file by default because the camera needs a
// permission prompt a background process cannot show, and because a repeatable
// input is what makes two runs comparable. The file is a REAL talking head: a
// synthetic pattern compresses to almost nothing, so a call carrying one measures
// an empty pipe and reports it as video.
let videoArg = arg("video") ?? "off"
var vsource: FrameSource?
var venc: VEncoder?
let vdec = VDecoder()
let vasm = VideoAssembler()
var vscratch = UnsafeMutablePointer<UInt8>.allocate(capacity: VHDR + VPAYLOAD + 64)
var vseq: Int32 = 0
var vg2g = Quantiles()
var vDecoded = 0, vSentFrames = 0, vBytesSent = 0

// RECEIVING is wired unconditionally. A peer that sends no video must still be
// able to show yours -- tying the receive path to the send path made the
// receiver look like a decoder failure when it had simply never been connected.
vasm.onFrame = { data, host in vdec.decode(data, hostTime: host) }
// GLASS TO GLASS, the only honest way: the capture instant travels with the
// frame and the subtraction happens at decoder output. No estimate, no clock
// model -- on loopback both ends share one host clock, so this is the pipeline
// exactly. Display is not inside this number yet, and is named as such.
// --dump <path.png>: write one decoded frame and exit that path. A bitrate
// cannot tell you whether the picture is any good -- this project has already
// shipped an upside-down camera past a green rig. Looking at the output is the
// verification; everything else is a proxy for it.
// --window opens a real window and shows the peer. Without it tk is a meter;
// with it, it is a call.
var display: Display?
var mdisplay: MetalDisplay?
// --display metal draws the frame by hand so that (a) the time it actually
// reaches the panel can be READ from Metal instead of inferred from a refresh
// rate, and (b) --vsync 0 can skip the compositor's synchronised pass. Default
// stays the AVSampleBufferDisplayLayer path until the measurement says otherwise.
let displayKind = arg("display") ?? "avsbdl"
if flag("window") {
  // NSApplication FIRST. AppKit will build an NSWindow before the application
  // object exists and simply never show it -- decode ran at 31 fps into a window
  // that was not on screen, which looks like a display bug and is an ordering
  // bug. Touching .shared here is what creates it.
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  if displayKind == "metal" {
    if let m = MetalDisplay(vsyncOff: arg("vsync") == "0", fullscreen: flag("fullscreen")) {
      m.open(title: "tokkah — \(peerHost)", w: 1280, h: 720)
      mdisplay = m
      fputs("display: metal, vsync \(m.vsyncOff ? "OFF (tearing allowed)" : "on")"
          + "\(m.fullscreen ? ", fullscreen" : ""), refresh \(String(format: "%.2f", m.refreshMs)) ms\n", stderr)
    } else {
      fputs("display: metal unavailable, falling back\n", stderr)
    }
  }
  if mdisplay == nil {
    let d = Display()
    d.open(title: "tokkah — \(peerHost)", w: 1280, h: 720)
    display = d
  }
}

let dumpTo = arg("dump")
var dumped = false
vdec.onDecoded = { img, capHost in
  // What the far end's picture actually looks like after decoding. Both ends of
  // the test rig play the same file, so a decoded mean luma that wanders away
  // from the encoder's reported luma is corruption -- the one symptom that
  // frames-lost, decFails and fps all agree to call healthy.
  gDecLumaTick += 1
  if gDecLumaTick % 15 == 0, let pb = img as CVPixelBuffer? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
      let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
      let h = CVPixelBufferGetHeightOfPlane(pb, 0), w = CVPixelBufferGetWidthOfPlane(pb, 0)
      let p = base.assumingMemoryBound(to: UInt8.self)
      var sum = 0, n = 0, y = 0
      while y < h { var x = 0; while x < w { sum += Int(p[y * stride + x]); n += 1; x += 8 }; y += 8 }
      if n > 0 { gDecLuma = Double(sum) / Double(n) }
    }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
  }
  // Same rule as audio: the capture stamp is the PEER's clock, so without the
  // offset this is not a latency, it is the difference between two epochs.
  if gThetaValid { vg2g.add(Clock.msSigned(Clock.now(), capHost) + gThetaMs) }
  vDecoded += 1
  display?.show(img)
  // Stamped HERE, not inside show(): the measurement is decode-to-glass, and a
  // timestamp taken after the draw call would quietly exclude the draw.
  if let m = mdisplay, let pb = img as CVPixelBuffer? {
    m.show(pb, at: Clock.now())
    if let mp = arg("dump-metal"), !gDumpedMetal, vDecoded > 40 {
      gDumpedMetal = true
      fputs("metal dump: \(m.dumpRendered(pb, to: mp))\n", stderr)
    }
  }
  if let path = dumpTo, !dumped, vDecoded > 30 {
    dumped = true
    let ci = CIImage(cvImageBuffer: img)
    let ctx = CIContext()
    if let cs = CGColorSpace(name: CGColorSpace.sRGB),
       let png = ctx.pngRepresentation(of: ci, format: .RGBA8, colorSpace: cs) {
      try? png.write(to: URL(fileURLWithPath: path))
      fputs("dumped a decoded frame to \(path)\n", stderr)
    }
  }
}

if videoArg != "off" {
  do {
    let src: FrameSource = videoArg == "camera"
      ? CameraSource()
      : FileSource(path: videoArg, fps: Double(arg("fps") ?? "30") ?? 30)
    let e = try VEncoder(width: 1280, height: 720, bitrate: Int(arg("vbitrate") ?? "3000000") ?? 3_000_000)
    e.requestKeyframe()
    src.onFrame = { pb, host in e.encode(pb, hostTime: host) }
    e.onEncoded = { data, host, _ in
      wire.sendVideo(seq: vseq, capHost: host, payload: data, scratch: vscratch)
      vseq += 1; vSentFrames += 1; vBytesSent += data.count
    }
    try src.start()
    vsource = src; venc = e
    fputs("video: \(src.describe) -> H.264 1280x720, no B-frames, realtime\n", stderr)
  } catch {
    fputs("video: disabled (\(error))\n", stderr)
  }
}

// ── Keyframe requests ───────────────────────────────────────────────────────
//
// The receiver asks, the sender obeys. Driven by OUTCOME -- "I have fragments
// arriving and still cannot decode" -- rather than by a timer, so a healthy call
// never sends one and a blind one recovers in a fifth of a second. Rate limited,
// because the condition that produces it produces it on every single frame.
let kscratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)
wire.onKeyRequest = { venc?.requestKeyframe() }
Thread {
  var lastAsk = 0.0
  var lastDecodes = -1
  var lastMissing = 0
  while true {
    Thread.sleep(forTimeInterval: 0.2)
    let blind = vasm.fragsIn > 0 && (vdec.noFormat > 0 || vdec.decodes == lastDecodes)
    lastDecodes = vdec.decodes
    let now = Date().timeIntervalSinceReferenceDate

    // A LOST FRAME IS A CORRUPTED PICTURE, not a missing one.
    //
    // There are no B-frames here, which is right for latency, but it means every
    // frame references the one before it. Lose one and the decoder keeps decoding
    // happily against a reference it does not have -- `decFails 0`, `noFmt 0`,
    // 30 fps, and a picture that is quietly wrong until something else happens to
    // send a keyframe. The old trigger only fired when decoding STOPPED, which is
    // the one symptom this failure does not have.
    //
    // Rate-limited, because under sustained loss the repair must not become the
    // problem: a keyframe is a few KB against a 300-byte P-frame.
    let lost = vasm.missing > lastMissing
    lastMissing = vasm.missing
    if lost && now - lastAsk > 0.4 {
      lastAsk = now
      keyAsksOnLoss += 1
      wire.requestKeyframe(scratch: kscratch)
    } else if blind && vdec.decodes == 0 || (blind && now - lastAsk > 1.0) {
      lastAsk = now
      wire.requestKeyframe(scratch: kscratch)
    }
  }
}.start()

// The socket thread. Not the audio thread and not the main thread: a blocking
// recvfrom on the render callback would be a dropout, and on main it would fight
// the reporter for the runloop.
// Network impairment, for measuring what a real path costs before there is a
// real path to measure. Off unless asked for, and impossible to overlook when on.
let impair = Impair(dropPct: Double(arg("imp-drop") ?? "0") ?? 0,
                    burstMs: Double(arg("imp-burst") ?? "0") ?? 0,
                    jitterMs: Double(arg("imp-jitter") ?? "0") ?? 0)
if impair.enabled {
  wire.impair = impair
  if impair.jitterMs > 0 { wire.armDelayQueue() }
  fputs("IMPAIRED: \(impair.description) -- numbers from this run describe a damaged path on purpose\n", stderr)
}

// Encryption. On by default; --no-crypt exists for interop with an older build
// and for reading packets in a capture while debugging, and it says so loudly.
//
// The room code is the HKDF salt when there is one. It is the one secret that
// never crosses the wire -- one person says it to the other -- so it is what
// makes the exchange authenticated rather than merely private.
// --secret sets the shared secret independently of how the two ends found each
// other. The room code is a sensible default for it, but tying the two together
// was wrong: it meant a pair using --peer directly could not have an
// authenticated channel at all, and it made "change the key" and "change where
// you look for the peer" the same act -- which is also what made the first
// mismatched-key test measure nothing.
let cryptoSalt = arg("secret") ?? arg("room") ?? ""
let crypto: Crypto? = flag("no-crypt") ? nil : Crypto(roomSalt: cryptoSalt)
if let c = crypto {
  wire.crypto = c
  Thread {
    // Fast until a key exists, then slow. The slow beat is not idle chatter: it
    // is how a peer that restarts with a fresh key gets re-keyed without anyone
    // restarting the call.
    while true {
      wire.sendHandshake()
      Thread.sleep(forTimeInterval: c.established ? 5.0 : 0.25)
    }
  }.start()
} else {
  fputs("crypto: DISABLED by --no-crypt -- audio and video go out in the clear\n", stderr)
}

// Clock sync, before the receive loop exists to answer probes.
let tsync = TimeSync()
wire.tsync = tsync
Thread {
  // Fast at first, then settle. The window wants a spread of samples quickly so
  // the first honest number arrives within a second or two of the call starting;
  // after that a probe a second is plenty to track drift between two crystals,
  // which is parts per million.
  var n = 0
  while true {
    wire.sendTimeProbe()
    n += 1
    Thread.sleep(forTimeInterval: n < 24 ? 0.15 : 1.0)
    if let th = tsync.thetaNs {
      audio.thetaMs = Double(th) / 1e6
      audio.thetaValid = true
      gThetaMs = audio.thetaMs
      gThetaValid = true
    }
  }
}.start()

let t = Thread { wire.recvLoop(into: audio.ring, video: vasm) }
t.start()

do { try audio.start() } catch {
  fputs("audio start failed: \(error)\n", stderr)
  fputs("if this is a permission error, macOS must be allowed to use the microphone for the terminal running this.\n", stderr)
  exit(1)
}

// ── The report ──────────────────────────────────────────────────────────────
//
// Once a second, and every line is a RATE from differenced cumulative counters.
// Not a moving average: a windowed average read across a state change has
// already inverted a result in this project, and a rate you can verify by
// arithmetic is worth more than a smooth one.
var last = (sent: 0, recv: 0, played: 0, concealed: 0, dup: 0, tooOld: 0, jumps: 0, cap: 0)
var lastV = (dec: 0, sent: 0, bytes: 0)
var lastVBytesPrev = 0
let expected = SR / Double(FPP)   // 375 packets/s at 128 frames

// THE BUDGET, PRINTED ONCE, so every future change is measured against a stated
// floor rather than against a memory of one. Anything added to this app has to
// justify itself against this line. That is the whole discipline: the number is
// cheap to print and impossible to argue with.
usleep(300_000)
let pktMs = Double(FPP) / SR * 1000
let jitMs = Double(audio.jitTarget) * pktMs
func ln(_ label: String, _ v: Double, _ note: String) {
  fputs("        " + label.padding(toLength: 16, withPad: " ", startingAt: 0)
        + String(format: "%6.2f", v) + " ms   " + note + "\n", stderr)
}
fputs("\nbudget\n", stderr)
ln("mic device", audio.inLatencyMs, "hardware, unavoidable")
ln("packetise", pktMs, "one packet must fill before it can be sent")
ln("jitter buffer", jitMs, audio.jitAuto
   ? "\(audio.jitTarget) packets to start, then sized from measured arrival slack"
   : "--jit \(audio.jitTarget) packets, pinned")

// ── The jitter buffer sizes itself ──────────────────────────────────────────
//
// A fixed jitter buffer is a hidden assumption about the network, and this
// project has been bitten by that whole bug class repeatedly: a constant with a
// duration in it is a limit on how far away the other person is allowed to be.
// 5.33 ms is right for one path and wrong for every other one -- too small over
// a jittery mobile leg (it conceals, which is audible) and too large on a LAN
// (it costs latency for nothing).
//
// The control signal is arrival slack: how long before its deadline each packet
// turned up. Measured locally, so it needs no peer clock and reads identically
// at 1 km and 10,000 km. On a clean path slack p01 == buffer exactly, so
// (p01 - one packet) is the headroom that would remain if the buffer shrank by
// one. That is the whole rule.
//
// ASYMMETRIC on purpose. Growing is instant, shrinking needs the evidence to
// hold for 10 seconds. Being one packet too small is a click in someone's ear;
// being one packet too large costs 2.67 ms. Those are not comparable, and a
// symmetric controller would trade the audible thing for the inaudible one.
//
// Changing the target mid-call is safe only because of the governor: the read
// cursor closes a 2.67 ms error at 0.4% of playback rate, so a step takes about
// 667 ms of audio and produces no click, no reprime and no gap. The buffer is a
// continuously adjustable parameter, not a restart.
if audio.jitAuto {
  let t = Thread {
    // JIT_MIN is 2 and that is a structural floor, not a cautious guess. A
    // packet holds exactly one device buffer (FPP == 128 frames both ways), so at
    // one packet of buffer the render callback and the socket are contending for
    // the same 2.67 ms slot: the callback can arrive to find the packet it needs
    // written a few microseconds from now. Measured -- at jit 1 the loopback path
    // (no network at all) still concealed 3 packets, while jit 2 on the same run
    // concealed none and held slack p01 at exactly 5.33 ms. The minimum buffer is
    // one render granularity above zero, and shrinking below that is not a
    // latency win, it is a click generator.
    let JIT_MIN = 2
    // A CEILING IN MILLISECONDS, not in packets. Written as 8 packets it meant
    // 21 ms at the old packet size and silently became 10.7 ms when packets
    // halved -- the maximum buffer was cut in half by a change that had nothing
    // to do with it. Same family as every other duration hidden inside a count in
    // this codebase (queue tolerance in ms; a codec win is a change of units).
    let JIT_MAX = max(JIT_MIN + 2, Int((30.0 / pktMs).rounded()))
    let GROW_BELOW_MS = 1.0     // headroom this thin is one jitter spike from a click
    let SHRINK_ABOVE_MS = 2.0   // and this much would survive losing a packet of buffer
    let SHRINK_HOLD = 5         // consecutive 2 s windows -- 10 s of agreement
    let SHRINK_HOLD_FAST = 2    // ...but 4 s while still descending from the safe start
    var calm = 0
    var lastConcealed = 0
    var lastSnaps = 0
    var lastLate = 0
    var lastLostForFec = 0
    var fecCalm = 0
    // Redundancy has to earn its bandwidth. Measured: at 1% UNIFORM loss it
    // recovered 916 of 966 (94.8%) and cut concealment 18x. At 3% loss in 20 ms
    // BURSTS it recovered 87 of 430 (20%) and cut concealment by 2.6% -- because
    // the second copy travels one packet behind the first, and a burst takes both.
    // Paying double for the audio payload on a link already dropping 3% in bursts
    // is not a neutral act; it can be the thing that pushes it over.
    var fecRecovered0 = 0, fecLost0 = 0, fecWindows = 0
    var fecUselessUntil = 0.0, fecBackoff = 60.0
    // A LEVEL THAT FAILED IS REMEMBERED. Without this the controller shrinks,
    // hears a click, grows, waits out its hold and shrinks into the same click
    // forever -- observed on this rig cycling 2 -> 1 -> 2 -> 1 with three
    // concealed packets each lap. Backoff doubles, so a path that genuinely
    // improves is still re-probed, just not at the cost of a click a minute.
    var unsafeBelow = 0          // levels < this are known bad
    var probeAt = 0.0            // seconds-since-start after which to retry one
    var backoff = 60.0
    var t = 0.0
    while true {
      Thread.sleep(forTimeInterval: 2.0)
      t += 2.0
      let r = audio.ring
      guard r.pos >= 0 else { continue }
      let conc = r.concealed - lastConcealed
      lastConcealed = r.concealed
      let late = r.lateArrivals - lastLate
      lastLate = r.lateArrivals

      // REDUNDANCY FOLLOWS THE EVIDENCE, not a setting. It doubles the audio
      // payload, so a clean call must not pay for it -- and a call that IS losing
      // packets should not wait for anyone to notice. One lost packet in a
      // two-second window turns it on; thirty seconds clean turns it off.
      //
      // Driven by LOST, not by concealed: concealment also covers starvation, and
      // a second copy of a packet that has not been sent yet is not a thing.
      let lostNow = r.concealLost - lastLostForFec
      lastLostForFec = r.concealLost
      if fecAllowed, lostNow > 0, !audio.redundancy, t >= fecUselessUntil {
        audio.redundancy = true
        fecRecovered0 = r.recovered
        fecLost0 = r.concealLost
        fecWindows = 0
        fputs("redundancy ON (\(lostNow) lost in 2 s) -- each packet now carries the previous one\n", stderr)
        fecCalm = 0
      } else if audio.redundancy {
        fecWindows += 1
        // Judge it on its own record, once there is enough of one to judge. A
        // recovery rate this low means the losses are bursts, and an offset of one
        // packet cannot reach past a burst -- so the bandwidth is being spent for
        // almost nothing and is better not spent.
        let rec = r.recovered - fecRecovered0
        let lost = r.concealLost - fecLost0
        if fecWindows >= 5, rec + lost >= 20 {
          let rate = Double(rec) / Double(rec + lost)
          if rate < 0.4 {
            audio.redundancy = false
            fecUselessUntil = t + fecBackoff
            fecBackoff = min(fecBackoff * 2, 600)
            fputs("redundancy OFF -- recovered only \(rec) of \(rec + lost) "
                + "(\(Int(rate * 100))%), so these are bursts and a one-packet offset "
                + "cannot reach them. Not spending the bandwidth; retrying in \(Int(fecBackoff / 2)) s\n", stderr)
            fecCalm = 0
            continue
          }
        }
        if lostNow > 0 { fecCalm = 0 } else {
          fecCalm += 1
          if fecCalm >= 15 {
            audio.redundancy = false
            fecCalm = 0
            fecBackoff = 60
            fputs("redundancy OFF (30 s without a lost packet)\n", stderr)
          }
        }
      }
      let snapped = r.snaps - lastSnaps
      lastSnaps = r.snaps
      guard let p01 = r.slackWin.p(0.01) else { continue }
      r.slackWin.reset()
      // The WORST arrival in the window is what a shrink has to survive, not the
      // 1st percentile: the p01 at jit 2 read a comfortable 5.33 ms while the
      // actual outcome one packet lower was concealment.
      let worst = r.slackWinMin == 1e9 ? p01 : r.slackWinMin
      r.slackWinMin = 1e9
      let head = worst - pktMs   // headroom that would remain one packet smaller

      // SLACK LIES WHILE THE CURSOR IS BEHIND, and it lies in the flattering
      // direction. Slack is measured against the read cursor, so a cursor that
      // has fallen behind makes every packet look like it arrived with room to
      // spare. Caught on this rig: during two 200 ms render stalls the buffer
      // controller read p01 2.69 ms, judged the path healthy and SHRANK -- while
      // m2e was passing 400 ms. A controller that can be fooled by the failure
      // it exists to catch is worse than no controller.
      //
      // So shrinking requires the governor to be CONVERGED first: the cursor sits
      // where it was told to, which is the only condition under which slack
      // describes the network instead of describing the cursor.
      let converged = abs(r.errMs) < 2.0
      // ATTRIBUTION BEFORE ACTION. A snap means the read cursor fell more than
      // 29 ms behind -- a stall, not jitter. Concealment in the same window is
      // that stall's doing, and a buffer one packet larger would not have
      // prevented any of it. Growing anyway is how a single transient hiccup
      // becomes permanently higher latency: measured here as two stalls ratcheting
      // the buffer 3 -> 4 -> 5 and holding m2e 1.7 ms worse for the rest of the
      // run, with a 240 s backoff before it would even reconsider.
      //
      // So the stall is absorbed by the snap, the level is held, and nothing is
      // marked unsafe on this evidence.
      if snapped > 0 {
        calm = 0
        fputs("jit: \(snapped) snap(s), \(conc) concealed -- stall, not jitter; holding at \(audio.jitTarget)\n", stderr)
      } else if late > 0 || p01 < GROW_BELOW_MS {
        if audio.jitTarget < JIT_MAX {
          audio.jitTarget += 1
          audio.jitGrows += 1
          // What just failed was the level we were AT, so nothing below the new
          // one is safe either.
          unsafeBelow = max(unsafeBelow, audio.jitTarget)
          probeAt = t + backoff
          backoff = min(backoff * 2, 900)
          fputs("jit -> \(audio.jitTarget) (grew: \(late) late arrivals, slack p01 \(String(format: "%.2f", p01)) ms)"
              + "  -- below \(unsafeBelow) marked unsafe, next probe in \(Int(backoff / 2)) s\n", stderr)
        }
        calm = 0
      } else if audio.jitTarget <= unsafeBelow && t < probeAt {
        calm = 0   // known bad, and the backoff has not elapsed
      } else if head > SHRINK_ABOVE_MS && converged && audio.jitTarget > JIT_MIN {
        calm += 1
        // Nothing has failed yet, so we are still descending from the deliberately
        // safe starting buffer and there is no reason to descend slowly. Once a
        // level has actually failed, patience is the whole point.
        let hold = unsafeBelow == 0 ? SHRINK_HOLD_FAST : SHRINK_HOLD
        if calm >= hold {
          audio.jitTarget -= 1
          audio.jitShrinks += 1
          calm = 0
          // This level just proved itself, so the old verdict about it expires.
          // Without this the doubling backoff eventually reaches 15 minutes and a
          // path that recovered stays punished for a failure it no longer has.
          if audio.jitTarget < unsafeBelow { unsafeBelow = audio.jitTarget; backoff = 60 }
          fputs("jit -> \(audio.jitTarget) (shrank: slack p01 \(String(format: "%.2f", p01)) ms, err \(String(format: "%.2f", r.errMs)) ms, \(hold) windows clean)\n", stderr)
        }
      } else {
        calm = 0
      }
    }
  }
  t.stackSize = 256 << 10
  t.start()
}

ln("speaker device", audio.outLatencyMs, "hardware, unavoidable")
fputs("        ----------------------------\n", stderr)
ln("floor", audio.inLatencyMs + pktMs + jitMs + audio.outLatencyMs, "+ network + scheduling")
fputs("\n", stderr)

// With a window, AppKit owns the main thread and the reporter moves off it.
// Without one, main just loops. Same body either way.
func reportLoop() {
  while true {
    usleep(1_000_000)
  let r = audio.ring
  let d = (sent: wire.sent - last.sent, recv: r.recv - last.recv, played: r.played - last.played,
           concealed: r.concealed - last.concealed, dup: r.dup - last.dup,
           tooOld: r.tooOld - last.tooOld, jumps: r.jumps - last.jumps,
           cap: audio.capturedPkts - last.cap)
  last = (wire.sent, r.recv, r.played, r.concealed, r.dup, r.tooOld, r.jumps, audio.capturedPkts)

  let p50 = audio.m2e.p(0.50), p95 = audio.m2e.p(0.95), p99 = audio.m2e.p(0.99)
  func f(_ x: Double?) -> String { x == nil ? "-" : String(format: "%.2f", x!) }
  let heard = Double(d.played) / expected * 100

  let pct = String(format: "%5.1f", heard)
  // A SEND RATE THAT DOES NOT MATCH THE CAPTURE RATE IS A BUG, SAID OUT LOUD.
  //
  // Every packet this app sends is caused by something countable: one per audio
  // packet captured, ~30/s of video, one clock probe. So `sent` should sit just
  // above `cap` and nothing else is legitimate. A handshake that replied to
  // handshakes once put it at 20,972/s against 758 captured -- 26x, about 6 Mbps
  // of echo -- and it cost NOTHING observable on loopback, where bandwidth is
  // free: latency, concealment and every other counter stayed clean. It would
  // have destroyed the first real call between two houses. Both numbers were
  // printed side by side on every line for two releases and I did not look.
  if d.cap > 100, d.sent > d.cap * 2 {
    fputs("WARNING: sending \(d.sent)/s against \(d.cap)/s captured "
        + "-- \(d.sent / max(d.cap, 1))x more packets than anything asked for\n", stderr)
  }
  fputs("cap \(d.cap)/s  sent \(d.sent)/s  recv \(d.recv)/s  played \(d.played)/s (\(pct)%)"
      + "  conceal \(d.concealed)/s (lost \(r.concealLost) late \(r.lateArrivals)"
      + " recovered \(r.recovered)\(audio.redundancy ? " FEC-on" : ""))  dup \(d.dup)  old \(d.tooOld)  jump \(d.jumps)"
      + (r.restarts > 0 ? " peer-restarts \(r.restarts)" : "")
      + "   m2e p50 \(f(p50)) p95 \(f(p95)) p99 \(f(p99)) ms"
      + "  slack p50 \(f(r.slack.p(0.50))) p01 \(f(r.slack.p(0.01))) min \(f(r.slackMin == 1e9 ? nil : r.slackMin)) ms"
      + "  jit \(audio.jitTarget) snap \(r.snaps)"
      + (wire.fmtMismatch > 0 ? "  VERSION-MISMATCH \(wire.fmtMismatch)" : "")
      + "  net rtt \(tsync.bestRttMs.map { String(format: "%.2f", $0) } ?? "-")"
      + " jit \(tsync.rttSpreadMs.map { String(format: "%.2f", $0) } ?? "-")"
      + " (\(tsync.samples) probes)"
      + (crypto.map { c in c.established
           ? "  crypt on (\(c.sealed)/\(c.opened) sealed/opened, \(c.openFails) bad"
             + (c.plaintextRx > 0 ? ", \(c.plaintextRx) plaintext refused" : "") + ")"
           : "  CRYPT PENDING (plaintext \(c.plaintextTx) sent)" } ?? "  crypt off")
      + (impair.enabled ? "  [IMPAIRED \(impair.description), \(impair.dropped) dropped]" : "") + "\n", stderr)
  // Say WHY there is no audio, in the same line as the zero. An instrument that
  // reports a zero and not its cause points investigation at the wrong end.
  if vsource != nil || vasm.fragsIn > 0 {
    var e = venc?.encLatUs ?? Quantiles(), dl = vdec.decLatMs, g = vg2g
    let dv = vDecoded - lastV.dec
    let sv = vSentFrames - lastV.sent
    let mbps = Double(vBytesSent - lastV.bytes) * 8 / 1e6
    lastV = (vDecoded, vSentFrames, vBytesSent)
    let perFrame = sv > 0 ? (vBytesSent - lastVBytesPrev) / max(sv, 1) : 0
    lastVBytesPrev = vBytesSent
    fputs("  video  enc \(sv)/s  dec \(dv)/s  \(String(format: "%.2f", mbps)) Mbps  \(perFrame) B/frame"
        + "  luma \(venc?.lastLuma ?? -1) motion \(venc?.lastDiff ?? -1)"
        + "  encLat \(f(e.p(0.50)))  decLat \(f(dl.p(0.50)))"
        + "  g2g p50 \(f(g.p(0.50))) p95 \(f(g.p(0.95))) ms"
        + "  frags \(vasm.fragsIn) frames-lost \(vasm.missing) partial-drops \(vasm.dropped) decFails \(vdec.decFails) noFmt \(vdec.noFormat)"
        + "  repairKeys \(keyAsksOnLoss) decLuma \(String(format: "%.0f", gDecLuma))"
        + (display != nil ? "  window \(display!.state) shown \(display!.shown) enqFail \(display!.enqueueFails) refresh \(String(format: "%.1f", display!.refreshMs))ms" : "")
        + (mdisplay != nil ? { () -> String in
            let m = mdisplay!
            let cov = m.shown > 0 ? Double(m.present.count) / Double(m.shown) : 0
            // A PERCENTILE OVER A TENTH OF THE FRAMES IS NOT A LATENCY.
            //
            // A two-minute fullscreen run reported "decode->glass p50 3.78 ms"
            // from 402 samples out of 3875 -- the window had gone occluded, so
            // most frames were never presented at all, and the quantile was
            // frozen from the first few seconds. It looked like the best result
            // of the day. Coverage was printed right beside it and I still had
            // to go looking. So now the number withholds itself: below half the
            // frames it prints the coverage instead, because a figure that is
            // present but wrong is read, and a figure that is absent is
            // investigated.
            let body = cov >= 0.5
              ? "decode->glass p50 \(m.present.p(0.50).map { String(format: "%.2f", $0) } ?? "-")"
                + " p95 \(m.present.p(0.95).map { String(format: "%.2f", $0) } ?? "-") ms"
              : "decode->glass WITHHELD (only \(Int(cov * 100))% of frames were presented"
                + "\(m.state == "occluded" ? ", window occluded" : "") -- no number)"
            return "  metal \(m.state) shown \(m.shown) skip \(m.skipped)  \(body)"
                 + " (timed \(m.present.count) of \(m.shown), noTime \(m.presentNoTime))"
          }() : "")
        + "\n", stderr)
  }
  if d.cap == 0 {
    fputs("  no capture: callbacks=\(audio.capCallbacks) renderErrs=\(audio.xruns)"
        + " lastErr=\(audio.lastRenderErr)"
        + (audio.capCallbacks == 0 ? "  -- the input callback is NOT FIRING (device or permission)" : "")
        + "\n", stderr)
  }
}
}

if display != nil || mdisplay != nil {
  Thread { reportLoop() }.start()
  NSApplication.shared.activate(ignoringOtherApps: true)
  NSApplication.shared.run()
} else {
  reportLoop()
}
