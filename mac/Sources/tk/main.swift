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

let VERSION = "0.95.0"

// ── LAUNCH ZERO ─────────────────────────────────────────────────────────────
//
// Declared here, as top-level code in main.swift, because top-level statements
// run in order at process start. A `static let` on a type would be LAZY -- it
// would stamp itself whenever something first asked, which is not launch, and
// every number measured against it would be quietly too small.
let launchT0 = Clock.now()
@inline(__always) func sinceLaunch() -> Int { Int(Clock.msSigned(Clock.now(), launchT0)) }

// ── AN APP THAT WAS DOUBLE-CLICKED HAS NOWHERE TO SAY ANYTHING ───────────────
//
// Every diagnostic this app prints -- which camera, which pixel format, which
// encoder, why a peer was re-found, what the picture quality did -- goes to
// stderr, and a bundle launched from the Dock or by a link has no stderr worth
// having. So the answer to "why was that call bad on the other Mac" was: open a
// terminal, reproduce it, and hope it happens again.
//
// The rule for redirecting is narrow on purpose. A regular file means somebody
// already aimed stderr somewhere (`open --stderr`, a shell redirect) and taking
// that away would break every rig in this repo. A terminal means a person is
// watching it. Anything else -- /dev/null, a closed descriptor, whatever
// LaunchServices hands a double-clicked app -- is nowhere, and nowhere is what
// this replaces.
func teeStderrToLogIfNowhere() {
  if isatty(2) == 1 { return }
  var st = stat()
  if fstat(2, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG { return }
  let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Kin", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let path = dir.appendingPathComponent("kin.log").path
  // Rotated by size, not by date: this is a ring buffer for the last few calls,
  // not an archive, and it must never be the reason a disk fills up.
  if let a = try? FileManager.default.attributesOfItem(atPath: path),
     let size = a[.size] as? Int, size > 4_000_000 {
    try? FileManager.default.removeItem(atPath: dir.appendingPathComponent("kin.1.log").path)
    try? FileManager.default.moveItem(atPath: path,
                                      toPath: dir.appendingPathComponent("kin.1.log").path)
  }
  let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
  guard fd >= 0 else { return }
  dup2(fd, 2)
  if fd != 2 { close(fd) }
  setvbuf(stderr, nil, _IOLBF, 0)
}
teeStderrToLogIfNowhere()

// --version must work, exit 0, and touch no hardware: the updater probes a
// candidate binary with it before allowing it to replace a running one, so this
// is the smoke test that keeps a bad release from bricking the far machine.
if CommandLine.arguments.contains("--version") { print(VERSION); exit(0) }

// ── `--help` HAD TO OPEN A MICROPHONE TO TELL YOU IT DID NOTHING ────────────
//
// It was in KNOWN_FLAGS, so the misspelled-flag guard waved it through, and then
// nothing read it. The result was not an ignored option: with no --room and no
// --peer, tk falls back to listen=7001/peer=127.0.0.1:7002 and STARTS A CALL --
// so the most common first thing anybody types at a new binary turned on their
// microphone and their speakers and printed statistics at them until they found
// Ctrl-C. Registered-but-unread is the same silent-no-op class as a misspelled
// flag, and it is worse here, because the no-op behaviour is live hardware.
//
// So it prints, and it exits, and it touches nothing -- same contract as
// --version, and beside it, so the next person adding a query flag sees both.
// Runs before anything opens a socket or a camera: it is a pure filesystem test
// in a temp directory, and release.sh gates on it.
if flag("selftest-rename") {
  let ok = Update.selftestRename()
  fputs("selftest-rename: \(ok ? "PASS" : "FAIL")\n", stderr)
  exit(ok ? 0 : 1)
}
// Same contract and the same reason: relocateIfHomeless runs once, on someone
// else's Mac, and moves the app the user just downloaded. Pure filesystem work in
// a temp directory, and release.sh gates on it.
if flag("selftest-install") {
  let ok = Install.selftest()
  fputs("selftest-install: \(ok ? "PASS" : "FAIL")\n", stderr)
  exit(ok ? 0 : 1)
}
// Same contract again: pure derivation, no network, no disk write. A handle
// nobody typed is the one part of identity that can be wrong in a way the person
// notices immediately -- being called `deveshs` or `2devesh` -- so the derivation
// is checkable without claiming anything.
if flag("selftest-identity") {
  let ok = Identity.selftest()
  fputs("selftest-identity: \(ok ? "PASS" : "FAIL")\n", stderr)
  exit(ok ? 0 : 1)
}
// Claim synchronously and say what happened, so the ladder can be exercised
// against a real server without launching a call. Unlike the selftests above this
// one DOES touch the network and DOES write identity.json -- point HOME somewhere
// disposable if you do not mean to claim for real.
if flag("claim") {
  Identity.claim()
  fputs("claim: handle=@\(Identity.handle) claimed=\(Identity.claimed)"
      + " key=\(Identity.publicKeyB64.prefix(12))... file=\(Identity.file.path)\n", stderr)
  exit(Identity.claimed ? 0 : 1)
}
// Silent mode from the command line, so the network half can be exercised
// without the sheet in the loop. `--quiet on|off`.
if let want = arg("quiet") {
  guard want == "on" || want == "off" else {
    fputs("--quiet takes on or off, not \(want)\n", stderr); exit(2)
  }
  let ok = Identity.setQuiet(want == "on")
  fputs("quiet: asked \(want), server says \(Identity.quietOn ? "on" : "off")"
      + " agreed=\(ok)\n", stderr)
  exit(ok ? 0 : 1)
}
// Ring somebody and print the room, without a window or a call. The two halves
// of handle-dialling are testable from a terminal before either has any pixels.
if let who = arg("ring-only") {
  let room = Launcher.mintRoom()
  // STAMPED BEFORE THE POST, because the thing being measured is press-to-ring
  // and the POST is inside it. A stamp taken after `ring` returns would hide
  // the caller's whole leg of the trip inside the ruler.
  fputs("ring-only: pressed at \(Int(Date().timeIntervalSince1970 * 1000))\n", stderr)
  if let got = Identity.ring(to: who, room: room) {
    fputs("ring-only: rang @\(who), room \(got)\n", stderr); exit(0)
  }
  exit(1)
}
// The other half of handle-dialling: tell somebody the call is off. Same shape
// as `--ring-only` and for the same reason -- the network half of a feature that
// only exists inside a window is a feature only a window can test, and this one
// has two ends that have to be driven from two terminals.
if let who = arg("bye-only") {
  guard let room = arg("room") else {
    fputs("--bye-only needs --room: a bye is about ONE call, and the room is\n"
        + "  the half of it the other end matches on\n", stderr)
    exit(2)
  }
  fputs("bye-only: pressed at \(Int(Date().timeIntervalSince1970 * 1000))\n", stderr)
  if Identity.ring(to: who, room: room, kind: "bye") != nil {
    fputs("bye-only: told @\(who) the call in \(room) is off\n", stderr); exit(0)
  }
  exit(1)
}
// Drain the mailbox once, or listen for a while. Prints every ring it verifies.
//
// THROUGH THE SAME LOOP THE APP USES. This used to be its own `poll; sleep 2.2`
// while the app ran `startRinging` at 5000 ms, so the number this printed was
// the harness's cadence and not the product's -- a rig measuring a parameter the
// product does not choose. `ringLoop` is now the only listening loop there is.
if flag("rings") || arg("rings-for") != nil {
  let secs = Double(arg("rings-for") ?? "0") ?? 0
  var seen = 0
  // `--stand-down` listens the way the menu-bar resident does: it yields the
  // mailbox whenever the app is open. Exposed here because otherwise the only
  // way to exercise it is to install a real LaunchAgent, and a rule that can
  // only be tested by shipping it is a rule nobody tests.
  Identity.ringLoop(gapMs: Int(arg("ring-gap") ?? "5000") ?? 5000,
                    until: Date().addingTimeInterval(max(secs, 0)),
                    standDown: flag("stand-down")) { r in
    seen += 1
    // The wall clock at the instant the ring reached this process. Subtract the
    // caller's `pressed` stamp above and that difference IS the ring latency.
    fputs("\(r.kind ?? "ring") from @\(r.from) room \(r.room) age \(r.ageMs) ms"
        + " known=\(r.known) keyChanged=\(r.keyChanged)"
        + " at \(Int(Date().timeIntervalSince1970 * 1000))\n", stderr)
  }
  fputs("rings: \(seen) verified\n", stderr)
  exit(seen > 0 ? 0 : 1)
}
// The headless watcher, and the three commands that manage it.
/// Rigs only: never touch the real identity directory. Declared HERE, above
/// the `--watch` block, because `Watch.run` returns `Never` -- read from
/// further down the file this guard is unreachable from the one process that
/// exists to claim a handle, and a watcher rig walked @devesh through
/// @devesh9 against the production directory every time it ran.
let noIdentity = ProcessInfo.processInfo.environment["TK_NO_IDENTITY"] == "1"

if flag("watch") {
  // And it is the one process that never REPORTED anything either, which is
  // why a Mac that stopped calling also stopped being visible at all.
  Update.reportsAsWatcher = true
  // ── THE ONE PROCESS THAT IS ALWAYS RUNNING NEVER LOOKED FOR AN UPDATE ──────
  //
  // `Update.startPolling` is called ~350 lines below this. `Watch.run` returns
  // `Never`. So on every Mac with the login item installed, the process that
  // lives from login to logout has never once asked whether there is a newer
  // Kin -- it only ever REACTED, via `imageStamp()`, to a swap some other copy
  // had already performed. Guard by unreachability again: nothing disabled the
  // updater here, it was simply below a function that does not come back.
  //
  // What that cost, exactly: the foreground app's first check is ten seconds
  // after launch, and closing the window is `exit(0)`. Nothing about a staged
  // update survives the process -- `pending` is memory and `stage()` deletes and
  // re-downloads its temp directory every time. So ten consecutive eight-second
  // sessions make no progress whatsoever, and somebody who is rung, answers,
  // talks and closes the window can stay on an old build for ever. "Open and
  // close it and it updates itself" was not true, and the half of the product
  // that could have made it true was this one.
  //
  // Half an hour, not the foreground app's minute: this process is measured in
  // days, and the thing it is racing is a release, not a call. Sixty seconds
  // before the first ask, because launchd starts it at login alongside
  // everything else a Mac does at login and there is no hurry at all. Both take
  // the same rig overrides as the foreground poller, so a test can prove this in
  // seconds rather than sitting through the production cadence.
  //
  // `callIsLive()` is false in here for ever -- a doorbell holds no media -- so
  // this commits as soon as it has something, which is exactly right for a
  // process with nobody looking at it. Its own `imageStamp()` check then sees
  // the binary move underneath it and exits 3, and launchd starts the new one.
  // That half is already proven in the field; it just never had anything to
  // react to unless the person happened to open the app for long enough.
  if !flag("no-update") {
    // ── HALF AN HOUR IS A LONG TIME TO BE ON THE WRONG BUILD ────────────────
    //
    // 1800 seconds. Measured against a real release: the second Mac in this
    // house was still on 0.82.0 while this one ran 0.84.0, and the report was
    // "the update mechanism is not working". It WAS working -- it was thirty
    // minutes behind, and thirty minutes behind is indistinguishable from broken
    // to the person waiting, especially when two Macs on one call disagree about
    // what the app does.
    //
    // 300 s. The check is a conditional GET of a small JSON manifest against an
    // edge cache: at this cadence it is roughly a megabyte a month, which is not
    // a cost worth thirty minutes of skew. `held-for-call` still defers the
    // INSTALL while somebody is talking, so a shorter poll cannot interrupt a
    // call -- it only shortens the wait before a quiet moment is found.
    let every = max(1, Double(ProcessInfo.processInfo.environment["TK_UPDATE_POLL"] ?? "") ?? 300)
    // ── ON EVERY RESTART ────────────────────────────────────────────────────
    //
    // Was 60 s, on the reasoning that launchd starts this at login alongside
    // everything else a Mac does at login and there is no hurry. True at login,
    // and wrong every other time this process starts: it also restarts after an
    // update, after a crash, and whenever the binary changes underneath it --
    // and in all of those the first question worth asking is whether this Mac
    // is current. This process has no window and no call, so nothing it does
    // can interrupt anybody.
    let first = max(0.5, Double(ProcessInfo.processInfo.environment["TK_UPDATE_GRACE"] ?? "") ?? 2)
    fputs("watch: checking for a newer Kin every \(Int(every)) seconds"
        + " -- this Mac stays current whether or not anybody opens the app\n", stderr)
    Update.startPolling(current: VERSION, every: every, firstAfter: first)
  }
  // ── AND THE PROCESS THAT NEVER STOPS HAD NO WAY TO REPORT ITS OWN DEATH ────
  //
  // Exactly the fault named twenty lines above, in the same block, found the
  // same way: `Watch.run` returns `Never`, so the crash sweep several hundred
  // lines below this is unreachable from here. Nothing switched it off -- it was
  // simply underneath a function that does not come back.
  //
  // This is the process where it matters most. It is the one that lives from
  // login to logout, the one that now fetches and installs a new Kin with nobody
  // watching, and therefore the one where a bad release does its damage
  // invisibly: it would crash, launchd would restart it, and the only symptom
  // anybody would ever see is that their Mac quietly stopped ringing.
  //
  // The telemetry settings have to be applied here too. They live several
  // hundred lines below as well, so `--no-telemetry` was already inert on this
  // path -- a rig watcher would have posted to the production endpoint.
  // And the server config has to be validated here too, for the same reason and
  // it is the same shape of bug: `Watch.run` never comes back, so the check that
  // main.swift does below the unknown-flag guard is unreachable from this path.
  // The watcher is the process that rings, so a `server.json` this build cannot
  // read would make a self-hoster's Mac silently stop receiving calls -- which is
  // indistinguishable from nobody calling.
  for problem in Server.check() { fputs("server: \(problem)\n", stderr) }
  if !Server.check().isEmpty { exit(2) }
  if Server.selfHosted { fputs("server: \(Server.describe())\n", stderr) }
  if flag("no-telemetry") { Telemetry.enabled = false }
  if let e = arg("tel-endpoint") { Telemetry.aimAt(e) }
  if Telemetry.enabled { Thread { Crash.begin() }.start() }
  atexit { Crash.endRun() }
  // A daemon is not quit, it is signalled: launchd sends SIGTERM at logout.
  // Without this, every single logout would file the watcher as a death nobody
  // could explain, and a crash panel full of those is a panel nobody reads.
  // Its own array of sources, declared here rather than reusing the one further
  // down the file -- top-level code runs in order, and a global referenced above
  // its own declaration is one this project has already been caught by.
  nonisolated(unsafe) var watchSignals: [DispatchSourceSignal] = []
  for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    src.setEventHandler { Crash.endRun(); exit(0) }
    src.resume()
    watchSignals.append(src)
  }
  Watch.run(gapMs: Int(arg("ring-gap") ?? "4000") ?? 4000)
}
if flag("watch-install") { fputs(Watch.install() + "\n", stderr); exit(0) }
if flag("watch-remove") { fputs(Watch.uninstall() + "\n", stderr); exit(0) }
if flag("watch-status") { fputs(Watch.status() + "\n", stderr); exit(0) }
// What macOS thinks a running Kin is: `regular` means it has a Dock icon, and a
// RESIDENT with one is a second Kin sitting next to the real app. Read from
// outside the process under test, because the question is what the system
// believes, not what that process last asked for.
if let p = arg("watch-policy") {
  let pid = pid_t(p) ?? -1
  guard let a = NSRunningApplication(processIdentifier: pid) else {
    print("no such running application (\(pid))"); exit(1)
  }
  switch a.activationPolicy {
  case .regular:    print("regular -- HAS A DOCK ICON")
  case .accessory:  print("accessory -- no Dock icon")
  case .prohibited: print("prohibited")
  @unknown default: print("unknown")
  }
  exit(0)
}



if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
  print("""
  tk \(VERSION) -- a video call that tries to be as fast as light allows.

  tk                                   join from the window (asks for a room name)
  tk --room <name> --video camera      join a room with the camera on
  tk --room <name>                     join a room, audio only

    --room <name>      the room to meet in; both sides type the same one
    --video camera     the camera  |  off  audio only  |  <path>  an .mp4, for measuring
    --window           show a window (the app bundle passes this itself)
    --fullscreen       fill the screen
    --mute             do not play audio out (TK_MUTE=1 does the same)
    --no-update        do not check for a newer version
    --version          print the version and exit
    --help             print this and exit

  Your own server, instead of ours -- SELF-HOSTING.md is the walkthrough:

    --server <url>     signalling, updates and invite links, all from your deployment
    --update-key <b64> the Ed25519 public key that signs YOUR releases. Without it
                       Kin installs nothing from your server: it will not run code
                       it cannot check the signature of, and there is no flag for
                       that. Base64 or hex, 32 bytes.
    --save-server      remember those on this Mac, and exit (for a double-clicked app)
    --forget-server    go back to the built-in server, and exit
    --server-print     print which server this copy would use, and exit

  Everything else is a measurement or impairment switch; the source is the reference
  and an unknown option is refused rather than ignored. AGPL-3.0, tokkah.com.
  """)
  exit(0)
}

func arg(_ name: String) -> String? {
  let a = CommandLine.arguments
  guard let i = a.firstIndex(of: "--" + name), i + 1 < a.count else { return nil }
  // A VALUE THAT IS ITSELF A FLAG MEANS THE VALUE WAS FORGOTTEN.
  //
  // `--video --imp-drop 3` reads as video="--imp-drop", which is not "on", so the
  // arm runs with video OFF while being named the video arm. That exact command
  // was just typed, and the run it produced was measuring nothing. The guard
  // below refuses unknown flags; this is the same failure wearing a known one.
  // Fourth instance of this class -- so it dies here rather than being remembered.
  if a[i + 1].hasPrefix("--") {
    fputs("--\(name) needs a value, and got the next flag instead: \(a[i + 1])\n"
        + "an arm running without the thing it is named after is worse than no arm at all.\n",
          stderr)
    exit(2)
  }
  return a[i + 1]
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains("--" + name) }

// ── STDERR, WHEN THERE IS NO TERMINAL TO SEE IT ─────────────────────────────
//
// The camera is the one thing on this Mac that cannot be measured from a shell,
// and the reason is not the signature. TCC attributes a camera request to the
// RESPONSIBLE process, and a binary exec'd by a shell is attributed to whatever
// terminal is at the top of that chain -- so a probe bundle launched that way is
// answered `.denied` however it was signed, `startRunning()` succeeds, the
// session is "up", and not one frame ever arrives. Every camera number measured
// that way is a measurement of the denial path.
//
// `open` fixes the attribution -- LaunchServices makes the app its own
// responsible process, so the bundle's own grant applies -- and `open` gives us
// no stderr at all. So the rig can name a file. Redirected here, before the first
// line is written, and the terminal is told where its output went.
if let logPath = arg("log") {
  let fd = Darwin.open(logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
  if fd >= 0 {
    fputs("log: everything after this goes to \(logPath)\n", stderr)
    dup2(fd, 2)
    Darwin.close(fd)
    fputs("log: tk \(VERSION) pid \(getpid()) -- \(CommandLine.arguments.dropFirst().joined(separator: " "))\n",
          stderr)
  } else {
    fputs("log: cannot write \(logPath) (errno \(errno)) -- keeping stderr\n", stderr)
  }
}

// ── A MISSPELLED FLAG MUST NOT BE A SILENT NO-OP ────────────────────────────
//
// `arg()` looks for "--name" followed by a separate value, so "--echo-sim=18" is
// one unrecognised token and reads as absent. Which means a test arm can run with
// its impairment, its format, or its whole feature switched off, produce a clean
// result, and be labelled as the damaged one. That has happened twice in this
// project -- once through zsh not word-splitting an unquoted variable, and once
// through this exact `=` mistake, where the echo-simulation arm and the control
// arm returned the same number because they WERE the same arm.
//
// The list is maintained by hand on purpose: adding a flag and forgetting to
// register it fails immediately and loudly, which is the cheap direction to fail.
let KNOWN_FLAGS: Set<String> = [
  "acoustic", "audio", "conceal", "devbuf", "display", "dump", "dump-metal",
  "cursor-ahead", "dump-playout", "echo-sim", "fps", "fullscreen", "id", "imp-burst", "imp-delay",
  "selftest-lpc", "no-lp", "gui", "vq-step", "jit-shrink-margin", "vq-hold", "cam-picker-test", "no-vparity", "vq-harm-pct", "shot", "shot-after", "press", "no-telemetry", "tel-endpoint", "vpsnr", "vpsnr-frames", "vquality",
  "imp-drop", "imp-jitter", "imp-spike", "imp-spike-hz", "interp", "jit", "listen",
  "mute", "no-crypt", "no-fec", "no-rt", "no-update", "pcm32", "peer", "room",
  "secret", "stall-out", "starve-pct", "stun", "stunserver", "vbitrate", "video", "vsync",
  "window", "version", "help", "press-after", "selftest-rename", "selftest-install",
  "no-relocate", "leave-exits", "log", "selftest-identity", "handle", "claim", "cam-twopass", "quiet", "prev-call",
  "ring-only", "bye-only", "rings", "rings-for", "ring-gap", "stand-down", "call", "no-rings", "io", "no-agc", "audio-route", "gate-close-ms",
  // `no-ring-preview` was read by main.swift and missing from here, so passing it
  // exited 2 instead of turning the feature off -- a flag whose only effect was
  // to kill the app. Same family as silent-no-op-flags, one worse.
  "no-ring-preview", "incoming-key",
  "watch", "watch-install", "watch-remove", "watch-status", "incoming", "calling",
  "callee-away",
  // A call that outlives its process is on by default and has to be switchable
  // off, because the negative arm of its own rig is "the same crash, and it does
  // NOT come back" -- a rig that cannot run the control is measuring nothing.
  // TK_NO_REJOIN=1 does the same, for a launch with no argv at all.
  "no-rejoin", "resumed",
  "no-vpause", "vpause-after", "vpause-quiet", "vpause-test", "imp-until",
  "no-auto-gain", "gain-debug", "presence", "presence-run",
  "no-gate", "gate-floor", "gate-margin", "gate-test", "force-gate", "gate-coupling",
  "no-corrveto", "floor-soft",
  "ledger-test", "subtitle-test", "sub-over", "sub-floor", "cue-test",
  "no-yield", "yield-db", "yield-after", "yield-test",
  "no-subtitles", "asr-port", "asr", "subtitle-debug", "no-sub-clean", "decimator-test",
  "floor-test", "floor-owd", "no-floor", "floor-debug",
  "turn-test", "turn-owd", "turn-coupling", "turn-wav", "corr-test", "quantile-test", "reopen-test", "gain-test", "echo-state-test",
  "predict-far-test",
  "predict-test", "predict-wav", "predict-seconds", "predict-model", "predict-usecase",
  "predict-budget", "predict-fast",
  "headphone-test", "route", "contacts-fake",
  // Reading what macOS has decided, and opening the exact pane that decides it.
  "permissions", "permissions-open",
  // Running against somebody else's deployment. SELF-HOSTING.md is the walkthrough.
  // `update-key` is registered here rather than being read straight out of the
  // environment for the usual reason: a security control whose flag is a silent
  // no-op is worse than no flag, because it reads as configured.
  "server", "update-key", "save-server", "forget-server", "server-print",
  "watch-policy",
]
// ── A TEST IS NOT A CALL, AND MUST NOT ACT LIKE ONE ─────────────────────────
//
// Every `--*-test` below is pure computation -- a gate, a ledger, a filter, a
// view -- and none of them need a socket, a microphone, a window or the user's
// login item. They were getting all of it anyway, because they sit far down a
// file that has already started an app by the time it reaches them. `tk
// --gate-test` printed
//
//     watch: was stale: points at a different copy ...
//
// which is a unit test INSPECTING THE USER'S REAL LOGIN ITEM. Both agents
// working on ringing had to invent isolation overrides to keep their tests off
// it (`rig-isolation-that-does-not-isolate`), and this is the other half of that
// problem: the tests that were never supposed to be near it.
//
// Not moved -- this file is top-level code and I have been caught by its
// ordering twice today. The side effects are skipped instead, which is the part
// that can actually hurt somebody.
let TEST_FLAGS = ["gate-test", "ledger-test", "cue-test", "yield-test",
                  "subtitle-test", "decimator-test", "headphone-test",
                  "predict-test", "floor-test", "turn-test",
                  "corr-test", "quantile-test", "reopen-test", "gain-test", "echo-state-test",
                  "predict-far-test"]
let isTestRun = CommandLine.arguments.dropFirst().contains { a in
  a.hasPrefix("--") && TEST_FLAGS.contains(String(a.dropFirst(2)))
}
/// ── AND THE SAME FOR A RIG RUNNING A WHOLE CALL ────────────────────────────
///
/// The shell rigs in tools/ drive real calls, so they are not `--*-test` runs and
/// the guard above does not cover them. They still must not claim a handle: since
/// `--no-update` stopped (correctly) disabling the identity claim, every one of
/// them walked @devesh, @deveshp, @devesh2 ... on the REAL server, squatting
/// plausible names a person might want.
///
/// Pinning `--handle` instead was tried and made them FLAKY -- a first claim is
/// 5 to 8 seconds of network, and these scripts time their presses in seconds.
/// Not claiming at all is both correct and free. Sibling of TK_KIN_DIR and
/// TK_UPDATE_POLL; production never sets it.

for a in CommandLine.arguments.dropFirst() where a.hasPrefix("--") {
  let name = String(a.dropFirst(2))
  if KNOWN_FLAGS.contains(name) { continue }
  // Name a likely intent rather than just refusing: "--echo-sim=18" and
  // "--echosim" are the two mistakes actually made.
  let bare = name.split(separator: "=").first.map(String.init) ?? name
  var hint = ""
  if KNOWN_FLAGS.contains(bare) {
    hint = " -- values are separate words here: --\(bare) <value>"
  } else if let near = KNOWN_FLAGS.first(where: { $0.replacingOccurrences(of: "-", with: "") == bare.replacingOccurrences(of: "-", with: "") }) {
    hint = " -- did you mean --\(near)?"
  }
  fputs("unknown option \(a)\(hint)\n"
      + "a misspelled flag would otherwise be ignored in silence, and an arm running"
      + " without the thing it is named after is worse than no arm at all.\n", stderr)
  exit(2)
}

if let io = arg("io") {
  guard io == "vp" || io == "hal" else {
    fputs("--io takes vp or hal, not \(io)\n", stderr); exit(2)
  }
  Audio.ioKind = io
  Audio.ioPinned = true
}

// ── THE ROUTE DECIDES, BECAUSE THE ROUTE IS WHAT MAKES THE ECHO ─────────────
//
// `hal` was the default for every call this app has ever made, and the comment
// above `ioKind` says exactly what that costs: the duplex gate "only ever acts
// while the near end is NOT speaking", so "echo during double talk is not
// solved by this and is the honest gap."
//
// The field closed that gap the hard way. Over 23 reported calls, `aec_on` was
// 0 on every single one and `output_route` was `speakers` on every single one:
// nobody was ever wearing headphones, so the acoustic path from speaker to mic
// was open on both ends of every call ever made, with no canceller behind it.
// What that sounds like to the person on the call is "ear deafening" echo.
//
// So it is not a taste question and it is not one default for everybody. On
// HEADPHONES there is no path from the speaker to the microphone, the gap does
// not exist, and pure HAL is right -- nothing between the mic and the wire.
// On SPEAKERS the path exists and cannot be wished away, so use the canceller
// Apple ships and FaceTime uses. The cost is latency and a little of the "on a
// call" colour; the alternative is a call nobody can hold.
//
// Read here, before the units are built, because the buffer size is a device
// property and the unit type cannot change underneath a running engine.
// `--io hal` still pins the old behaviour, and `--io vp` pins the new one.
// ── AND THE ANSWER TO THE ECHO IS NOT A CANCELLER ──────────────────────────
//
// This briefly chose VoiceProcessingIO whenever the sound left into a room.
// That does remove the echo, and it costs a measured +7.61 ms plus Apple's
// noise suppression and automatic gain -- "the sound of being on a call rather
// than in a room", which is the thing this app exists not to be.
//
// The decision is half duplex instead: the gate mutes whoever is not speaking
// outright (see `floorDb`), and whoever IS speaking is heard raw, through the
// plain hardware path, with nothing between the microphone and the wire. The
// green edge and the subtitles are what make that work -- they say whose turn
// it is, so a quiet moment reads as "they are listening" rather than "it broke".
//
// `--io vp` is still here and still does the whole VPIO path, so the two are
// A/B-able on a real call rather than argued about.
if !Audio.ioPinned {
  let (name, speakers) = Audio.outputDevice()
  Audio.ioKind = "hal"
  fputs("audio: out is \(name) -- \(speakers ? "speakers" : "headphones")"
      + ", raw mic, one at a time\n", stderr)
}
Metrics.fact("io_reason", Audio.ioPinned ? "pinned" : "route")

// ── WHAT THE AUDIO WOULD DO, WITHOUT DOING IT ──────────────────────────────
//
// Every other way to find out which IO path a call will take was to START a
// call: with no --room this app joins a loopback peer and opens the microphone,
// which is not a thing to do on somebody's Mac to answer a question. Reads the
// route, prints the decision and the reason, exits. No mic, no peer, no sound.
if flag("audio-route") {
  let (name, speakers) = Audio.outputDevice()
  // ── READ THE DECISION, DO NOT RECOMPUTE IT ────────────────────────────────
  //
  // This said `Audio.ioPinned ? Audio.ioKind : (speakers ? "vp" : "hal")` -- its
  // own copy of the rule, next to the block that actually makes it. When the
  // default changed from VoiceProcessingIO to the plain path, calls changed and
  // this did not: the tool built to verify which path a call takes reported the
  // OPPOSITE of what the app would do, on a machine already running the new
  // build. Two places answering one question is how `reach()` and `status()`
  // disagreed for twenty hours, in this same codebase.
  //
  // `Audio.ioKind` is the value the audio engine reads. So this reads it.
  let kind = Audio.ioKind
  fputs("output: \(name)\n", stderr)
  fputs("route:  \(speakers ? "speakers -- sound leaves into the room" : "headphones -- no path back to the mic")\n", stderr)
  fputs("io:     \(kind)\(Audio.ioPinned ? " (pinned by --io)" : " (the default)")\n", stderr)
  let how = kind == "vp"
    ? "cancelled by VoiceProcessingIO"
    : "one at a time -- the non-speaker's mic is muted, floor "
      + "\(Int(Audio.gate.floorDb)) dB reached in \(Int(Audio.gate.closeMs)) ms"
  fputs("echo:   \(how)\n", stderr)
  exit(0)
}

// ── WHICH SERVER THIS COPY TALKS TO ────────────────────────────────────────
//
// Below the unknown-flag guard, so `--sever` is refused rather than ignored, and
// above everything that opens a device, a socket, a window or the identity --
// the same placement, for the same reason, as `--permissions`.
//
// The exit matters more than it looks. `--server kin.example.com`, with the
// scheme forgotten, makes every `URL(string:)` in Stun, Turn, Telemetry and
// Update return nil, and every one of those is a `return nil` that is
// indistinguishable from a network that is simply down. Without this, a typo
// would present as an outage -- an app that starts, connects to nothing, and
// says nothing about why. So it is a sentence, at startup, and exit 2.
let serverProblems = Server.check()
if !serverProblems.isEmpty {
  for p in serverProblems { fputs("server: \(p)\n", stderr) }
  fputs("refusing to start against a server address this build cannot use.\n", stderr)
  exit(2)
}
// A switch that changes where the app sends everything must not be silent. Gated
// on `selfHosted` rather than on "differs from the default" on purpose: every rig
// in mac/tools sets TK_KIN_BASE or TK_UPDATE_BASE, and none of them needs a new
// line in a log some other script is reading.
if Server.selfHosted { fputs("server: \(Server.describe())\n", stderr) }
// Same contract as --version: print, exit, touch nothing. This is also the
// command that proves the default is still the default -- see SELF-HOSTING.md.
if flag("server-print") { print(Server.report()); exit(0) }
if flag("save-server") { fputs(Server.save() + "\n", stderr); exit(0) }
if flag("forget-server") { fputs(Server.forget() + "\n", stderr); exit(0) }

// ── A SENTINEL PID MUST NEVER SATISFY AN IS-IT-RUNNING CHECK ───────────────
//
// `Watch.Resident.Target.live` decides whether a Dock click is answered by
// bringing an open Kin forward or by starting one, and 0.76.0 answered six
// clicks in a row with "already open (pid -1)" -- activating a record with no
// process behind it, so nothing came up at all. Up here with the other pure
// arithmetic and above the media socket: this is a table of pids, and it needs
// no port, no device and no window.
if flag("reopen-test") { exit(Resident.Target.selfTestLive() ? 0 : 1) }

// ── A MICROPHONE FIVE TIMES TOO HOT, AND A LOOP THAT GAVE UP ON IT ─────────
//
// Driven with the peaks a real call delivered. Pure arithmetic over one struct:
// no device, no port, no window, so it sits up here with the other rulers.
if flag("gain-test") { exit(Audio.gainSelfTest() ? 0 : 1) }

// The state the floor forgot: nobody's turn, both loudspeakers live, both
// microphones open. Pure arithmetic over two Floor objects.
if flag("echo-state-test") { exit(Floor.echoStateSelfTest() ? 0 : 1) }
if flag("predict-far-test") { exit(Floor.predictFarSelfTest() ? 0 : 1) }

// ── ARE YOU TWO IN THE SAME ROOM? THE RULER, BEFORE ANY OF THE PRODUCT ─────
//
// Up here with `--permissions` and NOT down with the other `--*-test` blocks,
// which was the first place it went. `TEST_FLAGS` excuses a test from the
// updater, the identity claim and the login item -- but the media socket is
// bound at `Wire(listen:)` far above all of them, so every `--*-test` in this
// file still takes a UDP port. Measured while writing this: `tk --sameroom-test`
// spent 30 seconds retrying port 7001 against another agent's process and then
// exited 1, having computed nothing. This is pure arithmetic over a synthetic
// buffer; it needs no port, no device and no window.

// ── WHAT MACOS HAS DECIDED, AND THE ONE CLICK THAT CHANGES IT ──────────────
//
// Below the unknown-flag guard so a misspelling is refused rather than ignored,
// and above everything that opens a device, a socket, a window or the identity:
// asking what the permissions are must not itself be a call. Same reason the
// `--*-test` flags had to be excused from the app's side effects -- a diagnostic
// that starts the product cannot be used to diagnose the product.
//
// `tk --permissions` prints and exits. `tk --permissions-open camera` is the
// second token, and it is here because of this codebase's own law about controls
// that are declared and never wired: an API with no caller reads as finished and
// does nothing, and `reveal` is exactly the shape of thing that rots unnoticed.
// This makes it runnable by hand on any machine in one line.
if flag("permissions") || arg("permissions-open") != nil {
  if let which = arg("permissions-open") {
    guard let need = Permissions.Need(rawValue: which) else {
      fputs("--permissions-open takes one of: "
          + Permissions.Need.allCases.map(\.rawValue).joined(separator: ", ") + "\n", stderr)
      exit(2)
    }
    // The only path in this program that throws a System Settings window at
    // whoever is sitting here, which is why the automated rig never takes it.
    let opened = Permissions.reveal(need)
    fputs(Permissions.report() + "\n", stderr)
    exit(opened ? 0 : 1)
  }
  fputs(Permissions.report() + "\n", stderr)
  exit(0)
}

// ── WHAT `--video` ACCEPTS, SAID OUT LOUD ──────────────────────────────────
//
// The source used to be `videoArg == "camera" ? CameraSource() : FileSource(path:
// videoArg)`, so EVERY other string was a filename. The launcher passed `--video
// on` -- the obvious thing to write and the obvious thing to mean -- and it became
// a hunt for a file called "on", which failed. So the double-clicked app never
// once had a camera, and it never asked for a window either: a person opening
// Tokkah.app got a name prompt and then an invisible process. Not a video calling
// app, and the one defect a user notices before any amount of latency.
//
// Resolved HERE, beside the unknown-flag guard, because it used to be checked
// after the peer rendezvous -- so a typo waited for someone to answer before
// admitting it was a typo.
func resolveVideoArg() -> String {
  let v = arg("video") ?? "off"
  if v == "off" || v == "camera" { return v }
  if v == "on" || v == "cam" { return "camera" }
  if FileManager.default.fileExists(atPath: v) { return v }
  fputs("--video \(v): not \"camera\", not \"off\", and not a file that exists.\n"
      + "  --video camera   the built-in camera\n"
      + "  --video off      audio only\n"
      + "  --video <path>   an .mp4/.mov file, for measuring things\n"
      + "(a path containing spaces needs quoting)\n", stderr)
  exit(2)
}
let videoArg = resolveVideoArg()

// ── THIS IMAGE WAS LAUNCHED TO ASK, NOT TO TALK ──────────────────────────────
//
// `--incoming` is set and nobody has answered yet, so there is no call here: no
// room, no socket, no microphone and no camera. See the waiting block further
// down, and `tools/preanswer-check.sh`.
//
// Declared HERE, beside `videoArg`, and not next to the block it guards. Top-level
// statements run in file order, and the first thing that has to ask this question
// is the camera bring-up several hundred lines above that block -- which is
// exactly how the first version of this fix still turned the camera on. The rig
// could not see it either, because the rig passed `--video off` while the watcher
// passes `--video camera`: a parameter the harness hardcoded and the product
// chooses at runtime.
let ringPending = arg("incoming") != nil

// ── THE CALL IN FLIGHT, DECLARED WHERE NOTHING CAN READ IT FIRST ────────────
//
// Both of these are written by the poll thread and read by the ring handlers, so
// where the DECLARATION sits is the whole safety argument -- see
// `top-level-code-runs-in-order`, which this file has been bitten by twice. Top
// level `var`s in main.swift are initialised in file order, so one declared below
// `startRingingOnce()` is a variable a live poll thread can write to and then
// have its own initialiser silently undo a few microseconds later. Nothing above
// this line touches them; everything that does is far below it.
//
// gOffered: a ring reaches this process either from the in-app poll or, when Kin
// was closed, from the watcher via argv. `onAnswerRing` reads exactly one
// variable, because an answer path that only understands one of the two routes is
// a button that works or does nothing depending on how the call arrived -- and
// the watcher route is precisely the one nobody would test by hand.
nonisolated(unsafe) var gOffered: Identity.Ring?
// gCalling: WHO AND WHICH ROOM, not just who. A bye is matched on both, and the
// room is the half a stranger cannot guess -- it was minted for this call minutes
// ago and only the two ends have ever seen it.
nonisolated(unsafe) var gCalling: (who: String, room: String)?

// ── Double-clicked from the Finder? Ask where to call, then be a normal call ──
//
// After flag validation, so a typo is still refused, and before anything touches
// the microphone, the camera or a socket -- the window has to finish first.
// The URL handler goes in before anything can wait on it, and before the join
// window, since a link can arrive either side of it.
// ── BE SOMEWHERE INSTALLABLE BEFORE DOING ANYTHING ELSE ──────────────────────
//
// FIRST, and the position is the whole point. This started three lines above the
// update check, which reads as early enough and is not: with no --room, the app
// prompts for a room name and then Launcher.reexec's ITSELF, so a double-clicked
// copy would have shown its window, taken the user's room, and re-exec'd -- all
// from the read-only DMG -- before this line was ever reached. The relocation has
// to precede the URL handler, the room prompt, and the re-exec, because every one
// of them is something the wrong copy would otherwise do first.
//
// Also necessarily ahead of the update check (a translocated mount cannot be
// written, so every update would fail to stage and retry forever) and ahead of any
// audio or camera device, so the user's one permission prompt is not spent on a
// bundle that is about to move -- macOS ties those grants to the signature at the
// path that asked.
Install.relocateIfHomeless()

Launcher.installURLHandler()

// ── WERE WE IN A CALL WHEN THIS MAC LAST SAW US? ────────────────────────────
//
// Before the mint below, because the answer changes what "opening Kin" means. If
// there is a call nobody hung up on, opening the app is not starting a call, it
// is WALKING BACK INTO one -- no room to type, no link to click, no ring, no
// decision. That is the whole of what was asked for: "even if one side closes the
// app, they should hop into the call as soon as they start the app again".
//
// Below the URL handler and above the mint, so the precedence reads in the order
// a person would expect it: a link they just clicked wins over a call they were
// already in, and both win over a fresh room.
//
// Placed here, at the same point in the file as the mint, because both end in
// `Launcher.reexec` -- the room has to be in argv before the twenty places that
// read `arg("room")`, and re-execing is the move this file already makes for
// exactly that reason. It costs one `execv` (~15 ms, measured on this path
// already for the gui prompt) and it reuses a path that is proven rather than
// inventing a second way for a room to arrive.
//
// NOT for `--incoming` or `--calling`: both of those arrive WITH a room in argv,
// so the guard below already excludes them. A ring is about a different call than
// the one that was held, and answering it should not be ambiguous.
//
// ── AND NOT WHEN THE COMMAND LINE NAMES A DIFFERENT JOB ─────────────────────
//
// The guard above is "no room and no peer", which is true of `tk --stun`, `tk
// --gate-test` and `tk --call meera` as well as of a double-click. Without this
// list, a held call would turn a unit test into a re-exec INTO somebody's
// conversation, and pressing "call Meera" would rejoin the old call instead of
// placing the new one. Every entry is a mode that reaches its own behaviour below
// this line; the ones that exit above it (`--version`, `--rings`, `--watch`,
// every `--selftest-*`) need no mention. The list fails towards NOT rejoining,
// which is the cheap direction: the worst case is a person opening Kin and
// pressing nothing.
let namesAnotherJob = isTestRun || flag("stun") || flag("acoustic")
  || arg("call") != nil || arg("shot") != nil
  || flag("cam-picker-test") || flag("vpause-test") || flag("presence-run")
if arg("room") == nil, arg("peer") == nil, !flag("gui"), !flag("no-rejoin"),
   !namesAnotherJob,
   ProcessInfo.processInfo.environment["TK_NO_REJOIN"] != "1",
   let live = Resume.pending() {
  let bundled = (Bundle.main.executableURL?.path ?? CommandLine.arguments[0])
    .contains("/Contents/MacOS/")
  Launcher.remember(live.room)
  Launcher.reexec(room: live.room, extra: Resume.argv(live, bundled: bundled), why: "rejoin")
}

// ── A DOUBLE-CLICK STARTS A CALL ────────────────────────────────────────────
//
// No prompt, no lobby, no decision: the app opens, the camera comes on, and a
// freshly minted `xxx-xxxx-xxx` room is live with its link in the middle of the
// window. Exactly the web app, which is the flow that was asked for.
//
// A link that arrived via `tokkah://` wins over a fresh mint, because somebody
// clicking an invite is trying to reach a specific call and not to start one.
if arg("room") == nil, arg("peer") == nil, !flag("gui"),
   (Bundle.main.executableURL?.path ?? CommandLine.arguments[0]).contains("/Contents/MacOS/") {
  // WAIT for the link, do not merely check for it: the Apple Event carrying the
  // room is dispatched by the runloop, so a read taken here without turning it is
  // guaranteed nil and every invite became a freshly minted room instead.
  //
  // 0.25 and not 0.7: awaitURLRoom now also returns the instant the LAUNCH event
  // arrives, so this is the backstop for a launch that delivers neither event, not
  // the price of every double-click. Measured AE delivery was 27 ms.
  let room = Launcher.awaitURLRoom(within: 0.25) ?? Launcher.mintRoom()
  Launcher.remember(room)
  Launcher.reexec(room: room, extra: ["--video", "camera", "--window"], why: "gui prompt")
}

// `--gui` still opens the join window, for typing a name on purpose.
if Launcher.shouldPrompt(hasRoom: arg("room") != nil,
                         hasPeer: arg("peer") != nil,
                         forced: flag("gui")) {
  guard let room = Launcher.askRoom() else { exit(0) }   // closed the window
  // Video on by default here and off for the command line: someone who typed
  // `tk` is measuring something, someone who double-clicked wants a video call.
  // A WINDOW, TOO. Without `--window` nothing ever creates one, so the app that
  // was just double-clicked showed a name prompt and then vanished into the dock
  // while running a perfectly good audio call nobody could see. A video calling
  // app that opens no video is the one bug a user notices before any latency.
  Launcher.reexec(room: room, extra: ["--video", "camera", "--window"], why: "gui prompt")
}

// ── A LINK CLICKED WHILE A CALL IS ALREADY UP ────────────────────────────────
//
// The launch path reads the URL mailbox exactly once, and this process is long
// past it: it IS the re-exec'd call. So a second invite -- someone sends a link
// while the app sits in a room -- set `Launcher.urlRoom` and was read by nobody,
// which looked to the user like clicking the link did nothing at all.
//
// Re-exec into the new room, the same move the launch path makes. execv keeps the
// pid, the dock icon and the permission grants, and the only fd that would
// collide is the UDP socket, which carries FD_CLOEXEC for precisely this reason
// (Net.swift) -- the self-updater already re-execs mid-run through this same
// needle. The dedup in `reexec` drops the stale `--room` inherited from argv, so
// the new image sees one room and it is this one.
//
// INSTALLED HERE, not down by `NSApplication.run()`, and the position is the
// whole point: the rendezvous wait above the media loop pumps AppKit events
// itself, so a link clicked while the window says "waiting for the other
// person" is dispatched hundreds of lines before run() is ever called. That is
// exactly when a second invite arrives, and with the hook installed later it
// fell into the mailbox nobody reads -- measured: `url: joining fix-warm-three`
// with no switch behind it.
Launcher.onURLRoom = { r in
  guard r != arg("room") else { return }   // the link we are already in
  DispatchQueue.main.async {
    fputs("url: switching to \(r)\n", stderr)
    Launcher.remember(r)
    Launcher.reexec(room: r, extra: ["--video", "camera", "--window"], why: "url")
  }
}

// ── A TEST RUN MUST NOT COMPETE FOR A FIXED PORT ────────────────────────────
//
// `TEST_FLAGS` excuses a `--*-test` run from the updater, the identity claim and
// the login item, and the media socket is bound BELOW all of that -- so every one
// of them still took UDP 7001. Measured while the same-room work was being built:
// `tk --sameroom-test` spent thirty seconds retrying 7001 against another agent's
// process and then exited 1, having computed nothing. Seven of these blocks sit
// hundreds of lines under the bind and cannot be lifted above it without moving
// code this file has already punished people for moving (see `TEST_FLAGS`).
//
// So the PORT moves instead of the code. Zero means "any free one", the socket is
// still real, every path below is unchanged, and two tests can run at once. An
// explicit `--listen` still wins, because a rig that names a port means it.
//
// Measured with a live call holding 7001, which is what the collision actually
// is -- two short `--*-test` runs do NOT collide with each other, so the obvious
// control proves nothing and I ran the wrong one first:
//
//   tk --gate-test --listen 7001   ->  exit 1, "socket/bind failed on port 7001"
//   tk --gate-test                 ->  exit 0, GATE TEST PASSED
let listenPort = UInt16(arg("listen") ?? "") ?? (isTestRun ? 0 : 7001)
let peerSpec = arg("peer") ?? "127.0.0.1:7002"
let parts = peerSpec.split(separator: ":")
guard parts.count == 2, let pPort = UInt16(parts[1]) else {
  fputs("bad --peer, want host:port\n", stderr); exit(2)
}
let peerHost = String(parts[0])

fputs("tk \(VERSION)  listen=\(listenPort) peer=\(peerHost):\(pPort) timebase=\(Clock.timebaseDescription)\n", stderr)
// pid and argv on the banner: this process re-execs itself on several paths, so
// a log with four banners in it is either four launches or one process changing
// its mind four times, and those call for opposite fixes.
fputs("pid \(getpid()) argv: \(CommandLine.arguments.dropFirst().joined(separator: " "))\n", stderr)
fputs("packet=\(FPP) frames (\(String(format: "%.2f", Double(FPP) / SR * 1000)) ms)  ring=\(RING) pkts\n", stderr)

// ── NOTHING ON THE LAUNCH PATH TALKS TO THE UPDATE SERVER ────────────────────
//
// "On launch the check is synchronous and cheap" was the comment here, and the
// check was two sequential BLOCKING HTTPS GETs with a 12 s timeout each, on the
// main thread, BEFORE the window was created: 1155 ms of nothing, measured, on
// every launch. A/B: window at 2036 ms by default against 881 ms with
// --no-update. The claim was never tested; the word "cheap" was doing the work.
//
// The poller below is a strict superset -- same available(), same stage(), and it
// commits the instant nothing is live -- so nothing is lost by deleting the
// launch check outright. Its `firstAfter` grace is what preserves "you get today's
// build today". --no-update is for bisecting a regression, nothing else.
//
// GRACE, NAMED, AND NOT SMALL: callIsLive() is false for the whole of call setup,
// so a short first tick re-execs while the user is reading their invite link.
let UPDATE_FIRST_CHECK_GRACE = 10.0
if !flag("no-update"), !isTestRun {
  // A held update has to be visible or it is just a stall. The poller lands it by
  // itself the moment the call ends, so this is a notice and not a demand -- there
  // is a "Restart to update" item in the menu for anyone who would rather not wait.
  // ASSIGNED BEFORE startPolling: the poller can fire this on its first tick.
  Update.onPending = { v in
    DispatchQueue.main.async {
      display?.controls?.setStatus("update \(v) ready — restarts when the call ends")
    }
  }
  // And if we are already current but our BUNDLE is not -- an old updater took the
  // binary and left the icon behind -- fix that too, once, quietly.
  //
  // ON ITS OWN THREAD, because "free on a healthy install" is only true when it
  // does not fire: when it DOES it is 2 GETs plus a tarball download at
  // timeout:120, and it was doing all of that on the main thread ahead of the
  // window -- the same bug as the deleted check above, a hundred times worse, just
  // rarer. Not the poller's thread: the poller's half-second cadence is what lands
  // a pending update the moment a call ends, and a tarball download would stall it.
  Thread { Update.repairBundleIfStale(current: VERSION) }.start()
  // Rig override, sibling of TK_UPDATE_BASE: a test that proves the poller in
  // seconds must not sit through the production minute. Floor at 1 s so a typo
  // cannot turn the poller into a busy loop against the real server.
  let pollEvery = max(1, Double(ProcessInfo.processInfo.environment["TK_UPDATE_POLL"] ?? "") ?? 60)
  // The grace gets a rig override of its own, for the same reason: a 10 s wait is
  // right for a person and wrong for a test that has to prove the first tick.
  let firstAfter = max(0.5, Double(ProcessInfo.processInfo.environment["TK_UPDATE_GRACE"] ?? "")
                            ?? UPDATE_FIRST_CHECK_GRACE)
  Update.startPolling(current: VERSION, every: pollEvery, firstAfter: firstAfter)
  // ── ON EVERY OPEN ────────────────────────────────────────────────────────
  //
  // The grace above used to be the whole answer to "when does an open check?",
  // and it answered it with a ten-second wait. It is now only the fallback
  // cadence; the check itself happens at once. The ten seconds moved to the
  // COMMIT (`Update.armSettle`), which is what they were always protecting: a
  // window that re-execs while somebody is still reading their invite link.
  Update.armSettle(UPDATE_FIRST_CHECK_GRACE)
  Update.checkNow("Kin opened")
}

// ── THESE ARE NOT PART OF UPDATING, AND THEY USED TO BE ───────────────────────
//
// `Identity.start()` and the login-item install sat INSIDE `if !flag("no-update")`
// above. Nothing about claiming a handle or being reachable at login has anything
// to do with checking for a new build -- they were in there because that is where
// the `Thread { }` block already existed.
//
// The cost was silent and total: `--no-update` is documented one line above as
// "for bisecting a regression, nothing else", every rig script in this project
// passes it, and so EVERY test run had no handle at all. `handle=-` in the
// control audit, for months, while the ringing and contacts work was being
// written against it. `silent-no-op-flags`, and the same shape as the gate flag
// that put the whole turn-taking layer behind a pair of headphones: one condition
// answering two unrelated questions.
//
// A handle nobody asked for, claimed on a thread nobody waits for. If this never
// completes the app is exactly as usable as it was before handles existed, which
// is the only acceptable cost for a convenience.
if !isTestRun, !noIdentity { Identity.start() }
// Being callable is the point of having a handle, so an installed copy makes
// itself reachable rather than waiting to be told. Only from /Applications
// (Watch.install refuses anything else), only when absent or stale, and never on
// a rig build -- --no-relocate marks a copy that is not somebody's install.
if !flag("no-relocate"), !isTestRun, !noIdentity {
  Thread {
    // Recorded whichever way it goes. "Can this Mac be rung while Kin is closed"
    // is the single fact behind the whole doorbell, and until now the only trace
    // of the answer was a line in stderr on somebody else's machine.
    let r = Watch.reach()
    Metrics.fact("reachable_closed", r.on ? "yes" : "no")
    if !r.on { Metrics.fact("reachable_why", r.says) }
    guard !Watch.healthy() else { Metrics.count("watch_present"); return }
    // Say WHY it is being rewritten. "installed" on a Mac that already had a
    // login item reads as a bug until you know the old one pointed at a copy
    // that a self-update had replaced.
    // "absent" and "unreadable" are different findings, and staleReason cannot
    // tell them apart -- a file that is not there does not read either.
    let was = !Watch.installed ? "absent"
            : (Watch.staleReason().map { "stale: \($0)" } ?? "present but not loaded")
    let said = Watch.install()
    Metrics.count(said.contains("installed") ? "watch_installed" : "watch_install_fail")
    fputs("watch: was \(was) -- \(said)\n", stderr)
  }.start()
}

guard let wire = Wire(listen: listenPort, peerHost: peerHost, peerPort: pPort) else {
  fputs("socket/bind failed on port \(listenPort)\n", stderr); exit(1)
}

// ── A REJOIN ALREADY KNOWS WHERE THEY WERE ──────────────────────────────────
//
// The socket itself cannot survive what this feature has to survive -- a crash
// takes the file descriptor with the process, and no amount of care about
// FD_CLOEXEC changes that. The ADDRESS survives, and the address is most of what
// the socket was worth: the far end has been sending to us the whole time, so its
// NAT binding is still open and one datagram to that address is a working path
// with no discovery in it at all.
//
// So a resumed image starts aimed at where the call was, and races that address
// alongside whatever the rendezvous turns up. On a healthy network the directory
// answers first and this changes nothing; when the directory is slow, or still
// serving a stale entry, this is the only thing that works -- and it costs one
// file read and two assignments.
//
// AIMED, NOT TRUSTED. It goes in as a candidate like every other, so if the peer
// really has moved, the race settles on wherever they answer from and this
// address is simply one that never replied. The one thing it must not do is
// pre-empt the race, which is why `setPeer` here is the same provisional
// destination the rendezvous sets a moment later and not a lock.
if flag("resumed"), let p = Resume.rememberedPath() {
  wire.setPeer(ip: p.ip, port: p.port)
  wire.addCandidate(ip: p.ip, port: p.port)
  fputs("rejoin: aiming at \(p.ip):\(p.port), where the call was\n", stderr)
}

// TELEMETRY SETTINGS BEFORE ANYTHING CAN POST. These two lines used to sit next
// to the audio engine, several hundred lines and one rendezvous later -- so a
// person who ran with --no-telemetry and then left while still waiting for the
// other side posted a beat anyway, to the production endpoint, because the line
// that would have switched it off had not been reached yet. Same ordering fault
// as the crash above it: the window can act before the setup below it exists.
if flag("no-telemetry") { Telemetry.enabled = false; fputs("telemetry: off\n", stderr) }
// One control, both routes. Setting only `endpoint` would have left a rig's
// crash reports going to the production server while its beats went to a local
// sink -- one flag answering one question, unlike the two this project has
// already been bitten by.
if let e = arg("tel-endpoint") { Telemetry.aimAt(e) }

// ── WHAT HAPPENED THE LAST TIME THIS APP STOPPED ─────────────────────────────
//
// Every crash on somebody else's Mac has been invisible until now: the window
// goes away, they open it again, and the .ips file macOS wrote is in a folder
// they will never look in. That was survivable while a release only reached
// whoever ran the curl line by hand -- and it stopped being survivable when the
// always-on watcher started updating itself unattended, because a release that
// crashes now spreads to every Mac with nobody watching it happen.
//
// On its own thread and on every launch, like the login-item check above it. The
// main thread pays for one `Thread` and nothing else: the common case is a
// machine that has not crashed, and the common case reads no files at all. See
// Crash.swift for how it stays that cheap, and for why it never asks what the
// process was called.
//
// ── AND NOT ON A TEST RUN ──────────────────────────────────────────────────
//
// `isTestRun` already excuses `--*-test` from the updater, the identity claim,
// the login item and the media port, for one reason: a unit test must not touch
// the machine it is measured on. This was the hole left in that -- every
// `tk --gate-test` opened the crash ledger in the user's Application Support,
// read the machine's DiagnosticReports, and could post to the PRODUCTION
// telemetry endpoint. `--no-telemetry` was the only thing standing in front of
// it, which makes staying off production the caller's job to remember, and a
// safety property that depends on a second flag is one that is off by default.
if Telemetry.enabled, !isTestRun { Thread { Crash.begin() }.start() }
// EVERY ORDINARY ENDING CLOSES THE BOOKS, not just the ones that file a beat.
// `postFinalBeat` covers Leave, Ctrl-C, SIGTERM and a re-exec; this covers the
// rest of the `exit()` calls in this file -- a bind that failed, a rendezvous
// nobody joined, a self test that finished -- and it is exactly the right
// primitive, because the things that do NOT run an atexit handler are precisely
// the things that should be reported: a signal death, an abort, a SIGKILL.
atexit { Crash.endRun() }
// ── AN IMAGE THAT IS ABOUT TO BE REPLACED FILES ITS REPORT FIRST ─────────────
//
// And hands its call id to its successor. The id is random per PROCESS, so a
// ring answered in four seconds was two rows on the dashboard with nothing
// joining them -- the first row missing entirely, because it never lived long
// enough to send a beat at all. Now the first row exists, says why it ended, and
// the second one names it.
Launcher.beforeReexec = {
  postFinalBeat(why: "re-exec")
  return ["--prev-call", Telemetry.call]
}
// ── AND THE UPDATER'S OWN RE-EXEC, WHICH NEVER HAD ONE ───────────────────────
//
// `Update.commit` calls execv directly and so filed nothing on the way out: an
// update looked, on the dashboard, exactly like a call that stopped. Now that a
// call SURVIVES the restart, the record has to say so or it reads as a call that
// ended and a different one that began -- which this project has been fooled by
// before, in the other direction, with a `final` beat followed by later `live`
// ones.
//
// So the shape is: the outgoing image files a FINAL beat whose `ended` names the
// restart rather than an ending anybody chose, and the successor carries
// `--prev-call`, which the beat sends as `prev_call`. A row that says
// `ended: update-restart` and is named by the next row's `prev_call` is one call
// across an update; nothing else in the schema had to change.
//
// `--resumed` rides along too, so the new image aims at the address the call was
// on before its rendezvous has said anything -- see the block below `wire`.
Update.beforeRestart = {
  postFinalBeat(why: "update-restart")
  return ["--prev-call", Telemetry.call, "--resumed"]
}

// ── ASK FOR THE MICROPHONE HERE, WHERE THE PROCESS IS STILL ALIVE ────────────
//
// The request used to live several hundred lines below, under the room block --
// and the room block calls `exit(1)` when nobody else arrives inside two minutes.
// So on a solo launch the process died before the microphone was ever asked for.
// tccd proved it: kTCCServiceMicrophone sat at `Unknown (None)` after every
// launch, with no prompt ever recorded, while Camera read `Allowed (User
// Consent)` because it is asked early. The first person to actually get a call
// therefore met the permission dialog in the middle of a conversation.
//
// Two properties matter, and they are the two the camera path already has:
//
//   EARLY -- above the rendezvous, above `--stun`'s exit, above every other exit
//   in this file, so no failure to find a peer can outrun the question.
//   ASYNC -- the answer arrives on a callback and nothing waits for it. The old
//   code blocked the main thread on a semaphore for up to 60 seconds with no
//   runloop turning, which is a frozen window in the one moment the app most
//   needs to look alive. The system draws the dialog, not us; we only need to not
//   be dead when the answer comes back.
//
// It runs on EVERY launch, solo included, so the grant is settled before there is
// a call to interrupt. Already-decided is free: `authorizationStatus` short
// circuits and no dialog appears.
/// 1 granted, 0 denied, -1 still unanswered. Reported, because "they heard
/// silence" and "the microphone was never allowed" are the same symptom.
nonisolated(unsafe) var gMicAccess = -1
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
  gMicAccess = 1
  fputs("mic: already granted\n", stderr)
case .notDetermined:
  fputs("mic: asking for permission (look for a dialog)\n", stderr)
  AVCaptureDevice.requestAccess(for: .audio) { ok in
    gMicAccess = ok ? 1 : 0
    Metrics.count(ok ? "mic_granted" : "mic_denied")
    Metrics.fact("mic_access", ok ? "granted" : "denied")
    fputs(ok ? "mic: granted\n"
             : "mic: denied -- they will hear silence from this end."
             + " System Settings > Privacy & Security > Microphone\n", stderr)
  }
case .denied, .restricted:
  gMicAccess = 0
  fputs("mic: denied -- they will hear silence from this end."
      + " System Settings > Privacy & Security > Microphone\n", stderr)
@unknown default:
  break
}

// ── WHAT YOU SEND SOMEONE TO GET THEM INTO THE CALL ─────────────────────────
//
// There was nothing. The web app had a link you could paste to a person; this had
// a room name you had to tell them out loud and an install command they had to be
// told about separately. So the invite is both, as text, because the two ends of a
// native call are two installed apps and a bare URL cannot install one.
//
// The URL is a real page -- the invite funnel at /join, which the worker rewrite
// serves -- that names the room and either deep-links `tokkah://join/<room>`
// straight into the app or offers the download, so the person who receives this
// can act on it whether or not they already have the app.
/// THE LINK IS THE INVITE. `roomUrl()` in the web app is one line -- the short
/// path form for a minted code -- and the clipboard, the waiting screen and the
/// address bar all read it from the same place so they cannot disagree. Same here:
/// one function, and what you copy is exactly what is on screen.
// The invite link is the product's face: it is what gets pasted, read aloud and
// typed wrong. `kin.tokkah.com` is three letters of host before the dot, and both
// it and `room.tokkah.com` are the same worker -- so every link already sent to
// anybody keeps working, which is the only rule a link shortener has to obey.
func roomURL(_ room: String) -> String {
  // Two shapes, and only one of them works per room. `app.js` has had this right
  // the whole time -- `MEET_RE.test(room) ? origin/room : origin/?r=room` -- and
  // this copy used the short path for everything, so any NAMED room (`--room
  // standup`) produced a link that 404s. Minted rooms are 3-4-3 and were fine,
  // which is why every test of the normal flow passed over it.
  let minted = room.count == 12 && room.split(separator: "-").map(\.count) == [3, 4, 3]
    && room.allSatisfy { $0 == "-" || ("a"..."z").contains(String($0)) }
  guard minted else {
    // Hyphens survive: `?r=team%2Dstandup` is valid and unreadable, and this string
    // is meant to be read by a person before it is followed by a browser.
    var ok = CharacterSet.alphanumerics; ok.insert(charactersIn: "-_")
    let esc = room.addingPercentEncoding(withAllowedCharacters: ok) ?? room
    return "\(Server.invite)/?r=\(esc)"
  }
  return "\(Server.invite)/\(room)"
}
func inviteText(room: String) -> String { roomURL(room) }

/// False until every global `audioBeat` reads has been created. Declared here,
/// ahead of the window, because the controls that can call the beat exist from
/// the moment the window is drawn and this flag has to be readable before its own
/// initialiser has run -- a Bool reads false out of zeroed memory, an object
/// reference reads as a null pointer, which is the whole bug.
nonisolated(unsafe) var beatReady = false

/// Leave means leave: report the call's last numbers, then go. Same path as the
/// signal handler, because a person clicking Leave and a person pressing Ctrl-C
/// want exactly the same thing and the record should not be able to tell them
/// apart.
/// Post this process's last numbers and WAIT briefly for the post to land.
///
/// Shared by Leave and by every re-exec, because they are the same event as far
/// as the record is concerned: this process is about to stop existing. `why`
/// rides along so the dashboard can tell a hang-up from an image that handed the
/// call to its successor -- otherwise every answered ring looks like a call that
/// ended after four seconds.
@discardableResult
func postFinalBeat(why: String) -> Bool {
  // FIRST, and above the telemetry guard: this is the one place Leave, Ctrl-C,
  // SIGTERM and a re-exec all pass through, and a re-exec is the case an atexit
  // handler cannot cover -- `execv` replaces the image without unwinding
  // anything. Without this line every answered ring would have been reported as
  // an app that died without saying goodbye.
  Crash.endRun()
  guard Telemetry.enabled else { return false }
  // Last second's percentiles, not a live sort of the audio-thread buffer.
  var beat = audioBeat(uptime: Double(beatTick),
                       up: lastRates.up, down: lastRates.down,
                       played: lastRates.played, concealed: lastRates.concealed,
                       cap: lastRates.cap,
                       p50: lastM2e.p50, p95: lastM2e.p95, p99: lastM2e.p99)
  beat["ended"] = why
  let done = DispatchSemaphore(value: 0)
  let before = Telemetry.sent
  Telemetry.post(beat, final: true) { _ in done.signal() }
  // A report is not worth hanging a quit on: the person clicked Leave because
  // they wanted out, so 1.5 s and go regardless. Said out loud either way,
  // because a beat believed-sent and never sent is the worse of the two.
  let inTime = done.wait(timeout: .now() + 1.5) == .success
  let ok = inTime && Telemetry.sent > before
  fputs("final beat (\(why)): \(ok ? "sent" : "NOT SENT (\(Telemetry.lastError))")"
      + " uptime \(beatTick)s\n", stderr)
  return ok
}

// ── HANGING UP IS THE ONLY THING THAT ENDS A CALL ────────────────────────────
//
// Everything else -- a crash, a force-quit, an update's `execv`, a lid closing --
// leaves the call open and the record on disk, and the next launch walks straight
// back in (Resume.swift). This is the one path that says it is over, so it has
// two jobs beyond exiting: tell the other end, and delete the record.
//
// The goodbye goes out FIRST and synchronously. It is four UDP datagrams on a
// socket that is already open and already pointed at them -- microseconds -- and
// it has to leave before `exit(0)`, because after that there is no process to
// send it. `execv-discards-unsent-analytics` is the same lesson with a different
// payload: an ending has to finish its business while it still exists.
/// ── HANGING UP ENDS THE CALL. IT DOES NOT CLOSE KIN. ──────────────────────
///
/// Reported in as many words: "the app gets closed when I disconnect the call,
/// which should not be happening. Only the call should get disconnected."
///
/// It was `exit(0)`, from back when a call and a process were the same thing.
/// Closing the window already stopped meaning "hang up" (`closeWindowKeepingCall`
/// above); this is the other half of that same correction, and it was left
/// behind: the button that ends a call was still ending the app.
///
/// What stays on screen afterwards is the screen Kin opens with -- a fresh room,
/// waiting, with its link -- because that IS this app's idle state. There is no
/// lobby to go back to: a double-click starts a call.
///
/// Done by re-exec rather than by tearing the call down in place. Every other
/// change of room in this app goes through `Launcher.reexec` (a placed call, an
/// answered ring, a followed link, a rejoin) and that path is proven; unwinding
/// the sockets, the audio graph and the resume record in-process would be a
/// second way to do it, and the second way is the one that is never tested.
/// `--calling` and `--incoming` are already dropped on the way through, so the
/// new image cannot re-ring anybody.
///
/// `--leave-exits` keeps the old behaviour for the rigs that measure a departure
/// by watching a process end, and a plain CLI run keeps it too: `tk --room x`
/// from a terminal is not somebody's app, and re-arming it into a fresh room
/// would leave a stray call running after a test.
func leaveCall() -> Never {
  shuttingDown = true
  // Guarded the same way `hangUpAndExit` is, and for the same reason: leaving
  // while still waiting for somebody has nobody to tell, and a goodbye sent to a
  // ring that has not been answered would quit the caller's app instead of
  // showing them a card.
  if Resume.holding { wire.sendGoodbye() }
  Resume.end(why: "left")
  postFinalBeat(why: "leave")
  let bundled = (Bundle.main.executableURL?.path ?? CommandLine.arguments[0])
    .contains("/Contents/MacOS/")
  if bundled, !flag("leave-exits") {
    fputs("left the call -- Kin stays open\n", stderr)
    Launcher.reexec(room: Launcher.mintRoom(),
                    extra: ["--video", "camera", "--window"], why: "hung up")
  }
  fputs("left the call\n", stderr)
  exit(0)
}

/// ── CLOSING THE WINDOW IS NOT HANGING UP ──────────────────────────────────
///
/// The red button used to be wired straight to `leaveCall`, which was right when
/// a call could not survive its process. It is not right now, and the user said
/// so in as many words: "even if one side closes the app, they should hop into
/// the call as soon as they start the app again, unless they have disconnected
/// the call."
///
/// So closing the window puts the app away and leaves the call open: no goodbye,
/// the record stays, the far end holds, and opening Kin again walks back in. The
/// hang-up control in the bar is what ends a call, and it is the only thing that
/// does. This still stops the camera and the microphone with the process, which
/// is the privacy property `WindowCloser` was written for.
///
/// The final beat says `closed`, not `leave`, so the two are separable on the
/// dashboard -- a call that was put away and resumed must not read as a call that
/// ended, and a row whose successor names it as `prev_call` is how that reads.
func closeWindowKeepingCall() -> Never {
  shuttingDown = true
  let held = Resume.holding
  postFinalBeat(why: held ? "closed-holding" : "closed")
  fputs(held ? "window closed -- the call stays open; reopening Kin rejoins it\n"
             : "window closed\n", stderr)
  exit(0)
}

/// One shot, whichever thread arrives first. Two racing paths that both end the
/// process would otherwise file two final beats and exit twice.
final class Latch: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  func claim() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if fired { return false }
    fired = true
    return true
  }
}

// ── TELLING THEM IT IS OVER ─────────────────────────────────────────────────
//
// The complaint, in the words it was reported in: cancel a call and the other
// Mac "just kept showing calling forever". It was true, and there was nothing
// wrong with it -- there was simply no un-ring to send. A ring sat in a mailbox
// with a 60 s lease and both ends waited it out.
//
// A bye is the same signed envelope with `kind: "bye"` on it. It travels the
// same route, wakes the same held poll, and is dropped unread by any client too
// old to know the word -- see `ringMessage`, which signs a different domain for
// exactly that reason. Off the main thread always: this is an HTTPS round trip
// and the caller of this is usually the thread that draws.
func sendBye(to who: String, room: String, why: String, then done: (() -> Void)? = nil) {
  guard !who.isEmpty, !room.isEmpty else {
    fputs("bye (\(why)): nobody to tell\n", stderr)
    done?()
    return
  }
  Metrics.count("bye_sent_try")
  Thread {
    let ok = Identity.ring(to: who, room: room, kind: "bye") != nil
    Metrics.count(ok ? "bye_sent_ok" : "bye_sent_fail")
    // Said out loud either way. A message believed-sent and never sent is the
    // worse of the two, and the failure is invisible from this end otherwise.
    fputs("bye (\(why)): @\(who) \(ok ? "told" : "NOT told -- they wait out the timeout")\n",
          stderr)
    done?()
  }.start()
}

/// Tell them, then go. The window goes NOW and the process follows when the
/// message is out or after `capMs`, whichever is first -- a quit hung on
/// somebody else's network is a hang, and the person pressed the button to be
/// gone. `why` is also the ending recorded on the final beat, so cancelled and
/// declined are separable in the analytics from an ordinary leave.
func hangUpAndExit(to who: String, room: String, why: String, capMs: Int = 2000) {
  Metrics.fact("outcome", why)
  Metrics.mark("\(why)_ms", sinceLaunch())
  let once = Latch()
  // Straight away, and before anything that can block. Everything after this
  // point is the message going out; there is no reason to make somebody look at
  // a window for it.
  display?.callWindow?.orderOut(nil)
  func go(_ note: String) {
    guard once.claim() else { return }
    if !note.isEmpty { fputs(note, stderr) }
    shuttingDown = true
    // ── ONLY IF THERE WAS A CALL ────────────────────────────────────────────
    //
    // Cancelled and declined are a person saying no, and the far end has to be
    // told -- but it is told through the MAILBOX (`sendBye` above), which draws a
    // "can't talk right now" card and leaves their app open. The in-band goodbye
    // ends the far end's process outright, which is right for a hang-up and wrong
    // for a decline: it would quit the caller's app instead of telling them.
    //
    // `Resume.holding` is exactly the difference. It is set at the transport lock
    // and skipped for a ring preview, so a ring that was never answered has no
    // record and sends nothing here -- while a call that got as far as media
    // sends the goodbye, which is the case the mailbox cannot serve at all
    // because a link invite has no handles to address.
    if Resume.holding { wire.sendGoodbye() }
    Resume.end(why: why)
    postFinalBeat(why: why)
    exit(0)
  }
  sendBye(to: who, room: room, why: why) { go("") }
  DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(capMs)) {
    go("bye: gave the message \(capMs) ms and left anyway\n")
  }
}

// ── A WINDOW AND A PICTURE BEFORE THERE IS ANYONE TO CALL ────────────────────
//
// All of this used to happen AFTER the rendezvous, so double-clicking Tokkah.app
// produced a name prompt and then nothing at all: no window, no camera light, no
// sign the program was alive, for as long as it took the other person to join --
// up to two minutes, and forever if they never did. Every latency number in this
// file was irrelevant next to that, because the app did not look like it worked.
//
// So the window opens first, the camera starts first, and you watch yourself while
// you wait. The title carries the state, because a window that shows a picture and
// says nothing is indistinguishable from a call that has already connected.
// Whether anything has been decoded from the far end yet. Switches the window from
// self-view to the other person, and is the only thing that makes those two paths
// mutually exclusive.
nonisolated(unsafe) var sawRemote = false
/// ── THEY ARE HERE, WHICH IS NOT THE SAME AS "I CAN SEE THEM" ────────────────
///
/// `sawRemote` means their first video frame decoded, and the whole presence
/// system used to key off it: the waiting card, the status pill, the call timer,
/// and the departure detector. So somebody who joined with their camera off was,
/// to this app, somebody who never arrived. Measured on a real call: 59,574 audio
/// frames played, the session encrypted, their turn cue drawing on screen -- and
/// the window still showing "Waiting for the other person..." with the invite
/// link over the top of it, for the entire call.
///
/// Turning your camera off is an ordinary thing to do. `one-condition-two-concerns`:
/// "is the other person on this call" and "do I have their picture" are different
/// questions, and the second one was answering both.
nonisolated(unsafe) var peerHere = false
/// ── AND THIS END HAS NO PICTURE TO SEND ─────────────────────────────────────
///
/// `--video off`, or a camera that refused to open. From the OTHER end this is
/// indistinguishable from a camera somebody switched off with the button, and
/// "their camera is off" is the true, plain-words description of both -- so it
/// is advertised as exactly that. Without it the far end sits looking at a
/// connected call with no picture and nothing saying why, which is the same
/// silence this whole change is about.
///
/// INITIALISED HERE, not assigned earlier. It was set from `videoArg` up at the
/// argument parsing, three hundred lines above this declaration -- and main.swift
/// is TOP-LEVEL CODE, so the declaration's own initialiser runs later and put the
/// `false` straight back. The flag was set, then unset, by two lines that both
/// looked right, and the far end went on seeing nothing with no explanation.
nonisolated(unsafe) var noCameraHere = videoArg == "off"
/// Whether the doorbell's poll thread is up. Declared HERE, not beside the
/// function that sets it: `Identity.onClaimed` can fire while the claim's network
/// round trips are still finishing, which is before that line of top-level code
/// has run -- and main.swift is top-level code, so a variable declared later has
/// not been initialised yet. That exact trap cost an hour today one flag over
/// (see `noCameraHere` above).
nonisolated(unsafe) var ringingStarted = false
/// Ticks of the presence loop since the transport locked, or -1 before it has.
/// Used to give a healthy call time to deliver its first frame before the window
/// is blanked. See the note beside `clearPicture` in the presence thread.
nonisolated(unsafe) var sinceLock = -1
/// Whether the other person is silent RIGHT NOW while the call is being held
/// open for them. Distinct from `peerHere`, which stays true across a hold on
/// purpose -- the call has not ended and nothing should tear down. This is the
/// narrower question every READOUT has to ask: is there a person on the far end
/// to describe? Set where the hold is announced, cleared when they come back and
/// when the room lease finally decides they are gone.
nonisolated(unsafe) var peerHeld = false
nonisolated(unsafe) var pictureCleared = false
/// A LOCK AND NOT THE MAIN THREAD. The obvious way to make `startRingingOnce`
/// single-entry is to hop it onto main -- and that was written, and it never ran:
/// without `--window` there is no pumped run loop, so the block sat on the main
/// queue for the whole call and the doorbell stayed off. A latch that depends on
/// a run loop existing is a latch that is only correct in the windowed build.
let ringStartLock = NSLock()
/// Set from the control bar's camera button.
nonisolated(unsafe) var camOff = false
/// ── THE LINK SAID NO, SO NOTHING LEAVES ──────────────────────────────────────
///
/// Written once a second by the reporter, read at the camera's frame rate by the
/// capture thread. A plain Bool, deliberately: the capture callback must not take
/// a lock, and the worst a torn read could do is send or skip one frame during
/// the single tick when it changes -- which is 33 ms of an event that lasts
/// seconds. `camOff` above is the same shape for the same reason.
nonisolated(unsafe) var gVideoPaused = false

/// The window's title is the only status this app has. Set from whatever thread
/// notices the state changed, hopped to main because AppKit requires it.
func setWindowTitle(_ t: String) {
  DispatchQueue.main.async { NSApplication.shared.windows.forEach { $0.title = t } }
}
var display: Display?
var mdisplay: MetalDisplay?
// --display metal draws the frame by hand so that (a) the time it actually
// reaches the panel can be READ from Metal instead of inferred from a refresh
// rate, and (b) --vsync 0 can skip the compositor's synchronised pass. Default
// stays the AVSampleBufferDisplayLayer path until the measurement says otherwise.
let displayKind = arg("display") ?? "avsbdl"

// ── THE SENSOR IS THE SLOWEST THING, SO IT STARTS FIRST ─────────────────────
//
// `startRunning()` returning is not a picture, and until this file measured the
// FIRST FRAME nothing here knew the difference. Measured from a signed bundle
// with a real grant, launched through LaunchServices, with every stage named:
//
//   exec -> our first statement        17-21 ms   (dyld; ~470 ms once, right
//                                                  after the bundle is re-signed)
//   -> camera bring-up starts          14 ms      (this block, before AppKit)
//   -> device found                    48-82 ms
//   -> sensor opened                   20-25 ms
//   -> format negotiated               1-3 ms
//   -> startRunning() returns          24-32 ms
//   -> FIRST FRAME                     640-650 ms cold  /  283-294 ms warm
//
// ── "COLD" AND "WARM" ARE NOT ABOUT HOW LONG THE CAMERA HAS BEEN IDLE ────────
//
// This comment used to say "807 ms on the first launch after the camera has been
// idle a while", which put the reader onto a cool-down curve that does not exist.
// Swept directly (n=2 each at 2/10/30/60/120 s idle): dead flat, 769-792 ms at
// every one of them. Swept again below two seconds: 409-445 ms at gaps of
// 0.15-1.8 s and 770-790 ms at 2.0 s and above, with the step landing between
// 1.8 and 2.0 s and repeating on both sides. It is a latch, not a curve -- the
// camera assistant keeps the sensor powered for about 1.9 s after the last client
// lets go, and after that the next open pays a full 350 ms power-up.
//
// Two consequences worth stating because they are not obvious:
//   * The re-exec paths (placing a call, answering a ring) already land inside
//     that window and already get the warm number -- 429 ms, measured on a real
//     answered ring. Nothing needs doing there.
//   * A cold launch cannot be brought under 500 ms from here. 640 ms of the
//     ~780 ms is the sensor, everything this program owns adds up to ~120 ms, and
//     two attempts at that 120 ms (resolving the device by remembered id instead
//     of a discovery session; skipping the format negotiation entirely) both
//     measured exactly zero, n=5 each, arms rotated. See Video.swift.
//
// What it CAN do is stop making the sensor wait its turn. Everything below --
// NSApplication, the window, the control bar, `makeKeyAndOrderFront` -- is ~95 ms
// during which nothing has asked the camera for anything. Asked here instead, the
// bring-up begins at 14 ms rather than ~110, and the window is built while the
// sensor warms up: first frame 511 -> 464 ms, and the window itself lands SOONER
// (256 -> 192 ms) because the camera is no longer on the thread that draws it.
//
// ONLY on the already-authorized path, and that restriction is the point: on a
// first run the system draws a modal permission dialog, and it must appear over
// a window rather than over nothing. That was the whole reason the explicit
// request exists (Launcher.swift) -- an unanswered prompt shows black forever
// with no explanation, and it happened. So first runs keep the old order exactly,
// and every run after the first gets the head start.
var earlyCam: FrameSource?

/// The self-view sink and the picker, for a camera whose bring-up is in flight.
/// One function, called from the early path and the late one, so the two cannot
/// drift into showing different pictures or different camera lists.
func attachCamera(_ cam: CameraSource) {
  cam.onFrame = { pb, _ in
    // Self-view. Replaced the moment a decoded frame from the far end arrives:
    // vdec.onDecoded shows the remote picture, and this stops once `sawRemote` is
    // set so the two are never fighting over the same surface.
    // Once they are on screen you move to the corner rather than disappearing.
    // Display owns the routing entirely: the window before anyone arrives, the peek
    // tile while the button is held, nowhere otherwise. Two call sites deciding this
    // independently is exactly how they end up disagreeing.
    display?.showSelf(pb)
    if !sawRemote && !peerHere { mdisplay?.show(pb, at: Clock.now()) }
  }
  cam.startOffMain { err in
    if let err {
      // Not fatal. A call with no camera is still a call, and saying so beats a
      // blank window with no explanation.
      fputs("preview: unavailable (\(err)) -- continuing without a picture\n", stderr)
      noCameraHere = true
      setWindowTitle("Kin — no camera; waiting for the other person")
      // Cleared so the reuse below the rendezvous builds a fresh source instead of
      // adopting a dead session -- which is also how a camera plugged in after
      // launch still gets picked up. The join loop pumps the main queue on every
      // poll, so this is always drained before that line is read.
      DispatchQueue.main.async { earlyCam = nil }
      return
    }
    fputs("preview: \(cam.describe) on screen before the call connects"
        + " (session up at \(sinceLaunch()) ms)\n", stderr)
    // Discovery is a device call, so it stays off main with the rest of the
    // bring-up; only the two AppKit lines hop, with the answers already in hand.
    let devs = CameraSource.available()
    let names = devs.map { $0.localizedName }
    let mine = devs.firstIndex { $0.uniqueID == cam.current?.uniqueID } ?? 0
    DispatchQueue.main.async {
      // `--cam-picker-test` owns the picker when it is on: its placeholder list is
      // the thing under test, and the real one-camera list would erase it.
      guard (arg("cam-picker-test").flatMap { Int($0) } ?? 0) <= 1 else { return }
      display?.controls?.setCameras(names, current: mine)
      display?.controls?.onCamPick = { i in
        // `switchTo` does its own work on the session queue, so the click returns
        // immediately and the window never freezes on a camera swap.
        let list = CameraSource.available()
        guard i >= 0, i < list.count else { return }
        cam.switchTo(list[i])
      }
    }
  }
}

// `!ringPending`: no green light next to somebody who is only being asked.
if videoArg == "camera", flag("window"), !ringPending,
   AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
  fputs("camera: already granted at \(sinceLaunch()) ms -- starting it before the window\n", stderr)
  let cam = CameraSource()
  earlyCam = cam
  attachCamera(cam)
}

if flag("window") {
  // NSApplication FIRST. AppKit will build an NSWindow before the application
  // object exists and simply never show it -- decode ran at 31 fps into a window
  // that was not on screen, which looks like a display bug and is an ordering
  // bug. Touching .shared here is what creates it.
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  if displayKind == "metal" {
    if let m = MetalDisplay(vsyncOff: arg("vsync") == "0", fullscreen: flag("fullscreen")) {
      m.open(title: "Kin — waiting for the other person", w: 1280, h: 720)
      mdisplay = m
      fputs("display: metal, vsync \(m.vsyncOff ? "OFF (tearing allowed)" : "on")"
          + "\(m.fullscreen ? ", fullscreen" : ""), refresh \(String(format: "%.2f", m.refreshMs)) ms\n", stderr)
    } else {
      fputs("display: metal unavailable, falling back\n", stderr)
    }
  }
  if mdisplay == nil {
    let d = Display()
    let roomName = arg("room") ?? "direct"
    d.open(title: "Kin — waiting for the other person", w: 1280, h: 720,
           room: roomName,
           onMic: { m in
             gMicMuted = m
             fputs("mic \(m ? "muted" : "live")\n", stderr)
             d.controls?.setStatus(m ? "you are muted"
                                     : ((sawRemote || peerHere) ? "connected" : "waiting for the other person"))
           },
           onCam: { off in
             camOff = off
             fputs("camera \(off ? "off" : "on")\n", stderr)
           },
           onLeave: { leaveCall() },
           // The red button and Command-Q put Kin away. They do not hang up: a
           // call outlives its process now, so reopening walks straight back in.
           onClose: { closeWindowKeepingCall() },
           invite: inviteText(room: roomName))
    display = d
    // ── COMING BACK MUST NOT LOOK LIKE STARTING ────────────────────────────────
    //
    // A rejoining image opens the same window every launch does, so for the
    // second before the transport locks it says "waiting for the other person"
    // and shows the invite link -- which is the screen for a call that has not
    // begun, put in front of somebody who was mid-conversation ten seconds ago.
    // One string, and the difference between "it crashed and I have to start
    // again" and "it is coming back".
    if flag("resumed") {
      d.controls?.setStatus("rejoining\u{2026}")
      setWindowTitle("Kin \u{2014} rejoining")
      Metrics.fact("resumed", "yes")
      Metrics.mark("resumed_ms", sinceLaunch())
    }
    // ── WHEN CAN THE LINK ACTUALLY BE COPIED ──────────────────────────────────
    //
    // Not when `inviteText` is assigned. That happens inside `open()` above, on a
    // main thread that then walks straight into the camera and does not return to
    // the runloop -- so the card holds the URL, draws it, and every click on it
    // sits in the queue unhandled. "Present" and "clickable" are two different
    // times and only the second one is the product.
    //
    // A main-queue block is the honest marker precisely because it is dispatched
    // through the same queue a click is: it cannot run until main is back in the
    // runloop, which is the first instant a press on `copy` could be serviced.
    // The URL is already set before this is queued, so the block firing means
    // both halves are true at once.
    let urlAtOpen = d.controls?.inviteText ?? ""
    DispatchQueue.main.async {
      Metrics.mark("link_copyable_ms", sinceLaunch())
      fputs("link: copyable at \(sinceLaunch()) ms"
          + " (\(urlAtOpen.isEmpty ? "NO URL SET" : urlAtOpen))\n", stderr)
    }
  }
}


// ── SOMEBODY CLICKED KIN WHILE THIS ONE WAS ALREADY OPEN ────────────────────
//
// The resident answers every Dock click, Finder double-click and Spotlight hit
// for this bundle, and when Kin is already open the right answer is to bring
// THIS window forward. It could not: `Launcher.reexec` is an `execv`, and after
// one, LaunchServices' record for this process reads `pid -1` forever --
// `activate` on it returns true and does nothing. The person saw a click that
// did nothing, and then, once -1 was read as "not running", a new Kin on every
// click.
//
// So the raise is done from the inside, where no LaunchServices handle is
// needed. SIGWINCH because a resident that has just updated itself routinely
// faces an OLD Kin with no handler for this, and SIGWINCH is the one signal
// whose default action is to do nothing: an older copy ignores it. SIGUSR1
// would have HUNG UP on whoever was on the call.
//
// ── AND IT IS INSTALLED HERE, NEXT TO THE WINDOW ───────────────────────────
//
// It was first written at the foot of this file, beside the SIGINT handler, and
// it never ran once: a call with a window does not reach the end of main.swift,
// it blocks in the rendezvous long before. The debug line that proved it printed
// nothing at all, which is the same evidence a handler that runs and does
// nothing would leave -- so it is installed at the point where the window it
// raises is known to exist.
//
// `.main` queue, because everything it touches is AppKit.
nonisolated(unsafe) var raiseSource: DispatchSourceSignal?
if display != nil || mdisplay != nil {
  signal(SIGWINCH, SIG_IGN)
  let r = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
  r.setEventHandler {
    fputs("raise: asked to come forward\n", stderr)
    NSApplication.shared.activate(ignoringOtherApps: true)
    // `orderFrontRegardless` and not `makeKeyAndOrderFront`: this window may be
    // behind a full-screen app on another Space, and that is exactly the case
    // somebody is clicking the Dock icon to get out of.
    (mdisplay?.callWindow ?? display?.callWindow)?.orderFrontRegardless()
  }
  r.resume()
  raiseSource = r
  fputs("raise: ready -- a Dock click on an open Kin brings this window forward\n", stderr)
}

// The camera, started before there is anywhere to send it, so the preview is live
// while waiting. The encoder attaches to this same instance later -- one camera,
// opened once, so the permission prompt happens once and at the moment the person
// is actually looking at the app.
// Any source, not just the camera: a file source takes the identical path, which
// is the only way this feature can be verified without a person present to click
// Allow on a camera prompt. An instrument that cannot see the thing it tests
// reports the same value as a real failure.
// --shot <path> [--shot-after <s>]: photograph this window's controls and exit.
// The app's own camera on itself, so verifying a UI change never requires
// capturing the whole screen -- and armed HERE, before the rendezvous, because
// the interesting state is "waiting for the other person" and the code after the
// rendezvous never runs when nobody comes.
// One place that knows what a press means, called by both --press-after and the
// --shot path, so the two can never drift into pressing different things.
func pressControl(_ name: String) {
  display?.controls?.nudgeBar()
  // `selfview` is the one control that does not live on the bar: it is a Display
  // property, and it normally flips when the other side's first frame lands.
  // Reaching the connected layout otherwise needs two machines, which is a slow
  // way to check that a corner is in the corner.
  if name == "selfview" {
    sawRemote = true
    display?.selfViewOn = true
    display?.controls?.markConnected()
    display?.controls?.setStatus("connected")
    // The window title too, or every screenshot taken this way says "waiting for
    // the other side" over a connected call -- an instrument that lies quietly
    // about the state it was built to record.
    setWindowTitle("Kin — connected")
    fputs("pressed selfview: corner on\n", stderr)
    return
  }
  // ── PUTTING THE SPEAKER BACK ────────────────────────────────────────────────
  //
  // The room detector turns this Mac's speaker off by itself, so there has to be
  // one thing that turns it back on, and the decision has to STICK -- an
  // automatic action that re-applies itself over a choice somebody just made is
  // worse than not having the action at all. `audio` is a global created after
  // the rendezvous and touching it before that traps, so it is reached through a
  // hook that is nil until it exists.
  display?.controls?.simulate(name)
  // Read the CONTROL's state, not `audio`'s. `audio` is a global created after the
  // rendezvous, and touching it from a timer that fires while still waiting traps
  // on an uninitialised global -- a shape that has killed this process silently
  // three times.
  let c = display?.controls
  fputs("pressed \(name): micMuted=\(c?.micMuted ?? false) camOff=\(c?.camOff ?? false)"
      + " clipboard=\(NSPasteboard.general.string(forType: .string)?.count ?? 0) chars\n", stderr)
}

// ── --press-after: PRESS, AND KEEP RUNNING ──────────────────────────────────
//
// `--shot` photographs the layer tree, and the layer tree does not contain the
// picture -- the window server composites the video, so the app cannot see it.
// The capture that CAN see it is `screencapture -l <window id>`, and that has to
// happen while the app is still alive. So the presses get their own timer,
// separate from the shot that used to exit immediately after them.
if let seq = arg("press"), let afterS = arg("press-after"), let after = Double(afterS) {
  // A `~` token is a 3 s pause, so a PRESS-AND-HOLD can be photographed while held
  // and then released in the same run: `--press "peek,~,unpeek"`. Without it a hold
  // and its release were two separate runs, and "the tile went away" could never be
  // shown to be caused by the release.
  // `@name` is a REAL CLICK -- a synthetic NSEvent at the control's own centre,
  // routed through `window.sendEvent` and therefore through every `hitTest` on the
  // way down. `?` runs the hit-test audit over everything currently on screen.
  // Both exist because a handler call cannot fail the way a finger fails.
  var t = after
  // ── A PRESS THAT FIRES LATE IS NOT A PRESS THAT WORKED ──────────────────────
  //
  // `asyncAfter` computes its deadline HERE, but the block runs only when main is
  // back in the runloop. So a press armed for 500 ms that executes at 1440 ms is
  // reporting a control that a person would have clicked and watched do nothing
  // for most of a second -- and the log line, printed at execution, looked
  // identical to a press that was serviced instantly. Measured: exactly that,
  // 940 ms of queueing behind a synchronous camera open.
  //
  // So each press states when it was DUE and how long it waited. A late press is
  // now a number in the log rather than an absence in it.
  let armedAt = sinceLaunch()
  for name in seq.split(separator: ",") {
    let token = String(name)
    if token == "~" { t += 3.0; continue }
    let at = t
    let dueAt = armedAt + Int(at * 1000)
    // Every token gets its own moment. They used to share one, so a nine-step
    // sequence fired nine handlers inside the same runloop turn and the log read
    // like one instant -- which is exactly the evidence a step-by-step test is for.
    t += 0.7
    DispatchQueue.main.asyncAfter(deadline: .now() + at) {
      let ran = sinceLaunch()
      fputs("press \(token): due at \(dueAt) ms, ran at \(ran) ms"
          + " -- queued \(ran - dueAt) ms\n", stderr)
      if token == "?" {
        for line in display?.controls?.auditClicks() ?? ["no controls"] {
          fputs("audit \(line)\n", stderr)
        }
        // ── AND WHAT EVERY SURFACE IS MADE OF ─────────────────────────────────
        //
        // A material cannot be audited by hit-testing it and cannot be judged from
        // the app's own snapshot -- the layer tree does not contain the blur. But
        // the ANSWER each surface gave when it was built is a fact the process
        // knows, and for months nobody asked it: `Glass.swift`'s header described a
        // policy that nine of the ten surfaces did not implement. So they say it
        // now, and `tools/glass-check.sh` holds them to it.
        for line in Glass.describeAll() { fputs("glass \(line)\n", stderr) }
        fputs("audit state \(display?.controls?.describeTree ?? "-")\n", stderr)
      } else if token.hasPrefix("utter:") {
        // The words a rig puts in this Mac's mouth. Straight into the recogniser's
        // own callback, so the send gate below decides its fate exactly as it
        // would for a real sentence.
        let words = String(token.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
        if let u = gUtter {
          fputs("utter: \"\(words)\"\n", stderr)
          u(words, true)
        } else {
          fputs("utter: no recogniser on this run -- nothing said\n", stderr)
        }
      } else if token.hasPrefix("%") {
        // `%Check for Updates…` -- a MENU item, through AppKit's own dispatch.
        // Separate from `@` because the menu is not in `controls` and a handler
        // called directly cannot fail the way a menu item with no target fails.
        let title = String(token.dropFirst())
        fputs("menu \"\(title)\": \(Menu.click(title))"
            + " -> \(display?.controls?.describeTree ?? "-")\n", stderr)
      } else if token.hasPrefix("+") {
        // `+kinpeer7759` types into whatever a preceding `@dial` focused.
        let text = String(token.dropFirst())
        let ok = display?.controls?.typeText(text) ?? false
        fputs("type \(text): \(ok ? "sent" : "NO WINDOW")"
            + " -> \(display?.controls?.describeTree ?? "-")\n", stderr)
      } else if token.hasPrefix("@") {
        // `@peek:2.5` presses and holds for 2.5 s, so a hold can be photographed
        // while it is held rather than inferred from the state after it ended.
        var n = String(token.dropFirst())
        var hold: TimeInterval = 0
        if let colon = n.lastIndex(of: ":"), let d = Double(n[n.index(after: colon)...]) {
          hold = d; n = String(n[..<colon])
        }
        // `@!answer` -- a click that looks like it came from a device rather than
        // from here. The waiting card refuses those when nothing suggests anybody
        // aimed them, and that refusal is the only defence against a ring window
        // stealing somebody's next tap. Without a way to send one, the defence
        // could only ever be observed in production, by accident, once.
        let stray = n.hasPrefix("!")
        if stray { n = String(n.dropFirst()) }
        display?.controls?.nudgeBar()
        let sent = display?.controls?.click(n, holdFor: hold, stray: stray) ?? false
        fputs("click \(stray ? "!" : "")\(n): \(sent ? "sent" : "NOT ON SCREEN") -> \(display?.controls?.describeTree ?? "-")\n", stderr)
      } else {
        pressControl(token)
      }
    }
  }
  DispatchQueue.main.asyncAfter(deadline: .now() + t) {
    fputs("presses done -- window is live for capture\n", stderr)
  }
}

if let shot = arg("shot") {
  let after = Double(arg("shot-after") ?? "6") ?? 6
  DispatchQueue.main.asyncAfter(deadline: .now() + after) {
    // --press mic,cam,invite: exercise the wiring before photographing it.
    if arg("press-after") == nil, let seq = arg("press") {
      for name in seq.split(separator: ",") { pressControl(String(name)) }
    }
    fputs("tree: \(display?.describeTree ?? "no display")\n", stderr)
    let ok = display?.snapshot(to: shot) ?? false
    fputs("shot: \(ok ? "wrote" : "FAILED") \(shot)\n", stderr)
    exit(ok ? 0 : 1)
  }
}

// ── THE CAMERA CASES THE FAST PATH DELIBERATELY DID NOT TAKE ────────────────
//
// An authorized camera was already started above, before the window, because the
// sensor is the slowest thing here and it should not wait for AppKit. What is
// left is what could not go there: a file source, and a camera whose permission
// is not yet settled -- where the system's modal dialog has to appear over a
// window that already exists, so it can only be asked for from here.
// `!ringPending` for the same reason as the fast path above, and it matters more
// here: this is the branch that can put up the SYSTEM's camera permission dialog,
// so without it a ring from somebody could ask a stranger's Mac for camera access
// before its owner had agreed to take the call.
if earlyCam == nil, videoArg != "off", !ringPending, display != nil || mdisplay != nil {
  if videoArg == "camera" {
    // The call path asks too, in case the app was started from the command line and
    // never saw the join window. Blocking here is fine and deliberate: the answer is
    // needed before the camera can produce a frame, the window is already on screen,
    // and the system draws the prompt -- not us.
    //
    // Reached only when the status was not already `.authorized` when the window
    // was built -- a first run, or a refusal -- so this wait is once-ever rather
    // than once per launch. Every other launch took the path above and never
    // touched a semaphore.
    let gate = DispatchSemaphore(value: 0)
    var got = CameraSource.Access.denied
    fputs("camera: asking for permission at \(sinceLaunch()) ms\n", stderr)
    CameraSource.requestAccess { a in got = a; gate.signal() }
    // A minute is longer than anyone takes to answer, and expiring is not fatal:
    // the call continues without a picture rather than never starting.
    _ = gate.wait(timeout: .now() + 60)
    if got != .granted {
      Metrics.count("cam_denied")
      Metrics.fact("cam_access", "\(got)")
      fputs("camera: not permitted (\(got)) -- continuing with audio only."
          + " System Settings > Privacy & Security > Camera\n", stderr)
      display?.controls?.setStatus("camera off — check Privacy settings")
    }
    let cam = CameraSource()
    earlyCam = cam
    attachCamera(cam)
  } else {
    let f = FileSource(path: videoArg, fps: Double(arg("fps") ?? "30") ?? 30)
    f.onFrame = { pb, _ in
      display?.showSelf(pb)
      if !sawRemote && !peerHere { mdisplay?.show(pb, at: Clock.now()) }
    }
    do {
      // A file source's `start()` spawns its own reader thread and returns at
      // once, so there is nothing here to move off main.
      try f.start()
      earlyCam = f
      fputs("preview: \(f.describe) on screen before the call connects"
          + " (session up at \(sinceLaunch()) ms)\n", stderr)
    } catch {
      // Not fatal. A call with no camera is still a call, and saying so beats a
      // blank window with no explanation.
      fputs("preview: unavailable (\(error)) -- continuing without a picture\n", stderr)
      setWindowTitle("Kin — no camera; waiting for the other person")
    }
  }
}

// ── THE PICKER BELONGS HERE, NOT AFTER THE RENDEZVOUS ───────────────────────
//
// Wired after the rendezvous it never appeared at all while waiting -- and "is my
// camera the right one" is precisely the question a person has while waiting for
// someone to join. Third time this file has put something the user needs behind a
// barrier that only lifts once the other person arrives.
//
// `--cam-picker-test 3` fills it with placeholders: this Mac has exactly one
// camera, so the picker is correctly hidden and therefore unverifiable, and a
// hidden control returns the same nothing as a broken one. It needs no hardware,
// so it no longer waits behind one either -- it used to be wired inside the
// camera bring-up, which meant the control that exists to be testable was itself
// gated on the thing under test.
if videoArg != "off", let n = arg("cam-picker-test").flatMap({ Int($0) }), n > 1 {
  display?.controls?.setCameras((1...n).map { "Test camera \($0)" }, current: 0)
  display?.controls?.onCamPick = { i in fputs("camera: picker chose index \(i)\n", stderr) }
}

// ── THE HANDLE AND THE SILENT SWITCH, JOINED UP ─────────────────────────────
//
// Both directions are asynchronous and both are deliberate. The name appears in
// the sheet only once the server has agreed it is ours, and the switch moves only
// once the server has agreed to silence us -- so nobody is told they are
// unreachable while a stranger's call is still landing.
Metrics.mark("identity_ready", sinceLaunch())
Identity.onClaimed = { name in
  Metrics.mark("handle_claimed", sinceLaunch())
  display?.controls?.setHandle(name)
  // The other edge. See `startRingingOnce` below -- on a first install the handle
  // is won several seconds after the line that used to decide this.
  startRingingOnce()
}
// Already claimed on a previous launch: the sheet should not wait for a network
// round trip to show a name that is on this disk.
if Identity.claimed {
  display?.controls?.setHandle(Identity.handle)
  // onClaimed fires only the FIRST time a handle is won. Every launch after that
  // would have skipped the login item entirely -- including every launch by the
  // user who has had a handle for a month and still cannot be rung.
  // And the switch, from disk, so a restart does not show "you can be reached"
  // to somebody who is still silenced.
  display?.controls?.setSilent(Identity.quietOn)
}
// Same shape, same thread, same rule: the name in the sheet does not move until
// the server has agreed to it. `renamed` reports WHICH refusal it was, because a
// name that is taken and a network that is down are two different things to do
// about, and a boolean can only ever produce the vaguer of the two.
display?.controls?.onRenameHandle = { want in
  Thread {
    let outcome = Identity.renamed(to: want)
    if outcome == .ok { display?.controls?.setHandle(Identity.handle) }
    display?.controls?.renameAnswered(outcome, name: want)
  }.start()
}
display?.controls?.onSilent = { want in
  // Off main: this is an HTTPS round trip, and it is on the thread that draws.
  Thread {
    let ok = Identity.setQuiet(want)
    let now = Identity.quietOn
    display?.controls?.setSilent(now)
    if !ok {
      display?.controls?.setStatus(now == want ? "silent" : "could not change that")
    } else {
      display?.controls?.setStatus(want ? "silent" : "you can be reached")
    }
  }.start()
}

// ── DIALLING A NAME, AND BEING DIALLED ───────────────────────────────────────
//
// Both directions end in the same place: `reexec` into the room the ring named.
// That is deliberate and it is the reason this feature is small -- joining a room
// is a thing this program already does perfectly, from the first line of main,
// with every path tested. Re-entering it costs ~150 ms and inherits the whole
// call stack rather than growing a second one that can disagree with it.
// `tk --call devesh`: the same path the field takes, reachable without a mouse.
// Fired once the controls exist, so it cannot race the window into being.
if let who = arg("call") {
  DispatchQueue.main.async { display?.controls?.dial(who) }
}
// Handed a ring by the watcher. The mailbox has already been drained by the
// watcher's poll, so this cannot be re-discovered -- it arrives in argv or not
// at all, and the room is the one the caller minted.
// ── ONE OFFERED RING, TWO WAYS IN ──────────────────────────────────────────
//
// A ring reaches this process either from the in-app poll or, when Kin was
// closed, from the watcher via argv. `onAnswerRing` reads exactly one variable,
// because an answer path that only understands one of the two routes is a button
// that works or does nothing depending on how the call arrived -- and the
// watcher route is precisely the one nobody would test by hand.
if let from = arg("incoming"), let r = arg("room") {
  // No signature to check here: the watcher already verified it before deciding
  // to launch this process at all. No key either, so this contact is not
  // remembered on answer -- it will be, the next time they ring an open app.
  // The key comes from the watcher when the watcher is new enough to send it.
  // Without it this ring is a NAME and nothing else -- still answerable, still
  // shown, but not something to open a socket for before anybody agrees.
  let ik = arg("incoming-key") ?? ""
  gOffered = Identity.Ring(from: from, room: r, t: 0, k: ik, ageMs: 0,
                           known: !ik.isEmpty && Identity.contacts()[from] == ik,
                           keyChanged: false, kind: nil)
  Metrics.count("ring_recv_watch")
  // ── THEY MAY ALREADY HAVE CANCELLED, AND ONLY THE WATCHER KNOWS ───────────
  //
  // The doorbell drain is destructive and this copy did not do it: for the first
  // half-second of this launch the WATCHER is still the only process polling, so
  // a `bye` sent one beat after the ring is taken by the watcher and can never be
  // polled for here. It leaves the news on disk instead (`Identity.noteCancelled`
  // in Watch.swift), and this is the first of the two places that reads it.
  //
  // BEFORE the card and the ringtone, deliberately. Both are dispatched to main
  // just below, so checking after them would ring at somebody for a quarter of a
  // second before taking it back -- a cancelled call should make no noise at all.
  //
  // Through `handleBye` and not by hand, because a note only means something if
  // it is about THIS caller and THIS room, and that rule already exists in one
  // place for byes off the wire. Two copies of it is two things to get wrong.
  if Identity.takeCancelNote(from: from, room: r) {
    fputs("cancel: @\(from) called it off while Kin was still starting"
        + " -- the watcher took the message and left it here\n", stderr)
    Metrics.count("bye_note_prering")
    handleBye(Identity.Ring(from: from, room: r, t: 0, k: ik, ageMs: 0,
                            known: false, keyChanged: false, kind: "bye"))
  }
  // ── AND IT CAN ALSO LAND A MOMENT AFTER THAT LINE ─────────────────────────
  //
  // The read above is one sample of a file another process writes, so it answers
  // only for the instant it ran. A cancel that lands between it and this copy's
  // own first poll would be taken by the watcher, written after we looked, and
  // waited out in full -- the original bug moved a few hundred milliseconds to
  // the right. `once-fired-probes-record-transients`: a state read once at
  // startup is a birth certificate, not a subscription.
  //
  // Four times a second, for as long as this copy has something to ask about. It
  // is one open() of a path that is usually not there, against a window that has
  // a person looking at it, and it stops mattering the moment `gOffered` is
  // cleared -- by an answer, a decline, or by the note itself. `.common` mode so
  // it keeps firing while a menu or a drag is tracking.
  //
  // Handed straight to the run loop and not kept in a `let` of its own: a
  // top-level variable in this file is initialised in file order, and this file
  // has twice had one silently undone by its own initialiser after a thread had
  // already written to it. There is nothing here that needs a name.
  RunLoop.main.add(Timer(timeInterval: 0.25, repeats: true) { _ in
    guard let o = gOffered, o.kind == nil,
          Identity.takeCancelNote(from: o.from, room: o.room) else { return }
    fputs("cancel: @\(o.from) called it off -- the watcher took the message"
        + " while this copy was still starting up\n", stderr)
    Metrics.count("bye_note_ringing")
    handleBye(Identity.Ring(from: o.from, room: o.room, t: 0, k: o.k, ageMs: 0,
                            known: o.known, keyChanged: false, kind: "bye"))
  }, forMode: .common)
  DispatchQueue.main.async {
    display?.controls?.showIncoming(from: from, room: r)
    Ringer.start(raising: display?.callWindow)
  }
}
// ── WHO THIS IMAGE IS RINGING ──────────────────────────────────────────────
//
// The mirror of `--incoming`, and it exists because placing a call RE-EXECS. The
// process that sent the ring dies at `execv`; its successor knows only that it is
// alone in a room, so it drew the ordinary waiting card -- "Waiting for the other
// person…" over an invite link, pixel-identical to an app somebody had just
// opened. The one thing the caller needed to know, the name of the person being
// rung, was the one thing the re-exec threw away.
if let who = arg("calling") {
  gCalling = (who, arg("room") ?? "")
  let away = flag("callee-away")
  DispatchQueue.main.async { display?.controls?.showOutgoing(to: who, away: away) }
}
startRingingOnce()
display?.controls?.onCall = { who in
  // Off main: signing and an HTTPS round trip, on the thread that draws.
  Thread {
    let room = Launcher.mintRoom()
    Metrics.count("ring_sent_try")
    guard let got = Identity.ring(to: who, room: room) else {
      Metrics.count("ring_sent_fail")
      Metrics.fact("outcome", "could not ring them")
      // Honest, and vague on purpose. A 200 means the ring is in their mailbox;
      // anything else means we could not put it there. Neither says whether they
      // are awake, and silence is indistinguishable from away by design.
      display?.controls?.setStatus("couldn\u{2019}t reach \(Identity.display(who))")
      // On the card too. The status pill is four words in a corner; the card is
      // where the person is looking, and it is currently showing them a ring that
      // is not happening.
      display?.controls?.showCallFailed("Couldn\u{2019}t reach \(Identity.display(who))",
                                        because: "check the name, and try again")
      return
    }
    Metrics.count("ring_sent_ok")
    Metrics.mark("ring_sent_ms", sinceLaunch())
    // The ring landed in their mailbox. Whether anybody is there to take it out
    // is a different question, and now one the server answers. nil means it had
    // no basis to say, which is NOT the same as no -- so only an explicit false
    // changes a word on screen.
    let listening = Identity.lastRingListening
    Metrics.fact("callee_listening", listening.map { $0 ? "yes" : "no" } ?? "unknown")
    DispatchQueue.main.async {
      display?.controls?.setStatus("ringing \(Identity.display(who))…")
      // Carried as a FLAG rather than said here. `reexec` replaces this process
      // within the same run loop turn, so anything written to the screen on this
      // line is drawn by a process that is about to stop existing -- a status
      // nobody can read is the same as no status, and this project has shipped
      // that shape before. The window that actually waits for them is in the
      // NEXT process, so the news has to travel with it.
      var extra = ["--video", "camera", "--window", "--calling", who]
      if listening == false { extra.append("--callee-away") }
      Launcher.reexec(room: got, extra: extra, why: "call placed")
    }
  }.start()
}

// Listening. One thread, one poll every `--ring-gap` ms (the server refuses more
// than one poll per 2 s per handle, so the floor is not ours to choose).
// ── ANSWER AND DECLINE ARE WIRED UNCONDITIONALLY ───────────────────────────
//
// These used to live inside the poll block, so a ring delivered by the WATCHER
// -- the one route that exists precisely because the app was not running -- would
// draw a card with two buttons that did nothing. The poll loop is conditional;
// being able to answer is not.
display?.controls?.onAnswerRing = {
  // WHAT PRESSED IT. Answering re-execs the process, so by the time anything is
  // wrong the evidence is gone -- and an answer that fires with nobody at the
  // keyboard is indistinguishable in every other log line from one a person
  // pressed. `currentEvent` is the event AppKit is dispatching right now: a real
  // press says leftMouseUp with a location, and anything else says this did not
  // come from a finger.
  let e = NSApp.currentEvent
  fputs("ring: answer committed by "
      + (e.map { "\($0.type) at \($0.locationInWindow)" } ?? "NO EVENT -- not a click")
      + "\n", stderr)
  Ringer.stop()
  guard let o = gOffered else { Metrics.tap("answer", ok: false); return }
  Metrics.tap("answer")
  Metrics.count("ring_answered")
  Metrics.mark("answered_ms", sinceLaunch())
  Metrics.fact("outcome", "answered")
  // Remembered on ANSWER, not on arrival: binding a name to a key when the ring
  // merely turns up would let whoever rings first own the name.
  //
  // SYNCHRONOUSLY, and that is not a style choice. `reexec` is `execv`: it
  // replaces this image on the next line. A background thread doing the write
  // would be killed mid-file, and the file it was writing is the contact list.
  // Only when we actually hold the key. The watcher route carries none, and
  // binding a name to an empty string would poison the contact list.
  if !o.k.isEmpty { Identity.remember(handle: o.from, key: o.k) }
  display?.controls?.setStatus("answering \(Identity.display(o.from))…")
  Launcher.reexec(room: o.room, extra: ["--video", "camera", "--window"], why: "ring answered")
}
// Cancelling a call nobody has answered yet. `onLeave` still exists and still
// just leaves; this one exists because there is a person on the other end whose
// Mac is ringing, and until now the only thing that stopped it was a timeout.
display?.controls?.onHangUp = {
  guard let c = gCalling else { leaveCall() }
  hangUpAndExit(to: c.who, room: c.room, why: "cancelled")
}
display?.controls?.onDeclineRing = {
  Ringer.stop()
  Metrics.tap("decline")
  Metrics.count("ring_declined")
  Metrics.fact("outcome", "declined")
  // Read BEFORE it is cleared. This is the only record of who is being
  // declined, and the whole point of the next few lines is telling them.
  let who = gOffered?.from ?? ""
  let room = gOffered?.room ?? ""
  gOffered = nil
  // ── A PROCESS THAT EXISTS ONLY TO ASK IS DONE WHEN THE ANSWER IS NO ───────
  //
  // The watcher opens a whole new copy of Kin for each ring, precisely so that
  // declining does not take the watcher down with it. That copy has no room, no
  // socket and nothing else to do, and leaving it running left an app on screen
  // showing an empty invite box for a call that was refused.
  //
  // Only when this image IS the ring. An app that was already open and in a call
  // when somebody rang must not exit on decline -- there is a call in it.
  if ringPending {
    fputs("ring: declined -- nothing else for this copy to do\n", stderr)
    hangUpAndExit(to: who, room: room, why: "declined")
    return
  }
  // Already in a call when somebody rang: this image stays, but the person who
  // rang still has to hear no. Fire and forget -- nothing here is exiting.
  sendBye(to: who, room: room, why: "declined")
}

// ── A RING IS NOT A CALL UNTIL SOMEBODY SAYS SO ───────────────────────────────
//
// Measured on a real call, and it is the worst thing this app has done. The
// watcher launches Kin with BOTH `--room <r>` and `--incoming <who>`, so the copy
// that exists to ask "do you want to talk to Meera?" fell straight through into
// the rendezvous and joined the room. With nobody having pressed anything:
//
//     the caller           status=connected   card=hidden
//     the callee           sent 1513/s  recv 1510/s  played 1503/s
//
// So the ring answered itself. The caller saw the call connect; the callee's
// microphone was live in a room with them; and `setPeerPresent(true)` then HID the
// ringing card, which is the control that would have let them say no. On top of
// that the ringtone was playing out of the speakers into that live microphone,
// which is the echo on both ends that came with it.
//
// The fix is the sentence in the heading. This copy shows a card and waits. It
// opens no socket, no microphone and no camera, and it turns on no green light
// next to somebody who has not agreed to be on a call. Answering re-execs into
// the room -- which is what `onAnswerRing` already did -- and that new image is an
// ordinary call with no `--incoming` on it.
//
// Placed HERE, above every line that touches a device or a socket, and gated on
// the flag rather than on the watcher's argv: the resident watcher is the last
// thing to update (see `updater-ships-only-what-it-can-install`), so the app has
// to defend itself against the OLD watcher's launch line, which is the one that
// will keep arriving for as long as somebody stays logged in.
// ── AND YET THEIR FACE SHOULD BE ON IT ─────────────────────────────────────
//
// "If someone is calling, their video should be visible to you so you know who
// is calling exactly." Both things are true at once, and the shape that makes
// them true is asymmetric: this copy RECEIVES and never SENDS.
//
//   receives   the rendezvous, the socket, the incoming picture, decoded and
//              drawn behind the card. That is who is calling.
//   sends      nothing. No microphone is opened, so there is nothing to send and
//              no green light; no camera is opened, so there is no picture of
//              this room; and no audio engine is started, so the caller's voice
//              is received and never played.
//
// The two lines that make "sends nothing" true are not new rules bolted on: the
// camera bring-up is already gated on `ringPending` (0.61.0) and audio is sent
// from the capture callback, which only exists once `audio.start()` runs -- so
// the whole of it is one skipped call plus the gate that was already there.
//
// And the caller is TOLD. `ST_RINGING` in the status byte is what stops the
// caller reading packets-arriving as answered -- which is precisely the mistake
// that made a ring answer itself. Their card keeps saying Calling, and their
// microphone stays off this wire until somebody says yes.
// ── AND ONLY FOR SOMEBODY YOU HAVE ALREADY TALKED TO ──────────────────────
//
// RINGING.md wrote this rule down before the feature existed, and it is the one
// thing that keeps it from being a leak: "the callee's probes go to those
// candidates, so the CALLER learns the callee's IP and that the Mac is online
// and awake, BEFORE consent. This is the real leak. The mitigation to ship
// instead: probe only for rings whose `k` is already in the contact list."
//
// So a stranger who has learnt your handle can make your Mac ring and learns
// nothing else -- no address, no proof you are at it. Somebody you have already
// spoken to gets the fast, visible version, which is the FaceTime contract and
// is what the feature is for. `known` is set from the contact list above, and
// for a ring delivered by an older watcher -- which sends no key -- it is false,
// so those simply do not connect early. That is the pre-0.64 behaviour, which is
// the right thing to degrade to.
let ringPreviewAllowed = gOffered?.known ?? false
let ringPreview = ringPending && arg("room") != nil && ringPreviewAllowed
  && ProcessInfo.processInfo.environment["TK_RING_PREVIEW"] != "0"
  && !flag("no-ring-preview")
if ringPending {
  fputs("ring: waiting to be answered -- no microphone, no camera"
      + (ringPreview ? ", their picture only\n" : ", no room\n"), stderr)
  Metrics.count("ring_offered")
  Metrics.count(ringPreview ? "ring_preview" : "ring_preview_off")
  if !ringPreviewAllowed {
    Metrics.count("ring_preview_stranger")
    fputs("ring: @\(arg("incoming") ?? "?") is not in this Mac's contacts"
        + " -- not connecting before you answer\n", stderr)
  }
  // ── SET HERE, NOT ONCE A SECOND ─────────────────────────────────────────
  //
  // `selfStatus` is otherwise assigned in the report loop, which first runs a
  // second into the call -- and the hole-punch and time probes go out long
  // before that. Measured: the caller locked, read a status byte of zero,
  // announced "connected" and took its calling card down, and only THEN heard
  // the ring bit. A flag that describes what this process IS must be true from
  // the moment the process can send anything, not from the first tick of a
  // loop that reports on it.
  if ringPreview { wire.selfStatus |= Wire.ST_RINGING }
  // The callee's own copy never draws a calling card, so without this a ring
  // that was never answered reported no outcome at all -- and "nothing recorded"
  // is what a crash looks like too.
  Metrics.fact("outcome", "being asked")
  // Same switch, same reason: a rig must not take the screen away from whoever
  // is using this Mac. See Display's window placement and Ringer.start.
  if ProcessInfo.processInfo.environment["TK_NO_RAISE"] != "1" {
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
  // Without a room to look at there is nothing to fall through TO, and falling
  // through would run a whole call's worth of setup for a socket with no peer.
  if !ringPreview {
    NSApplication.shared.run()
    exit(0)
  }
}

// ── AND IT HAS TO START WHEN THE HANDLE ARRIVES, NOT WHEN THIS LINE RUNS ────
//
// `Identity.claimed` is written by a background thread -- the claim is a network
// round trip, and on a first install it is SEVERAL, because the obvious names are
// taken and it walks down the list. This line runs long before any of that
// finishes, so on a fresh install it read false and the doorbell never started:
// you claim a name, you tell somebody, and you cannot be rung until you quit and
// reopen Kin. First run is exactly when a person tries this.
//
// So it is a function called from BOTH edges -- here for the launch that already
// has a handle on disk, and from `onClaimed` for the launch that wins one while
// running -- with a latch, because `startRinging` spawns a thread and two of them
// would poll the same mailbox and take turns losing rings to each other.
// `once-fired-probes-record-transients`: a state read once at startup is a
// birth certificate, not a subscription.
// ── A BYE IS ONLY EVER ABOUT THE CALL YOU ARE ON ───────────────────────────
//
// Matched on `from` AND `room`, both, before it is allowed to change anything.
// The room is the half that carries the weight: it was minted for this call
// minutes ago and the only two machines that have ever seen it are the two ends.
// A stranger who knows a handle can put a signed bye in this mailbox all day and
// every one of them lands here and is dropped.
//
// Deliberately NOT gated on the contact list. The first call from somebody new
// is trust-on-first-use for the ring, and a bye that only worked for people you
// had already spoken to would leave the very first call -- the one most likely
// to be declined -- as the one that hangs.
func handleBye(_ r: Identity.Ring) {
  // The person we are ringing has said no, or hung up before we gave up.
  if let c = gCalling, r.from == c.who, r.room == c.room {
    // A bye is a person hanging up, whichever road it came down. The in-band one
    // on the media socket is faster and works for a link invite; this one still
    // arrives when the call never got as far as media. Either way the record has
    // to go, or the next launch would walk back into a call somebody declined.
    Resume.end(why: "they said no")
    Metrics.count("bye_recv_calling")
    Metrics.mark("bye_recv_ms", sinceLaunch())
    Metrics.fact("outcome", "they said no")
    fputs("bye: @\(r.from) is not taking the call\n", stderr)
    // Plain words, and no blame in either direction: from here we cannot tell
    // declined from cancelled-at-the-same-moment from a Mac that went to sleep.
    display?.controls?.showCallFailed("\(Identity.display(r.from)) can\u{2019}t talk right now",
                                      because: "try again in a little while")
    return
  }
  // The caller gave up while this Mac was ringing. Stop the noise, take the card
  // down, and -- if this copy of Kin exists only to ask -- there is nothing left
  // to ask about.
  if let o = gOffered, r.from == o.from, r.room == o.room {
    Resume.end(why: "they stopped calling")
    Metrics.count("bye_recv_ringing")
    Metrics.mark("bye_recv_ms", sinceLaunch())
    Metrics.fact("outcome", "they hung up before this Mac answered")
    Ringer.stop()
    gOffered = nil
    display?.controls?.hideIncoming()
    display?.controls?.setStatus("\(Identity.display(r.from)) hung up")
    fputs("bye: @\(r.from) stopped calling\n", stderr)
    if ringPending {
      shuttingDown = true
      postFinalBeat(why: "caller hung up")
      exit(0)
    }
    return
  }
  // Counted, not silent. A bye that matches nothing is either a stale message
  // from a call that already ended -- ordinary -- or the two ends disagreeing
  // about which room they are in, which is not.
  Metrics.count("bye_recv_stale")
  fputs("bye: @\(r.from) hung up on a call this Mac is not on -- ignored\n", stderr)
}

func startRingingOnce() {
  // The two edges arrive on different threads -- this launch's top-level code,
  // and the claim's completion on its network thread -- and two of them through
  // the guard means two poll threads on one mailbox, taking turns losing rings to
  // each other. Decided under the lock, acted on outside it: `startRinging`
  // spawns a thread and nothing it does needs to be serialised with this.
  ringStartLock.lock()
  let go = !ringingStarted && Identity.claimed && !flag("no-rings")
  if go { ringingStarted = true }
  ringStartLock.unlock()
  guard go else { return }
  fputs("ring: listening for calls to @\(Identity.handle)\n", stderr)
  // The whole ring, not a pair of strings: answering has to remember the KEY that
  // rang, and an earlier version of this line kept only the name and bound the
  // contact to an empty string -- which would have made every later ring from
  // that person read as a changed key.

  Identity.startRinging(gapMs: Int(arg("ring-gap") ?? "5000") ?? 5000) { r in
    // FIRST, above every line that treats this as a call. A bye is not a ring:
    // it makes no sound, draws no card, and remembers no contact.
    // A ring older than its lease is not a call, it is a record of one -- and a
    // hang-up older than its lease is not a hang-up either. Checked ABOVE the
    // kind switch, so both get the same freshness rule: a two-minute-old bye
    // reaching a reused room could otherwise end a call that had just started.
    guard r.ageMs < 60_000 else { return }
    if r.kind == "bye" { handleBye(r); return }
    if r.keyChanged {
      // The name is one we know and the key is not. Say the name is in doubt
      // rather than dropping it: a reinstall looks exactly like this, and so
      // does somebody claiming a name that is not theirs.
      fputs("ring: @\(r.from) rang with a DIFFERENT key than we remember\n", stderr)
    }
    gOffered = r
    Metrics.count("ring_recv")
    Metrics.mark("ring_recv_ms", sinceLaunch())
    if r.keyChanged { Metrics.count("ring_key_changed") }
    if r.known { Metrics.count("ring_known") }
    fputs("ring: @\(r.from) is calling -- room \(r.room), age \(r.ageMs) ms,"
        + " known=\(r.known)\n", stderr)
    display?.controls?.showIncoming(from: r.from, room: r.room)
    // This line was missing entirely. A ring that arrived while Kin was open --
    // the ORDINARY case, the one that does not need a watcher at all -- drew a
    // card in a window that was very probably behind something, made no sound,
    // and did not bounce the dock. It was a silent call.
    Ringer.start(raising: display?.callWindow)
  }
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
  // ── THE NAME IN THE DIRECTORY MUST SURVIVE A RESTART ───────────────────────
  //
  // It was `mac-<pid>`. The room's peer map (worker.ts `rvPeers`) is keyed by
  // this string and swept after 90 s, so a process that crashed and came back
  // published under a NEW key and left its own corpse in the map for a minute and
  // a half -- listed to the far end ahead of the live entry, and listed to
  // ITSELF as a peer to race candidates against. That is `open-socket-is-not-a-
  // live-peer` and the web app's own `sid` comment, and it is the single most
  // likely way rejoining fails: the returning process collides with its ghost.
  //
  // A stable id makes the map overwrite the entry instead of adding one, so no
  // ghost is ever created and the server needs no change. Derived per room so it
  // is not a tracking identifier; see Resume.rendezvousId.
  let me = arg("id") ?? Resume.rendezvousId(room: room, port: Int(listenPort))
  // ── NO PUBLIC ADDRESS IS NOT THE END OF THE CALL ──────────────────────────
  //
  // This used to be `exit(1)`. On any network that blocks UDP 3478 -- a hotel, a
  // corporate guest VLAN, a captive portal -- double-clicking the app made it
  // appear in the Dock and disappear, with the reason on a stderr stream nobody
  // launched it from. Two machines on the same wifi never needed the public
  // address in the first place, so the honest behaviour is to publish what we do
  // know, say so on screen, and let the call try.
  // ── PAINT BEFORE THE NETWORK ────────────────────────────────────────────────
  //
  // The window is created 500 lines above here and the camera is already running.
  // Neither of them needs a socket -- CameraSource.start is pure AVFoundation and
  // the frame sink only calls display?.showSelf, so the local picture is ALREADY
  // above the network in program order. The only reason nothing was on screen was
  // that the main thread walked out of the camera straight into STUN -> TURN ->
  // rendezvous and did not return to the runloop for 2878 ms: the window existed,
  // was key, and was blank glass for the best part of three seconds.
  //
  // So the cheapest correct fix is not "move the network", it is "turn the runloop
  // before it". This one call is most of the win. The thread below is what keeps
  // the window alive and clickable while the network happens.
  if display != nil || mdisplay != nil {
    Launcher.pumpAppKit(until: Date().addingTimeInterval(0.06))
  }

  // ── ONE READER ON wire.fd. ALWAYS ───────────────────────────────────────────
  //
  // Stun.discover and TurnClient.roundTrip both recvfrom on the media socket, both
  // setsockopt(SO_RCVTIMEO) on it, and roundTrip's defer hands it back BLOCKING.
  // So the two of them stay serialized with each other on this one thread, and the
  // media recv loop is not allowed to start until this thread has finished (the
  // wait is below, right after the join). Two readers on this descriptor is
  // intermittent unattributable audio loss at call start, plus a TURN allocate
  // that fails for no visible reason.
  //
  // TurnClient.fetch() is pure HTTPS and never touches the socket -- that is the
  // free parallelism, and it runs while STUN is still in flight.
  let stunDone = DispatchSemaphore(value: 0)
  let turnDone = DispatchSemaphore(value: 0)
  let fetchDone = DispatchSemaphore(value: 0)
  let relay = RelayBox()
  var mapped: Stun.Mapped?
  var creds: TurnClient?
  DispatchQueue.global().async {
    creds = TurnClient.fetch()
    fetchDone.signal()
  }
  Thread {
    mapped = Stun.discoverAny(fd: wire.fd,
                              servers: arg("stunserver").map { [$0] })
    // ── WHERE THE SECONDS BEFORE "CONNECTED" ACTUALLY GO ────────────────────
    //
    // `connected_ms` was the only mark on this whole path, so a 3.1 s p50 was a
    // number with no parts. These four split it into the phases that can each
    // be fixed separately: STUN, the rendezvous exchange that finds the peer,
    // the TURN allocate the connect then BLOCKS on, and the candidate race.
    Metrics.mark("stun_ms", sinceLaunch())
    stunDone.signal()
    // TURN on the same socket, after STUN and before the media loop exists.
    // Fail-open: a missing relay still leaves STUN + LAN, which is how every call
    // used to work.
    // THE RESULT OF THE WAIT IS THE PERMISSION TO READ. This was
    // `_ = fetchDone.wait(...)` followed by `if let tc = creds`, which on the
    // timeout path reads a refcounted class reference while the other thread may
    // still be storing it -- a torn retain, which is the crash `runPumping` in
    // Launcher.swift spells out in its own comment and deliberately avoids. On
    // timeout there is nothing to read, so nothing is read.
    if fetchDone.wait(timeout: .now() + 8) == .success, let tc = creds {
      if tc.allocate(fd: wire.fd) {
        wire.turn = tc
        relay.set(tc.relayed)     // the poll loop republishes with it on its next turn
      } else {
        fputs("turn: allocate failed -- racing STUN and LAN only\n", stderr)
      }
    } else {
      fputs("turn: no credentials (or /api/mac/turn unreachable or still fetching after 8 s)"
          + " -- racing STUN and LAN only\n", stderr)
    }
    Metrics.mark("turn_ms", sinceLaunch())
    turnDone.signal()
  }.start()

  // Pump AppKit until STUN answers, in 20 ms slices, so the wait ends within a
  // frame of the answer instead of at some fixed timeout.
  //
  // ── AND THE FALLBACK PUMPS TOO ──────────────────────────────────────────────
  //
  // This loop used to give up pumping after 15 s and fall through to a bare
  // `stunDone.wait()`, on the stated grounds that it was better to block than to
  // "read a variable another thread is still writing". That reasoning does not
  // require a deadline: `mapped` is read only after a wait on `stunDone` has
  // SUCCEEDED, and a zero-timeout wait publishes exactly as much as a blocking one
  // -- the semaphore is the barrier, not the blocking. What the deadline did buy
  // was a main thread inside a bare wait(), which is a window that does not draw,
  // does not move, and shows the spinning cursor, for as long as STUN is stuck.
  // Every other wait in this file pumps; so does this one now, for as long as it
  // takes, and the barrier is unchanged.
  var stunReady = false
  while !stunReady {
    if display != nil || mdisplay != nil {
      Launcher.pumpAppKit(until: Date().addingTimeInterval(0.02))
    } else {
      usleep(5_000)
    }
    if stunDone.wait(timeout: .now()) == .success { stunReady = true }
  }

  let myLocal = localIPv4().map { "\($0):\(listenPort)" }
  let mine = mapped.map { "\($0.ip):\($0.port)" }
  // These diagnostics deliberately stay on the MAIN thread: setStatus is AppKit,
  // and off-main AppKit mutation is the class of bug that has already SIGSEGV'd
  // this process. Nothing here is slow -- the waiting happened above.
  if mine == nil {
    if myLocal == nil {
      fputs("room: no public address and no local address -- this machine has no"
          + " usable network route\n", stderr)
      display?.controls?.setStatus("no network")
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(1) }
    } else {
      fputs("room: STUN found no mapping -- advertising \(myLocal!) only,"
          + " so a call on this network still works\n", stderr)
      display?.controls?.setStatus("this network only")
    }
  }
  fputs("room \(room): I am \(me), public \(mine ?? "unknown")"
      + "\(myLocal.map { ", local " + $0 } ?? "") at \(sinceLaunch()) ms\n", stderr)
  var found = false
  var bindTarget: (String, UInt16)?
  // ── A DEADLINE, NOT A COUNT ─────────────────────────────────────────────────
  //
  // This was `for attempt in 1...60` with a two-second sleep, and the message at
  // the bottom says "nobody else arrived in 2 minutes" -- so 60 was two minutes
  // only as long as nobody touched the cadence. Speeding the polls up would have
  // collapsed the give-up window to about six seconds while the message went on
  // claiming two minutes, and a peer ten seconds late would have been met with
  // exit(1). Same class as every RTT-blind timeout in this codebase: a threshold
  // expressed in the wrong unit is a hidden limit. The unit is now seconds.
  let giveUp = Date().addingTimeInterval(120)
  let joinStart = Date()
  var attempt = 0
  while Date() < giveUp {
    attempt += 1
    // Re-publish every poll: the lease is short on purpose, because an address is
    // only true while the NAT binding behind it lives.
    //
    // `relay.get()` and not a captured value: the relay may not exist yet and the
    // join does not wait for it. /rv is an in-memory Map write with a 90 s lease
    // and no rate limit, and it overwrites the entry every time, so republishing
    // with a relay a second later costs nothing and TURN latency costs the join
    // nothing at all -- fixed allocate or not.
    // OFF MAIN, PUMPING. The exchange is a blocking HTTPS round trip and this
    // loop owns the main thread for the entire time the waiting screen is up --
    // which is precisely when the person is trying to copy the link. The peers
    // still arrive here, on this thread, in this order; only the wait moves.
    // A nil return is a poll that did not answer in time, which is what the next
    // iteration is for.
    let relayNow = relay.get()
    // Two optionals, two different failures, and both mean "try again next
    // iteration" HERE: runPumping's nil is "the pump timed out", exchange's is
    // "the directory did not answer". Flattened rather than conflated, because
    // the caller further down that DOES care about the difference reads it
    // unflattened.
    let peers = (Launcher.runPumping(pump: display != nil || mdisplay != nil) {
      Rendezvous.exchange(room: room, me: me, addr: mine, local: myLocal, relay: relayNow)
    } ?? nil) ?? []
    if let p = peers.first {
      // Every address we have, raced by measured RTT — LAN, public, and the
      // peer's TURN relayed address. First-packet-wins was the public internet
      // as often as the short path.
      wire.addCandidate(ip: p.ip, port: p.port)
      var cands = ["\(p.ip):\(p.port)"]
      if let lip = p.localIP, let lport = p.localPort {
        wire.addCandidate(ip: lip, port: lport)
        cands.append("\(lip):\(lport)")
      }
      if let rip = p.relayIP, let rport = p.relayPort {
        wire.addCandidate(ip: rip, port: rport)
        cands.append("relay \(rip):\(rport)")
      }
      // NOT HERE. bindPeer does two round-trips on wire.fd, and the TURN thread
      // above may still be inside its own -- two readers on one descriptor, the
      // exact race this file spends 40 lines warning about. Remembered, and done
      // once that thread has signalled, a few lines below.
      bindTarget = (p.ip, p.port)
      // A provisional destination so media has somewhere to go in the moments
      // before a probe comes back; the first packet that arrives replaces it with
      // an address known to work.
      wire.setPeer(ip: p.ip, port: p.port)
      fputs("room \(room): peer \(p.id) (\(p.ageMs) ms old) -- racing \(cands.joined(separator: " and "))\n", stderr)
      Metrics.mark("peer_found_ms", sinceLaunch())
      Metrics.count("join_polls", attempt)
      setWindowTitle("Kin — connecting")
      found = true
      break
    }
    if attempt == 1 { fputs("room \(room): waiting for the other person...\n", stderr) }
    // ── FAST WHILE IT MATTERS ───────────────────────────────────────────────────
    //
    // A flat two seconds cost the first arriver 2104 ms of "waiting for the other
    // person" for no reason: the peer had published, and we were asleep. The
    // seconds that matter are the first few, so spend polls there and back off
    // afterwards. Real cadence is exchange latency PLUS this sleep -- the exchange
    // is synchronous, ~400 ms -- so the fast end is about 500 ms, and two peers
    // come to roughly 5 requests a second against one in-memory Map. Nothing.
    let age = Date().timeIntervalSince(joinStart)
    let gap: Double = attempt <= 10 ? 0.1 : (age < 3 ? 0.25 : (age < 10 ? 0.5 : 2.0))
    // PUMP THE EVENT LOOP, do not just sleep. With a window open this loop owns
    // the main thread, and a main thread inside usleep is a window that does not
    // draw, does not move and shows the spinning cursor -- which is worse than no
    // window at all. Same pump as everywhere else.
    if display != nil || mdisplay != nil {
      Launcher.pumpAppKit(until: min(Date().addingTimeInterval(gap), giveUp))
    } else {
      usleep(UInt32(gap * 1_000_000))
    }
  }
  if !found {
    fputs("room \(room): nobody else arrived in 2 minutes.\n", stderr)
    exit(1)
  }
  // ── THE SOCKET IS OURS AGAIN ────────────────────────────────────────────────
  //
  // Everything below this line -- the probe threads, the media recv loop, the
  // audio graph -- shares wire.fd, so the STUN/TURN thread has to be finished
  // first. This is the barrier that makes "one reader on wire.fd" true, and it is
  // also what publishes wire.turn to this thread.
  //
  // PUMPED, not blocked. This was a bare `turnDone.wait(timeout: .now() + 20)`, and
  // the window at this point in the launch says "connecting" -- so a slow TURN
  // allocate froze that window solid, on the main thread, for up to twenty seconds.
  // That is exactly the class of defect the launch work just removed everywhere
  // else. A zero-timeout wait in a pumping loop is the same memory barrier as a
  // blocking one, so `wire.turn` is still read only after a wait that SUCCEEDED.
  let turnDeadline = Date().addingTimeInterval(20)
  let turnWaitBegan = Date()
  var turnJoined = false
  while Date() < turnDeadline {
    if display != nil || mdisplay != nil {
      Launcher.pumpAppKit(until: min(Date().addingTimeInterval(0.02), turnDeadline))
    } else {
      usleep(5_000)
    }
    if turnDone.wait(timeout: .now()) == .success { turnJoined = true; break }
  }
  // How long the CONNECT stood still for the relay. Distinct from `turn_ms`,
  // which says when the allocate finished: this says how much of that the
  // person waited through after their peer was already found and reachable.
  // A direct call does not need the relay at all, and this is the number that
  // says what asking for it anyway costs.
  Metrics.mark("turn_blocked_ms", Int(Date().timeIntervalSince(turnWaitBegan) * 1000))
  if turnJoined {
    if let t = wire.turn, let b = bindTarget, t.bindPeer(fd: wire.fd, ip: b.0, port: b.1) {
      fputs("turn: channel bound to \(b.0):\(b.1)\n", stderr)
    }
  } else {
    // Never seen; said out loud rather than raced past, because this branch is a
    // FAIL-OPEN and not a barrier: carrying on means a still-running TURN thread
    // becomes a second reader on the media socket from here to the end of the call,
    // which is intermittent unattributable audio loss and nothing in the log to
    // attribute it to. Left as it is on purpose -- closing it means giving that
    // thread a way to be told to stop touching the socket, which is a change to
    // TurnClient and not to this line -- but it is written down rather than implied
    // by a timeout that reads like a safety margin.
    fputs("turn: still working after 20 s -- carrying on without the relay"
        + " (that thread is now a second reader on the media socket)\n", stderr)
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
  // Punch every candidate until one answers, and go back to punching if the peer
  // ever goes quiet. Fast while unresolved, because this is the window a person
  // experiences as "is it connecting?", and both NATs need an outbound packet
  // before either will pass an inbound one.
  Thread {
    var announcedFor = ""
    /// Consecutive rendezvous polls that did not list the peer at all.
    var gone = 0
    /// Ticks since the transport locked, for the deadline below.
    /// When the transport locked, as a CLOCK and not a tick count.
    ///
    /// This was `var sinceLocked = 0`, incremented once per pass, and the
    /// deadline below read `sinceLocked > 20` with a comment reading "TWENTY
    /// TICKS, TEN SECONDS". Ten seconds only for as long as nobody touched the
    /// loop's sleep -- and the sleep is the obvious thing to touch, because this
    /// is the loop a person watches as "connecting".
    ///
    /// Proven, not hypothesised: an experiment here that took the tick from
    /// 500 ms to 25 ms turned that ten-second fallback into half a second, and
    /// the rig read the result as a 482 ms improvement in connect time. It was
    /// not one. The app was announcing "connected" on a TIMEOUT half a second
    /// after locking, without ever having heard the other end's status byte --
    /// declaring a call answered on a threshold rather than on evidence, which
    /// is the exact hazard the comment at the deadline itself warns about.
    ///
    /// The unit is seconds now, so the deadline means what it says whatever the
    /// cadence becomes. Same class as the join loop thirty lines up, which was
    /// converted from `for attempt in 1...60` for the same reason.
    var lockedAt = Date.distantFuture
    // ── HOLDING A CALL WHOSE OTHER END IS RESTARTING ──────────────────────────
    //
    // `gapBegan` is host time at the moment media stopped arriving, and it is the
    // only honest ruler for "how long was the far end without us". Printed when
    // media returns, because a rig -- and a person -- both need the number, and
    // the two ends of a call cannot each measure their own half of it.
    var gapBegan: UInt64 = 0
    var announcedHold = false
    while true {
      // RE-ARMED WITH THE LOCK, not counted once for the life of the process.
      // Left running, `sinceLocked > 4` was permanently true after the first
      // rediscovery, so the "we have not heard their status yet" deadline was
      // already expired at the first tick of every subsequent lock -- and that
      // deadline fails OPEN, towards "treat them as answered".
      // ── THE GAP, MEASURED FROM TWO PACKET STAMPS ─────────────────────────────
      //
      // Checked HERE, at the top, before anything about locks or status bytes --
      // and computed as the difference between the LAST packet before the silence
      // and the FIRST one after it, never from the moment this loop happened to
      // notice. The first version reported when the poll loop declared the peer
      // connected, which waits on a half-second tick AND on a status byte
      // arriving from a peer that has just re-keyed: it turned a one-second
      // recovery into a four-second one in the log while media had been flowing
      // the whole time. A ruler has to measure the thing it is named after, and
      // both stamps are already recorded, so the honest number is free.
      if wire.peerBackAt != 0 {
        let ms = Int(Clock.msSigned(wire.peerBackAt, wire.peerGoneAt))
        wire.peerBackAt = 0; wire.peerGoneAt = 0
        Metrics.mark("rejoin_gap_ms", ms)
        Metrics.count("rejoins_seen")
        fputs("room \(room): they are back -- media gap \(ms) ms\n", stderr)
        gapBegan = 0
        announcedHold = false
        peerHeld = false
        display?.controls?.setHolding(false)
        display?.controls?.setStatus("connected")
      }
      if !wire.locked { lockedAt = Date.distantFuture }
      if wire.locked {
        if lockedAt == Date.distantFuture { lockedAt = Date() }
        // ── LOCKED IS NOT ANSWERED ANY MORE ─────────────────────────────────
        //
        // A Mac that is only being ASKED joins the room and punches a hole, so
        // that the person can see who is calling. Packets therefore arrive from
        // somebody who has decided nothing, and every line below this used to
        // read that as "they are here": the card came down, the status said
        // connected, and the call had begun without anybody agreeing to it.
        //
        // So this waits for one word from them. `peerStatusSeen` is the word;
        // `ST_RINGING` is what it says. The deadline exists because a build older
        // than the bit never sends one -- and those never joined before answering
        // either, so treating their silence as "answered" after two seconds is
        // both safe and the old behaviour.
        // TWENTY TICKS, TEN SECONDS. The deadline exists only for a build that
        // predates the status BYTE -- not the ringing bit, the byte, which has
        // shipped for a long time -- so it should almost never decide anything.
        // At five ticks a lossy link that dropped time probes for two and a half
        // seconds would have declared a ringing phone answered, which is an
        // absolute threshold deciding a safety property: exactly the shape this
        // project keeps finding (see RTT-blind timeouts).
        let heard = wire.peerStatusSeen || Date().timeIntervalSince(lockedAt) > 10
        if heard, wire.peerRinging {
          if announcedFor != "ringing" {
            announcedFor = "ringing"
            fputs("room \(room): they are being asked -- not connected yet\n", stderr)
            Metrics.count("peer_ringing_seen")
          }
        } else if heard, announcedFor != wire.lockedFrom {
          announcedFor = wire.lockedFrom
          wire.markPeerFresh()
          Metrics.mark("connected_ms", sinceLaunch())
          Metrics.count("connects")
          // NOT for a ring nobody has answered. Booked here, above the split,
          // every ring on every Mac reported `outcome: talked` and one more
          // `connects` -- so the answer rate and the connection rate on the
          // dashboard this release builds would both have been unusable, and a
          // call nobody took would read as "they talked".
          // ONE FIELD THAT SAYS HOW THIS CALL WENT, and it is set from both ends
          // rather than from the caller's card: the callee's own copy never draws
          // a calling card at all, so an outcome written there would have left
          // every answered call looking like nothing happened. Last writer wins,
          // which is what makes "calling" -> "talked" the ordinary story.
          Metrics.fact("outcome", "talked")
          Metrics.fact("path", wire.lockedFrom.hasPrefix("relay") ? "relay" : "direct")
          // WITH THE LAUNCH CLOCK ON IT. `connected_ms` has been marked here for a
          // while and only ever left in a telemetry beat, so the number that says
          // how long this Mac took to get into a call was invisible to anybody
          // running the app -- and rejoining is a launch-to-media budget in
          // exactly the same way a first join is. Printing it is what makes it
          // possible to say where the time went instead of guessing.
          fputs("room \(room): connected via \(wire.lockedFrom) at \(sinceLaunch()) ms\n", stderr)
          // ── AND THE PERSON WE CALLED GOES IN THE LIST ──────────────────────
          //
          // The mirror of the answer path, which writes a contact down the moment
          // somebody presses answer. `remember` had exactly one call site and it
          // was that one, so this app recorded a person only when THEY rang YOU:
          // place the call yourself and nobody was written down, and two people
          // who met on a link never recorded each other at all. The People panel
          // promised "call someone once and they'll show up here" over a list
          // that could only ever fill up for the person who never calls.
          //
          // ── WHY HERE AND NOT WHEN THE RING WAS SENT ───────────────────────
          //
          // The answer path binds on ANSWER rather than on arrival "because
          // binding a name to a key when the ring merely turns up would let
          // whoever rings first own the name". The caller's version of that
          // question is different, because the caller TYPED the name -- nobody
          // can claim it out from under them. What the caller can get wrong is
          // whether the call happened at all: a mistyped handle that happens to
          // exist, or a person who never picks up, would land in the panel for
          // ever after one dial that went nowhere. So the equivalent safe moment
          // is not "we sent the ring" (a 200 only means it reached a mailbox) but
          // THIS line -- the far end is locked, and `heard && !wire.peerRinging`
          // above says the far end has told us it is not merely being asked. That
          // is a person on the other end, which is what "someone you have called"
          // is supposed to mean.
          //
          // ── AND A NAME, NEVER A KEY ────────────────────────────────────────
          //
          // `rememberCalled` writes to `called.json` and cannot reach
          // `contacts.json`. There is no key to write: the doorbell hands the
          // caller nothing back, and the key on this very socket is an ephemeral
          // X25519 one that nobody signed. Writing that key here would seed
          // `known` -- the flag that opens a socket to a caller BEFORE anybody
          // agrees to talk to them -- off a value a man in the middle picks. A
          // name is what we honestly have, so a name is what gets stored.
          //
          // ── AND IT SURVIVES THE RE-EXEC BY NOT RACING IT ──────────────────
          //
          // `Launcher.reexec` is `execv`; it replaces this image on the next
          // line, and a background thread writing the contact file when that
          // happens is killed mid-write. Placing a call re-execs -- which is why
          // nothing is written before it. The name is carried across in argv as
          // `--calling`, and this line runs in the SUCCESSOR image, where every
          // `reexec` call site is already behind us (gui prompt, url, call
          // placed, ring answered all run before the rendezvous). The write is
          // synchronous on this thread for the same reason the answer path's is.
          //
          // `gCalling` is set from `--calling` and nothing else, and the only
          // thing that passes `--calling` is the re-exec after the server
          // accepted our signed ring. A link-joined call has no `gCalling`, so it
          // writes nobody -- see below.
          if let c = gCalling, !c.who.isEmpty { Identity.rememberCalled(c.who) }
          // ── TWO PEOPLE WHO MET ON A LINK RECORD NOTHING, ON PURPOSE ───────
          //
          // Asked directly: should an hour on a link mean you can call each other
          // by name afterwards? No, and not because it would be unsafe to want it
          // -- because there is no name. A room code is a CAPABILITY, not an
          // identity: `Rendezvous.exchange` sends `me=mac-<pid>` and gets back IP
          // addresses, the media handshake carries an unsigned ephemeral key and
          // "no identity, no room code, nothing that is worth anything to a
          // listener", and neither end ever utters a handle. Whoever holds the
          // link joined; the app never learned who that is.
          //
          // So the choice is not between recording them and not recording them.
          // It is between recording nothing and INVENTING an identity for a
          // stranger -- and an entry in the People panel is a promise that
          // tapping it reaches that person. There is nothing to tap here. The
          // honest fix for link-joined calls is for one of them to ring the other
          // by name once, which is a thing they can already do and which lands in
          // exactly the two files above.
          //
          // Deliberately silent rather than a log line: a link call is the
          // ordinary case, and "recorded nobody" is not news every time.
          // ── THE CALL BECOMES A FACT ON DISK, HERE AND NOWHERE EARLIER ────────
          //
          // At the LOCK, not at launch. A process that never found anybody was
          // never in a call, and a record written hopefully at startup would send
          // the next launch straight into an empty room with the camera on.
          //
          // Not for a ring preview either: that image is showing a card, and a
          // record written there would make a ring somebody declined into a call
          // that reopens itself.
          if !ringPreview {
            Resume.begin(room: room, port: Int(listenPort), peer: peerSpec,
                         video: videoArg, who: arg("calling") ?? arg("incoming") ?? "",
                         call: Telemetry.call, path: wire.lockedFrom)
          }
          // ── AND THE GAP, IF THIS LOCK IS A RETURN ───────────────────────────
          //
          // Measured on the side that STAYED, which is the only side that can
          // measure it: the returning process has no idea how long it was away
          // from the far end's point of view, and its own launch clock starts
          // after the silence began. One number, printed once, in the plainest
          // form a rig can grep for.
          // ── NOT `if sawRemote`. THE LOCK IS THE ARRIVAL. ──────────────────
          //
          // A locked transport with packets flowing IS the other person being
          // here; their camera is a separate question, answered by the "their
          // camera is off" banner that `setPaused` already draws. Gating this on
          // video is what left a camera-off peer permanently invisible.
          // Only a real call. `peerHere` arms the departure detector, and on a
          // ring preview that meant: caller goes quiet for three seconds ->
          // `setPeerPresent(false)` -> `clearIncoming()` -> mode back to invite,
          // which hides the answer and decline buttons while the ringtone is
          // still going. A phone ringing with nothing to press.
          if !ringPreview {
            // ── ON EVERY CALL ──────────────────────────────────────────────
            //
            // The moment somebody is actually on the other end. Asked for, and
            // it is the moment a stale build matters most: two Macs in one
            // conversation running different versions is where every difference
            // between them turns into a bug report that cannot be reproduced.
            //
            // Not a demand to restart. `callIsLive()` is true from here, so the
            // poller holds anything it finds until the call ends and says so on
            // screen -- which is the behaviour that already existed for a mid-call
            // discovery. Only a peer on a DIFFERENT WIRE FORMAT may interrupt a
            // conversation, and that is `wireMismatch`, decided elsewhere.
            if !peerHere { Update.checkNow("a call started") }
            peerHere = true
          }
          // Their picture, if any, takes the window; yours stops filling it.
          // Idempotent -- the first-frame path below does the same thing, and
          // whichever happens first is right.
          display?.selfViewOn = true
          // ── THE HALF A RING GETS, AND THE HALF IT MUST NOT ──────────────────
          //
          // This copy is showing somebody a card that asks whether they want to
          // talk. Their caller's picture arriving is the whole point -- and every
          // line below would then take the card away, put "connected" in the
          // status, and title the window as a call in progress. That is the
          // 0.61.0 bug rebuilt out of the feature that needed the socket.
          //
          // So a ring gets the picture and nothing else. The card stays, the
          // buttons stay, and the only thing that can change any of it is a
          // person pressing one.
          // The mirror is flushed a moment later, not here -- see `sinceLock`
          // below. Clearing at the lock blanks the window on a HEALTHY call for
          // however long their first frame takes, which is a flicker introduced
          // to fix a still.
          sinceLock = 0
          if ringPreview {
            setWindowTitle("Kin — \(Identity.display(arg("incoming") ?? "someone")) is calling")
            // What just happened is a LOCK, not a frame. This counted
            // `ring_preview_picture` right here and printed that their picture
            // was on the card -- at a point a caller running `--video off`
            // reaches identically. So the counter meant "a ring found its
            // socket", the dashboard rendered it as "the caller's video reached
            // the ring card", and a rig asserting on that log line passed on a
            // ring with no picture in it whatsoever. A picture is counted where
            // a picture exists: `vdec.onDecoded`, further down this file.
            Metrics.count("ring_preview_open")
            Metrics.mark("ring_preview_ms", sinceLaunch())
            // NOT `continue`. The sleep that paces this whole loop is at the
            // bottom of it, and skipping to the top would turn a half-second poll
            // into a spin -- on the one image whose entire promise is that it
            // costs a Mac nothing while it waits to be answered.
            fputs("room \(room): the ring card reached them"
                + " -- their picture will follow, still nobody's decision\n", stderr)
          } else {
          display?.controls?.markConnected()
          setWindowTitle("Kin — connected")
          display?.controls?.setStatus(gMicMuted ? "you are muted" : "connected")
          // The other half of the door. `markConnected` fires once per process,
          // so if the waiting card came back on a departure, this is the only
          // thing that can take it away again -- otherwise it would sit on top of
          // the returning peer for the rest of the call, which is a worse fault
          // than the one it was added to fix.
          display?.controls?.setPeerPresent(true)
          }
          gone = 0
        }
        // ── AND THE MIRROR, ONCE IT IS CLEAR THEY HAVE NO PICTURE ────────────
        //
        // `selfViewOn` stops NEW frames of you filling the window; the last one
        // stays on it. On a call where they arrive without a camera, that frozen
        // frame is all there is -- under a banner reading "their camera is off",
        // so it reads as THEM, stopped. This app has a whole document about why a
        // frozen face is the worst thing to show; this was one of the wrong
        // person.
        //
        // One tick of grace (0.5 s) rather than clearing at the lock, because on
        // a healthy call their first frame is moments away and blanking the
        // window until it lands trades a still for a flicker.
        if sinceLock >= 0 { sinceLock += 1 }
        if sinceLock >= 1, !sawRemote, !pictureCleared {
          pictureCleared = true
          display?.clearPicture()
          // Said out loud so a rig can see it. A blanked window and a window that
          // was never painted look identical from outside.
          fputs("  picture: nothing from them yet -- clearing the mirror\n", stderr)
        }
        // SILENCE IS THE SIGNAL. Three seconds with nothing arriving means the
        // address we locked onto has stopped being true -- a new NAT port, a
        // different access point, a DHCP renewal, a lid closed and reopened. The
        // old code locked once and could never reconsider, so any of those ended
        // the call permanently and silently.
        if wire.lastFromPeer != 0, Clock.msSigned(Clock.now(), wire.lastFromPeer) > 3000 {
          Metrics.count("rediscoveries")
          fputs("room \(room): nothing from \(wire.lockedFrom) for 3 s -- looking again\n", stderr)
          // The gap started when the last packet arrived, NOT when this branch
          // noticed. Three seconds of the silence had already happened by the time
          // the detector fired, and a ruler that starts at the alarm rather than at
          // the event under-reports by exactly its own threshold.
          if gapBegan == 0 { gapBegan = wire.lastFromPeer }
          wire.unlockForRediscovery()
          announcedFor = ""
          // ── SAY SOMETHING ─────────────────────────────────────────────────
          //
          // This detector has re-found a moved peer since it was written, and never
          // once told the person watching. What they see is a frozen face with the
          // call timer still counting -- which looks exactly like the app having
          // died, so they close the window and blame it. The web app has said
          // "reconnecting…" for this the whole time.
          //
          // AND SAID OUT LOUD, not only drawn. A status pill exists only when
          // there is a window, so every headless run -- which is most of the rigs
          // in tools/ -- could not tell "the app decided to say reconnecting" from
          // "the app said nothing at all". Same reason the mirror-clearing line
          // above it prints.
          fputs("  telling them: reconnecting\n", stderr)
          display?.controls?.setStatus("reconnecting…")
          gone = 0
        }
        Thread.sleep(forTimeInterval: 0.5)
        continue
      }
      // Unlocked: refresh the directory as well as probing, because if the peer
      // moved, its old address is exactly the one we would otherwise keep trying.
      let answer = Rendezvous.exchange(room: room, me: me, addr: mine, local: myLocal, relay: relay.get())
      let peers = answer ?? []
      // ── A BLIP AND A DEPARTURE ARE NOT THE SAME THING ────────────────────
      //
      // From the media side they are identical: silence. From the DIRECTORY they
      // are not -- a peer that has left stops republishing its address. Waiting for
      // the room to evict them takes 90 s (worker.ts: "short enough that a stale
      // mapping is never offered as a live one"), which is far too long to leave a
      // frozen face over a running clock. But every entry carries `ageMs`, the time
      // since that peer last said it was there, so the answer arrives in seconds
      // and needs no change to the protocol.
      func addAll(_ p: Rendezvous.Peer) {
        wire.addCandidate(ip: p.ip, port: p.port)
        if let lip = p.localIP, let lport = p.localPort { wire.addCandidate(ip: lip, port: lport) }
        if let rip = p.relayIP, let rport = p.relayPort { wire.addCandidate(ip: rip, port: rport) }
      }
      if let p = peers.first, p.ageMs < 4000 {
        gone = 0
        addAll(p)
      } else if peerHere {
        // `sawRemote` here too, once, and with the same consequence in reverse:
        // a camera-off peer could not be detected leaving either, so the call sat
        // on a dead line saying "connected" forever.
        gone += 1
        // ── AND NOW: GONE QUIET IS NOT GONE ──────────────────────────────────
        //
        // Every line below used to fire at two seconds of silence: "the other
        // person left", the waiting card back over their frozen face, presence
        // off. That is right for somebody who hung up and wrong for the four
        // things that look identical from here -- an update re-exec, a crash, a
        // force-quit, a closed lid -- and only one of those is a decision.
        //
        // A person who hangs up now SAYS so, on the media socket
        // (`Wire.sendGoodbye`), and that goodbye ends the call at both ends
        // immediately. So silence is no longer evidence of anything except
        // silence, and while a call record is open this end HOLDS: the timer
        // keeps running, the picture stays, the invite card does not come back
        // (a card reading "waiting for the other person" over a call that is
        // paused is what makes a return feel like a brand new call), and the
        // probes keep going out for as long as it takes.
        //
        // The one thing that DOES end the hold without a goodbye is the room
        // forgetting them. `answer == nil` means this Mac could not ask, which is
        // not a fact about them (`blind-instruments-report-negatives`), so only a
        // real answer with an empty list counts -- and an empty list means the
        // 90 s lease expired with nobody republishing. A restarting process
        // republishes within about a second, hundreds of times inside that
        // window, which is what makes the two ends agree without two timeouts.
        let holding = Resume.holding
        if holding, gone >= 4 {
          if !announcedHold {
            announcedHold = true
            let who = arg("calling") ?? arg("incoming") ?? ""
            let name = who.isEmpty ? "They" : Identity.display(who)
            Metrics.count("peer_held")
            fputs("room \(room): \(name.lowercased()) went quiet without hanging up"
                + " -- holding the call open\n", stderr)
            display?.controls?.setStatus("\(name)\u{2019}ll be right back\u{2026}")
            // Everything that DESCRIBES them has to stop here too -- see the
            // report loop. Holding the call open is not the same as having
            // somebody to measure.
            peerHeld = true
            display?.controls?.setHolding(true)
          }
          // The room has forgotten them: 90 s with nobody publishing. That is the
          // shared fact both ends read, and it is the bound on the hold.
          if let a = answer, a.isEmpty,
             wire.lastFromPeer != 0,
             Clock.msSigned(Clock.now(), wire.lastFromPeer) > Double(Resume.roomLeaseMs) {
            fputs("room \(room): nobody has been in \(room) for \(Resume.roomLeaseMs / 1000) s"
                + " -- treating that as gone\n", stderr)
            Resume.end(why: "the room lease expired with nobody in it")
            Metrics.count("peer_left")
            peerHeld = false
            display?.controls?.setHolding(false)
            display?.controls?.setStatus("the other person left")
            display?.controls?.setPeerPresent(false)
            peerHere = false
            sinceLock = -1
            pictureCleared = false
            announcedHold = false
          }
        } else if !holding, gone == 4 {
          let why = peers.isEmpty ? "not in the room" : "silent for \(peers[0].ageMs / 1000)s"
          fputs("room \(room): peer is \(why) -- telling the window\n", stderr)
          display?.controls?.setStatus("the other person left")
          // And bring the waiting screen back. Saying "the other person left" over
          // their last frozen frame, with no link and nothing to press, describes
          // the situation and offers nothing about it. This screen already has the
          // invite link and both ways to copy it, and it is now the ONLY place that
          // does -- the sheet's invite row was removed because this exists.
          Metrics.count("peer_left")
          display?.controls?.setPeerPresent(false)
          // Presence is OFF now, and everything downstream reads it: the report
          // loop stops publishing peer-derived readouts, and a peer who comes
          // back gets the same first-frame grace they got the first time.
          peerHere = false
          sinceLock = -1
          pictureCleared = false
        }
        // Keep probing anyway: a peer that comes BACK republishes, and the status
        // is a report, not a decision to stop trying.
        if let p = peers.first { addAll(p) }
      }
      wire.probeAllCandidates()
      Thread.sleep(forTimeInterval: 0.5)
    }
  }.start()

  Thread {
    while true {
      Thread.sleep(forTimeInterval: 20)
      let peers = Rendezvous.exchange(room: room, me: me, addr: mine, local: myLocal, relay: relay.get()) ?? []
      // Only worth acting on while unresolved. Once a packet has arrived, the
      // address it came from is better evidence than anything the rendezvous can
      // tell us -- and re-pointing a working call at a directory entry is how a
      // live call gets broken by bookkeeping.
      if let p = peers.first, !wire.locked {
        wire.addCandidate(ip: p.ip, port: p.port)
        if let lip = p.localIP, let lport = p.localPort { wire.addCandidate(ip: lip, port: lport) }
        if let rip = p.relayIP, let rport = p.relayPort { wire.addCandidate(ip: rip, port: rport) }
      }
    }
  }.start()
}

var keyAsksOnLoss = 0
/// Inbound keyframe requests. Every one of these is the far end saying "I lost
/// video from you" -- a video-derived, OUTBOUND-direction harm signal that was
/// already arriving and being thrown away. Counted first and steered on later:
/// attribute before acting.
var keyAsksIn = 0
var gDumpedMetal = false
var gDecLuma: Double = -1
/// Width of the last picture DECODED from the far end. Not what we asked them
/// for -- what actually arrived, which is the only number that can answer "why
/// does their video look soft". One Int, written from the decode callback.
nonisolated(unsafe) var gRxWidth = 0
nonisolated(unsafe) var gRxHeight = 0
var gDecLumaTick = 0

// ── BLOCKINESS, MEASURED ON THE PICTURE A PERSON IS LOOKING AT ───────────────
//
// The first attempt at this counted frames whose bits-per-pixel fell below a
// threshold while the scene moved. It failed its own calibration immediately: at
// the FULL 3 Mbps it called 23 of 30 moving frames blocky, because a talking head
// is cheap to encode and a low bitrate on easy content is not damage. Bits are
// not quality. That version is gone.
//
// The SECOND attempt measured steps on the 8-pixel block grid against steps
// everywhere else. It also failed calibration, and backwards: at quality 0.9 it
// reported 1.356 and flagged 42 of 49 samples, and at quality 0.05 -- a picture
// visibly destroyed, 702 bytes a frame against 8994 -- it reported 1.155 and
// flagged NONE. Two reasons, both fundamental: H.264 runs an in-loop deblocking
// filter whose entire job is to erase that signature, and a picture starved of
// bits goes SMOOTH, so edge and interior gradients collapse together and the
// ratio walks back towards 1. The ratio is still reported, because it is nearly
// free, but nothing is allowed to conclude anything from it.
//
// What ranked correctly is the absolute amount of detail left in the decoded
// picture. Bits buy detail; when they run out, detail is what goes. Paired with
// how much the picture was MOVING, that separates "a still, plain scene" -- which
// is legitimately low-detail and looks perfect -- from "a moving scene being
// scrubbed flat", which is the complaint.
//
// Measured where the complaint is -- on the DECODED far-end picture -- because
// "his picture goes blocky" is a statement about what arrived, and the sender's
// own numbers cannot see the network that came after them.
var gDecMotion: Double = -1
nonisolated(unsafe) var gDecPrev = [UInt8](repeating: 0, count: 4096)
nonisolated(unsafe) var gDecCur = [UInt8](repeating: 0, count: 4096)
var gDecPrevN = 0
var gThetaMs: Double = 0
var gThetaValid = false
/// Put this Mac's speaker back on after the room detector turned it off, and
/// return whether it is on now. Declared HERE and assigned once `audio` exists:
/// `pressControl` is defined a thousand lines above and only ever RUNS from a
/// timer, but a global assigned above its own declaration is silently undone by
/// the declaration's initialiser (`top-level-code-runs-in-order`).
// TK_MUTE=1 in the environment silences playout as surely as --mute does.
// This exists because a flag you have to remember on every one of forty test
// commands is a flag you will forget on the forty-first, and here the cost of
// forgetting is landing on someone's speakers while they are asleep. An exported
// variable is remembered once.
// MICROPHONE PERMISSION: REPORTED HERE, ASKED FOR MUCH EARLIER.
//
// A denied microphone produces "cap 0/s" and nothing else -- identical to a
// muted mic, a wrong default device, or a bug in this code. That ambiguity has
// already cost me a whole false root cause once in this project, so the state is
// still named out loud, right where the audio devices are about to be opened.
//
// What is NOT here any more is the request itself, or the 60-second semaphore
// that used to wait for it on the main thread. Both moved up above the
// rendezvous: this line sits below a block that can `exit(1)`, so on a solo
// launch it never ran at all and the microphone was never asked for. Reading the
// status is free and cannot block; the answer may still be in flight, and
// `notDetermined` here means "the dialog above is still on screen", which is not
// an error.
//
// A command-line tool has no bundle, so macOS attributes the grant to the
// terminal that launched it -- which is why this names the terminal app and not
// "tk".
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
  break
case .notDetermined:
  fputs("microphone: still waiting on the permission dialog -- answer it and this\n"
      + "  end starts sending. Nothing here blocks on it.\n", stderr)
case .denied, .restricted:
  // ── AND NAME THE RIGHT APP ────────────────────────────────────────────────
  //
  // This used to say "enable the app you launched this from (Terminal, iTerm, VS
  // Code...)". True of the bare CLI binary, whose grant TCC attributes to the
  // terminal above it -- and reached from inside Kin.app too, where it is advice
  // that sends somebody to switch on a text editor to fix their microphone. The
  // bundle has owned its own grant since it became a bundle; the message had not
  // noticed. It now names whichever is actually true, and carries the URL that
  // opens the pane rather than a path through three menus.
  fputs("microphone: DENIED. You will hear the other person and they will hear silence.\n"
      + "  Switch on \(Bundle.main.bundleIdentifier == nil ? "the app you launched this from (Terminal, iTerm, VS Code...)" : "Kin")"
      + " under System Settings > Privacy & Security > Microphone.\n"
      + "  One click: tk --permissions-open microphone\n", stderr)
@unknown default:
  break
}

// --no-fec exists so redundancy can be A/B'd against itself. A feature that
// cannot be turned off cannot be measured, and this one costs bandwidth.
let fecAllowed = !flag("no-fec")
// --acoustic measures the real speaker->air->mic path, which is the only thing
// that can settle whether the device-latency terms are already inside the
// timestamps we add them to (17.89). It has to make a sound.
// Must be set before the units are built: the buffer size is a device property.
// `--io hal` is the control arm: the old two-unit raw-hardware path, no echo
// cancellation, exactly as every call before this shipped.
if flag("no-agc") { Audio.agcOn = false }
if flag("no-auto-gain") { Audio.autoGain = false }
if flag("gain-debug") { Audio.gainDebug = true }

// HOW FAR AWAY THE OTHER PERSON SOUNDS. Distance is monaural -- level, the
// direct-to-reverberant ratio and spectrum -- so unlike direction it arrives
// intact on a laptop speaker, which is where most calls are actually heard.
// Costs nothing to send (it runs on the receiving end of a stream already on the
// wire) and nothing in latency (reflections are late by definition; the direct
// sound is untouched).
// Both of these pin what the route would otherwise decide, which is what makes
// an A/B possible: --no-gate is full duplex on speakers, --force-gate is one at
// a time on headphones.
// ── DOES THE LEDGER ACTUALLY EVEN THINGS OUT? ─────────────────────────────
//
// The failure it exists to prevent is one person going second every single time,
// so the test is not "does the number move" -- it is whether somebody who keeps
// losing coin-flips ends up owed a turn, and whether an even conversation stays
// neutral instead of drifting. Both matter: a ledger that nudges during a
// balanced conversation is worse than none at all.
// ── HOW MUCH OF THE OTHER PERSON IS LEFT FOR THE RECOGNISER TO READ? ──────
//
// The muted person's microphone hears both of them, and the whole point is that
// their subtitles must contain their words and not the other person's. So the
// measure is the near-to-far ratio the recogniser is handed, against the one it
// would have been handed raw.
//
// Both halves are measured through the SAME per-band gains the mixture produced.
// Cleaning the near voice alone and the echo alone would let the filter adapt to
// a different signal in each run and score itself on two passes that never
// happened -- flattering by construction.
if flag("subtitle-test") {
  let sr = 16000.0
  var seed: UInt64 = 0xBEEF
  func rnd() -> Float {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Float(Int32(truncatingIfNeeded: Int(seed >> 33))) / Float(Int32.max)
  }
  func voiceLike(_ n: Int, _ rate: Double, _ amp: Float) -> [Float] {
    // Amplitude-modulated, band-limited noise: syllable structure, formant-ish
    // tilt, and no two of them alike.
    var x = (0..<n).map { i -> Float in
      rnd() * amp * Float(0.5 + 0.5 * sin(2 * Double.pi * rate * Double(i) / sr))
    }
    var lp: Float = 0
    for i in 0..<n { lp = 0.72 * lp + 0.28 * x[i]; x[i] = x[i] - lp * 0.6 }
    return x
  }
  let n = Int(sr * 6)
  let near = voiceLike(n, 3.9, 0.30)
  let far  = voiceLike(n, 2.7, 0.55)
  // The echo: delayed, and coloured, because a laptop speaker and its microphone
  // are not flat. A test with a flat echo path is a test of the easy case.
  let d = Int(sr * 0.012)
  var echo = [Float](repeating: 0, count: n)
  var lp: Float = 0
  for i in d..<n { lp = 0.55 * lp + 0.45 * far[i - d]; echo[i] = lp * 0.45 + far[i - d] * 0.12 }
  let mic = (0..<n).map { near[$0] + echo[$0] }

  func rms(_ x: [Float]) -> Double {
    var a = 0.0; for v in x { a += Double(v) * Double(v) }
    return (a / Double(max(1, x.count))).squareRoot()
  }
  let inRatio = 20 * log10(rms(near) / max(rms(echo), 1e-12))

  let c = Audio.SubtitleCleaner()
  if let v = arg("sub-over"), let f = Float(v) { c.over = f }
  if let v = arg("sub-floor"), let f = Float(v) { c.floorFrac = f }
  _ = c.clean(mic: mic, ref: far)                       // let it learn the path
  let c2 = Audio.SubtitleCleaner()
  if let v = arg("sub-over"), let f = Float(v) { c2.over = f }
  if let v = arg("sub-floor"), let f = Float(v) { c2.floorFrac = f }
  let keptNear = c2.clean(mic: mic, ref: far, probe: near)
  let c3 = Audio.SubtitleCleaner()
  if let v = arg("sub-over"), let f = Float(v) { c3.over = f }
  if let v = arg("sub-floor"), let f = Float(v) { c3.floorFrac = f }
  let keptEcho = c3.clean(mic: mic, ref: far, probe: echo)
  let outRatio = 20 * log10(rms(keptNear) / max(rms(keptEcho), 1e-12))
  let nearLoss = 20 * log10(rms(keptNear) / max(rms(near), 1e-12))

  print(String(format: "  the microphone hands over the near voice %+.1f dB above the other person", inRatio))
  print(String(format: "  after cleaning, %+.1f dB above -- %+.1f dB better for the recogniser",
               outRatio, outRatio - inRatio))
  print(String(format: "  the near voice itself lost %.1f dB (it may sound bad; nobody hears it)", -nearLoss))
  let ok = outRatio - inRatio > 12 && nearLoss > -8
  print(ok ? "  SUBTITLE TEST PASSED -- the other person's voice is pushed down far enough to read past"
           : "  SUBTITLE TEST FAILED"
             + (outRatio - inRatio > 12 ? " (it ate the near voice too)" : " (not enough separation)"))
  exit(ok ? 0 : 1)
}

// ── CAN WE TELL A TURN IS ENDING BEFORE IT ENDS? ──────────────────────────
//
// The whole argument, the labels and the control arms live in Predict.swift; this
// is only the door. It opens a recogniser and no device, which is why it sits
// with the other `--*-test` blocks rather than anywhere near a call.
if flag("predict-test") {
  let media = arg("predict-wav") ?? "testbed/media/real/realA.wav,testbed/media/real/realB.wav"
  Predict.selfTest(paths: media.split(separator: ",").map(String.init),
                   seconds: Double(arg("predict-seconds") ?? "600") ?? 600,
                   useModel: flag("predict-model"),
                   useCase: arg("predict-usecase") ?? "general",
                   budget: Double(arg("predict-budget") ?? "0.15") ?? 0.15,
                   fast: flag("predict-fast"))
}

if flag("ledger-test") {
  var l = Audio.Ledger()
  var bad = false
  func show(_ what: String, _ v: Double, _ want: String, _ ok: Bool) {
    print(String(format: "  %@ nudge %+.2f  (want %@)  %@",
                 what.padding(toLength: 34, withPad: " ", startingAt: 0), v, want, ok ? "ok" : "WRONG"))
    if !ok { bad = true }
  }
  // An even conversation must not nudge anybody.
  for i in 0..<20 { l.won(byMe: i % 2 == 0) }
  show("taking turns fairly", l.owed, "near 0", abs(l.owed) < 0.35)

  // One side taking every contested start must end up clearly owing.
  l = Audio.Ledger()
  for _ in 0..<8 { l.won(byMe: true) }
  show("you took eight in a row", l.owed, "strongly +", l.owed > 0.7)
  // 0.6, not 0.7: the swept value lands at 0.70 and a bar sitting exactly on it
  // passes by a rounding digit, which is not a test.
  show("... so you are nudged to yield", l.owed, "> 0.6", l.yieldNudgeFor > 0.6)

  // And it must forgive: yielding a few times clears the debt, or the nudge
  // becomes a permanent handicap rather than a correction.
  for _ in 0..<4 { l.won(byMe: false) }
  // ABSOLUTE VALUE, NOT LESS-THAN. The first version of this line asked only
  // that the number came DOWN, and +0.93 swinging to -0.48 passed it -- a
  // correction that overshoots into owing the other person just as much, which
  // in a real conversation is a nudge that oscillates instead of settling.
  show("then yielded four", l.owed, "back near 0 EITHER WAY", abs(l.owed) < 0.3)

  // The far end's ledger is the mirror of ours, or the two ends nudge the same
  // person and the conversation locks up.
  var a = Audio.Ledger(), b = Audio.Ledger()
  for i in 0..<10 { let mine = i % 3 == 0; a.won(byMe: mine); b.won(byMe: !mine) }
  show("two ends see the mirror image", a.owed + b.owed, "sums to 0", abs(a.owed + b.owed) < 0.001)

  print(bad ? "  LEDGER TEST FAILED" : "  LEDGER TEST PASSED -- it corrects a lopsided conversation and leaves an even one alone")
  exit(bad ? 1 : 0)
}

// ── THE CUES, WHICH ONLY EVER EXIST WHILE MOVING ────────────────────────────
//
// A photograph proves a cue was drawn. It cannot prove that it ARRIVES in time,
// that it goes away, that the ledger changes anything, or that a caption's last
// line is not being clipped off the bottom of its own field -- and that last one
// shipped, looked exactly like a bug in the string fitting, and was found by
// reading a debug line rather than by looking at the screen.
//
// So the parts that move are asserted here, at a fixed frame time, and the parts
// that are drawn are photographed by the shoot rig. Neither one covers the other.
if flag("cue-test") {
  var bad = false
  func show(_ what: String, _ got: String, _ want: String, _ ok: Bool) {
    print("  \(what.padding(toLength: 40, withPad: " ", startingAt: 0)) \(got.padding(toLength: 22, withPad: " ", startingAt: 0)) (want \(want))  \(ok ? "ok" : "WRONG")")
    if !ok { bad = true }
  }
  func ms(_ v: CGFloat?) -> String { v.map { String(format: "%.0f ms", $0) } ?? "never" }

  // ── 1. A BID HAS TO LAND BEFORE THE FIRST SYLLABLE IS OVER ─────────────────
  //
  // A vowel is about 120 ms. A cue that takes longer than that to become
  // unmistakable arrives after you have already started talking over somebody,
  // which is the one thing it exists to prevent.
  let c = FloorCue(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
  c.vocal = 2
  let bid = c.timeTo(0.75)
  show("a bid becomes unmistakable", ms(bid), "<= 120 ms", (bid ?? 1e9) <= 120)

  // ── 2. A LISTENING NOISE MUST NOT ─────────────────────────────────────────
  //
  // Same organ, and it must stop well short of the bid's brightness or the two
  // are one signal with two names.
  let c2 = FloorCue(frame: c.frame)
  c2.vocal = 1
  _ = c2.timeTo(0.41)
  for _ in 0..<60 { c2.step(1.0 / 30) }
  show("a listening noise settles low", String(format: "%.2f", c2.level), "0.40-0.45",
       c2.level > 0.40 && c2.level < 0.45)

  // ── 3. THE LEDGER HAS TO DO SOMETHING ─────────────────────────────────────
  //
  // Somebody who is owed a turn gets a cue that arrives sooner and goes further.
  // If these two numbers are equal, the whole record-keeping is decoration.
  let c3 = FloorCue(frame: c.frame)
  c3.vocal = 2; c3.nudge = 1
  let owedT = c3.timeTo(0.75)
  show("owed a turn: the bid arrives sooner", ms(owedT), "< the \(ms(bid)) above",
       (owedT ?? 1e9) < (bid ?? 0))
  for _ in 0..<60 { c3.step(1.0 / 30) }
  show("... and goes further", String(format: "%.2f vs %.2f", c3.level, c.level),
       "higher", c3.level > c.level + 0.05)

  // ── 4. AND IT HAS TO LEAVE ────────────────────────────────────────────────
  //
  // Slower than it came, because a cue that snaps off reads as a glitch -- but
  // gone, because a cue that lingers stops meaning anything.
  //
  // Measured to "visibly gone" rather than to zero: the tail of an exponential
  // takes another second to reach nothing and nobody can see the difference. The
  // slow fall is deliberate -- a cue that snapped off at the first gap between
  // two words would flicker through every sentence.
  c.vocal = 0
  let gone = c.timeTo(0.05)
  show("and then it goes away", ms(gone), "300-1200 ms",
       (gone ?? 1e9) > 300 && (gone ?? 1e9) < 1200)

  // ── 5. THE LAST LINE OF A CAPTION IS NOT CLIPPED ──────────────────────────
  //
  // The regression: the two-line well was sized from `ascender - descender +
  // leading`, the text system lays out one point taller than that, and the
  // second line was cut off entirely. It read as truncation in the fitting code,
  // which was correct all along.
  let band = CaptionBand(frame: NSRect(x: 0, y: 0, width: 720, height: 200))
  band.theirText = "So the thing about a call is that you never really know whose "
                 + "turn it is, and that is the whole problem."
  band.refit(force: true)
  band.layoutSubtreeIfNeeded()
  show("a two-line caption is not clipped", String(format: "%+.0f pt", band.clippedBy),
       "<= 0", band.clippedBy <= 0)
  show("... and both lines are there", band.theirDrawn.hasSuffix("problem.") ? "ends correctly" : "TRUNCATED",
       "the whole sentence", band.theirDrawn.hasSuffix("problem."))

  // ── 6. A LONG ONE KEEPS ITS TAIL, NOT ITS HEAD ────────────────────────────
  //
  // The newest words are the ones somebody is trying to read. What falls off is
  // what fell off the front.
  let long = (1...40).map { "word\($0)" }.joined(separator: " ")
  band.theirText = long
  band.refit(force: true)
  band.layoutSubtreeIfNeeded()
  show("a long caption keeps its tail", band.theirDrawn.hasSuffix("word40") ? "ends at word40" : "lost the end",
       "the newest words", band.theirDrawn.hasSuffix("word40"))
  show("... and says it cut the front", band.theirDrawn.hasPrefix("…") ? "leading …" : "silently cut",
       "a leading …", band.theirDrawn.hasPrefix("…"))
  show("... and still fits two lines", String(format: "%+.0f pt", band.clippedBy), "<= 0",
       band.clippedBy <= 0)

  // ── 7. THE WHOLE LAYER STOPS ──────────────────────────────────────────────
  //
  // Thirty frames a second for the length of a call, drawing nothing, is the kind
  // of thing that shows up later as "the app makes my laptop hot".
  let cues = TurnCues(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
  cues.setFloor(peerVocal: 2, nudge: 0)
  cues.setTheirs("hello", final: true)
  cues.setListeningNoise("mm-hmm")
  show("it is running while there is something", cues.testTicking ? "ticking" : "stopped",
       "ticking", cues.testTicking)
  cues.setFloor(peerVocal: 0, nudge: 0)
  // ── THE HARNESS HAS TO LET REAL TIME PASS ─────────────────────────────────
  //
  // The eased values run on the `dt` this loop hands them, but the bloom's life
  // and the caption's expiry are wall-clock -- correctly, because they are about
  // how long a person has had to read something. Spinning two thousand fake
  // frames in a fifth of a second left the bloom still alive and reported a layer
  // that never stops. That was the instrument, not the code.
  Thread.sleep(forTimeInterval: 1.9)
  var spins = 0
  while cues.testTicking, spins < 2000 { cues.testTick(1.0 / 30); spins += 1 }
  show("and stops when there is not", cues.testTicking ? "STILL TICKING" : "stopped after \(spins) frames",
       "stopped", !cues.testTicking)

  print(bad ? "  CUE TEST FAILED"
            : "  CUE TEST PASSED -- the bid lands inside a syllable, the ledger moves it,"
              + " nothing is clipped, and the whole layer stops when the call goes quiet")
  exit(bad ? 1 : 0)
}

// ── DOES THE DEADLOCK RULE PICK ONE, AND ONLY WHEN IT SHOULD? ───────────────
//
// The rule is the one place in this app that acts on a person's audio because of
// a judgement about a conversation, so it is asserted clause by clause -- and the
// clause that matters most is the REFUSAL: an even conversation with two
// simultaneous starts must leave both people alone.
// ── THE RULER FOR THE THING THAT FEEDS THE RECOGNISER ───────────────────────
//
// A resampler is invisible: it produces audio that sounds fine and a transcript
// that is quietly worse. The filter this replaces was four cascaded one-poles,
// which is 24 dB per octave from about 3.5 kHz -- so it removed most of the
// energy in s, sh, f and t, the band a recogniser needs to tell them apart. It
// was doing that for months and nothing could see it, because every check was of
// the transcript and not of the signal.
//
// So the filter is measured directly, against a swept tone: flat where speech
// lives, gone before anything can fold back.
if flag("decimator-test") {
  var bad = false
  func show(_ what: String, _ got: String, _ want: String, _ ok: Bool) {
    print("  \(what.padding(toLength: 40, withPad: " ", startingAt: 0)) \(got.padding(toLength: 12, withPad: " ", startingAt: 0)) (want \(want))  \(ok ? "ok" : "WRONG")")
    if !bad { bad = !ok }
  }
  /// Level at the OUTPUT for a tone at `f` at the input, in dB relative to a
  /// tone at 300 Hz. Measured, not modelled: the same code the call runs.
  func level(_ f: Double) -> Double {
    let n = Int(SR * 0.6)
    var x = [Float](repeating: 0, count: n)
    for i in 0..<n { x[i] = Float(sin(2 * .pi * f * Double(i) / SR)) }
    let d = Decimator3()
    let y = x.withUnsafeBufferPointer { d.run($0.baseAddress!, n) }
    // Skip the filter's own fill, then RMS.
    let skip = min(y.count / 2, Decimator3.taps)
    var e = 0.0
    for i in skip..<y.count { e += Double(y[i]) * Double(y[i]) }
    return 10 * log10(e / Double(max(1, y.count - skip)) * 2)
  }
  let ref = level(300)
  func rel(_ f: Double) -> Double { level(f) - ref }
  // ── PASSBAND: SPEECH HAS TO COME THROUGH UNTOUCHED ────────────────────────
  for f in [300.0, 1000, 2000, 3000, 4000, 5000, 6000] {
    let d = rel(f)
    show("\(Int(f)) Hz passes", String(format: "%+.1f dB", d), "within 1.5 dB", abs(d) < 1.5)
  }
  // ── STOPBAND: NOTHING ABOVE 8 kHz MAY FOLD BACK ───────────────────────────
  for f in [9000.0, 11000, 14000, 20000] {
    let d = rel(f)
    show("\(Int(f)) Hz is gone", String(format: "%+.0f dB", d), "< -40 dB", d < -40)
  }
  // And the rate is actually a third.
  let n = Int(SR)
  let x = [Float](repeating: 0.1, count: n)
  let d = Decimator3()
  let y = x.withUnsafeBufferPointer { d.run($0.baseAddress!, n) }
  show("one second in, a third out", "\(y.count) samples", "16000", abs(y.count - 16000) <= 1)
  // Streaming across chunk boundaries must equal one big call, or every 120 ms
  // tick puts a click into the recogniser's input.
  var seed: UInt64 = 0x5EED
  func rnd() -> Float {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Float(Int32(truncatingIfNeeded: Int(seed >> 33))) / Float(Int32.max)
  }
  let src = (0..<(48000 * 2)).map { _ in rnd() }
  let whole = src.withUnsafeBufferPointer { Decimator3().run($0.baseAddress!, src.count) }
  let piece = Decimator3()
  var chunked: [Float] = []
  var i = 0
  while i < src.count {
    let take = min(5760, src.count - i)     // 120 ms
    src.withUnsafeBufferPointer { chunked += piece.run($0.baseAddress! + i, take) }
    i += take
  }
  var worst: Float = 0
  for k in 0..<min(whole.count, chunked.count) { worst = max(worst, abs(whole[k] - chunked[k])) }
  show("120 ms chunks == one long call", String(format: "%.2e", Double(worst)), "0",
       worst < 1e-6 && abs(whole.count - chunked.count) <= 1)

  print(bad ? "  DECIMATOR TEST FAILED"
            : "  DECIMATOR TEST PASSED -- speech passes flat, nothing above 8 kHz survives to fold"
              + " back, and a chunk boundary is not a discontinuity")
  exit(bad ? 1 : 0)
}

if flag("yield-test") {
  // BEFORE anything reads `Audio.gate`. See `applyGateFlags` for what ran the
  // wrong arm for how long.
  applyGateFlags()
  var bad = false
  func show(_ what: String, _ got: String, _ want: String, _ ok: Bool) {
    print("  \(what.padding(toLength: 46, withPad: " ", startingAt: 0)) \(got.padding(toLength: 14, withPad: " ", startingAt: 0)) (want \(want))  \(ok ? "ok" : "WRONG")")
    if !bad { bad = !ok }
  }
  // Was a hardcoded 450, which is the default -- so `--yield-after` moved the
  // duck's config and not the threshold these assertions actually exercise, and
  // half the arm was still the control. Reads the same 450 when nothing is
  // passed, and the line below now prints which number it used.
  func y(_ ms: Double, _ gap: Double?, _ owed: Double) -> Bool {
    Audio.Yield.shouldYield(collisionMs: ms, gapMs: gap, owed: owed,
                            afterMs: Audio.gate.yieldAfterMs)
  }
  func yn(_ b: Bool) -> String { b ? "ducks" : "left alone" }

  // THE NUMBER ON THE LINE. The defect above was invisible for exactly one
  // reason: a -9 run and a -12 run printed the same page. An arm that does not
  // state what it is cannot be caught being something else.
  print("  yield config: yieldDb=\(Audio.gate.yieldDb) yieldAfterMs=\(Audio.gate.yieldAfterMs)"
      + " yieldOn=\(Audio.gate.yieldOn)")

  // Brief overlap is what conversation sounds like.
  show("200 ms of overlap, they were first", yn(y(200, -400, 0)), "left alone", !y(200, -400, 0))
  show("449 ms, one millisecond short", yn(y(449, -400, 0)), "left alone", !y(449, -400, 0))
  // Past the deadlock threshold, whoever started second gives.
  show("600 ms, they started 400 ms earlier", yn(y(600, -400, 0)), "ducks", y(600, -400, 0))
  show("600 ms, this end started first", yn(y(600, 400, 0)), "left alone", !y(600, 400, 0))
  // The refusal.
  show("both started together, even ledger", yn(y(600, 20, 0)), "left alone", !y(600, 20, 0))
  show("both started together, no start known", yn(y(600, nil, 0)), "left alone", !y(600, nil, 0))
  // The ledger, which is the point of keeping one.
  show("together, but this end owes a turn", yn(y(600, 20, 0.5)), "ducks", y(600, 20, 0.5))
  show("together, and the far end owes one", yn(y(600, 20, -0.5)), "left alone", !y(600, 20, -0.5))
  show("this end has taken every start", yn(y(600, 400, 0.8)), "ducks even so", y(600, 400, 0.8))
  // Both ends run the same rule off mirrored ledgers, so exactly one gives.
  var mirrored = 0
  for owed in stride(from: -1.0, through: 1.0, by: 0.1) {
    let a = y(600, 20, owed), b = y(600, -20, -owed)
    if a != b { mirrored += 1 }
  }
  show("mirrored ledgers pick different sides", "\(mirrored)/21", ">= 12", mirrored >= 12)

  // ── AND THE DUCK ITSELF: BOUNDED, AND IT LETS GO ──────────────────────────
  //
  // Nine decibels, never a mute, and back within a breath of the deadlock
  // ending. A rule that decides correctly and then leaves somebody quiet is
  // worse than no rule at all.
  let g = Audio.DuplexGate()
  g.cfg = Audio.gate
  var seed: UInt64 = 0x9E11
  func rnd() -> Float {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Float(Int32(truncatingIfNeeded: Int(seed >> 33))) / Float(Int32.max)
  }
  let secs = 3.0, n = Int(SR * secs), blk = 16
  var x = (0..<n).map { _ in rnd() * 0.3 }
  let ref = x
  var minGain: Float = 1, releasedAt = -1.0
  x.withUnsafeMutableBufferPointer { op in
    var i = 0
    while i + blk <= n {
      let t = Double(i) / SR
      g.yielding = t >= 0.5 && t < 2.0            // a deadlock, then it ends
      g.process(op.baseAddress! + i, blk)
      if t > 1.9, t < 2.0 { minGain = min(minGain, g.yieldGainNow) }
      if t >= 2.0, releasedAt < 0, g.yieldGainNow > 0.98 { releasedAt = (t - 2.0) * 1000 }
      i += blk
    }
  }
  let duckDb = 20 * log10(Double(minGain))
  show("the duck settles at", String(format: "%.1f dB", duckDb), "-9 +/- 1",
       abs(duckDb + 9) < 1)
  show("... and it is never a mute", String(format: "%.3f gain", Double(minGain)),
       "> 0.2", minGain > 0.2)
  show("it lets go after the deadlock", releasedAt < 0 ? "never" : String(format: "%.0f ms", releasedAt),
       "< 300 ms", releasedAt >= 0 && releasedAt < 300)
  // Untouched while nobody is yielding: the first half second is the control.
  var worst = 0.0
  for i in 0..<Int(SR * 0.45) where abs(ref[i]) > 1e-4 {
    worst = max(worst, Double(abs(x[i] - ref[i]) / abs(ref[i])))
  }
  show("before the deadlock, nothing is touched", String(format: "%.4f%%", worst * 100),
       "0", worst < 0.001)

  print(bad ? "  YIELD TEST FAILED"
            : "  YIELD TEST PASSED -- brief overlap is left alone, a deadlock is decided by who"
              + " started second unless the ledger says otherwise, an even one is refused,"
              + " and the duck is 9 dB and lets go")
  exit(bad ? 1 : 0)
}

// `--no-gate` means HANDS OFF THE AUDIO, so it has to turn off both of the
// things that touch it. The duck is not part of the gate -- it survives on
// headphones, where the gate does not -- so leaving it on here would make
// "no gate" a measurement of audio that something else was still attenuating.
// ── A FLAG APPLIED AFTER THE TEST THAT READS IT IS NOT A FLAG ──────────────
//
// These were seven straight-line statements here, and `--yield-test` lives
// ninety lines ABOVE them and exits before reaching any of it. So
// `tk --yield-test --yield-db -12` ran the -9 duck, printed PASSED, and was
// labelled the -12 arm -- an arm compared against itself, which is the exact
// class that has already cost this project three A/Bs and has its own law.
//
// A function called from here AND from the top of the test, rather than the
// block moved: this file is top-level code whose ordering has caught me twice,
// and moving it would change when `--route` is validated relative to everything
// between. Every line is a pure assignment read out of argv, so calling it twice
// is the same as calling it once, and a run passing none of these flags does
// exactly what it did before.
func applyGateFlags() {
  if flag("no-gate") { Audio.gate.on = false; Audio.gateAuto = false; Audio.gate.yieldOn = false }
  // The turn layer ships ON, with this as the control arm. `--no-gate` must NOT
  // also switch it off: the echo gate and the turn layer answer two different
  // questions, and one flag answering two of those is a bug this project has
  // shipped four times (`one-condition-two-concerns`).
  if flag("no-floor") { Audio.floorOn = false }
  if flag("no-yield") { Audio.gate.yieldOn = false }
  // The control arm for the correlation veto (0.94.0): the classifier goes back
  // to trusting the level test alone, which is the 0.93.0 behaviour.
  if flag("no-corrveto") { Audio.corrVetoOn = false }
  // The control arm for the strict floor (0.95.0): the 0.94.0 rules -- the
  // -20 dB out-of-turn duck, the open idle, the open fallback.
  if flag("floor-soft") { Audio.sharedFloor.cfg.strict = false }
  if let v = arg("yield-db"), let d = Double(v) { Audio.gate.yieldDb = d }
  if let v = arg("yield-after"), let d = Double(v) { Audio.gate.yieldAfterMs = d }
  if flag("force-gate") { Audio.gate.on = true; Audio.gateAuto = false }
  if let v = arg("gate-floor"), let d = Double(v) { Audio.gate.floorDb = d }
  if let v = arg("gate-close-ms"), let d = Double(v) { Audio.gate.closeMs = d }
  if let v = arg("gate-margin"), let d = Double(v) { Audio.gate.margin = Float(d) }
}
applyGateFlags()
// `--route headphones` on a machine with no headphones. The route decides the
// classifier, the cues, the captions and the cleaner, so it has to be reachable
// from a rig or half the product is only ever unit-tested.
if let r = arg("route") {
  guard r == "speakers" || r == "headphones" else {
    fputs("--route takes `speakers` or `headphones`, not \(r)\n", stderr); exit(2)
  }
  Audio.routeForced = (r == "speakers")
}
// (`--gate-floor` and `--gate-margin` moved up into `applyGateFlags` above.
// Nothing between here and there reads `Audio.gate`, and `--route` does not
// touch it, so the state this file ends up in is unchanged.)

// ── THE SAME CALL, WITH HEADPHONES ON ─────────────────────────────────────
//
// The gate is off on headphones, correctly: there is no acoustic path from the
// earcup to the microphone, so there is no echo to protect against. Everything
// else was off with it, and nothing said so. `vocal` sat at `.quiet` for the
// whole call, so the cues never drew, the captions never appeared, the ledger
// never moved and the deadlock rule never fired -- the entire turn-taking
// product, off for anyone wearing headphones.
//
// The assertions below are PAIRS, because the cheap way to pass "a headphone
// user still gets a bid" is a classifier that says bid to everything.
if flag("headphone-test") {
  var bad = false
  func show(_ what: String, _ got: String, _ want: String, _ ok: Bool) {
    print("  \(what.padding(toLength: 52, withPad: " ", startingAt: 0)) "
        + "\(got.padding(toLength: 14, withPad: " ", startingAt: 0)) (want \(want))  \(ok ? "ok" : "WRONG")")
    if !bad { bad = !ok }
  }
  let n = Int(SR * 12)
  var seed: UInt64 = 0x4EAD
  func rnd() -> Float {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Float(Int32(truncatingIfNeeded: Int(seed >> 33))) / Float(Int32.max)
  }
  func active(_ i: Int, _ spans: [(Double, Double)]) -> Bool {
    let t = Double(i) / SR
    return spans.contains { t >= $0.0 && t < $0.1 }
  }
  // The far end talks almost throughout; the near end interrupts at 3 s. That
  // overlap is the whole subject: it is where a bid has to be seen, and it is
  // exactly where an echo test that should not be running would hide it.
  let farSpans = [(1.0, 11.0)]
  let nearSpans = [(3.0, 5.0), (8.0, 9.0)]
  var far = [Float](repeating: 0, count: n)
  var near = [Float](repeating: 0, count: n)
  for i in 0..<n {
    let env = Float(0.55 + 0.45 * sin(2 * Double.pi * 4.3 * Double(i) / SR))
    if active(i, farSpans) { far[i] = rnd() * 0.5 * env }
    if active(i, nearSpans) { near[i] = rnd() * 0.35 * env }
  }
  /// Run one route through the gate and report what the classifier saw during
  /// the overlap, and what the audio came out like.
  func run(gateOn: Bool, mic src: [Float], warm: (() -> Audio.DuplexGate)? = nil)
      -> (claim: Bool, changed: Double, claims: Int) {
    let g = warm?() ?? Audio.DuplexGate()
    var cfg = Audio.Gate(); cfg.on = gateOn; cfg.yieldOn = false
    g.cfg = cfg
    var out = src
    var sawClaim = false
    let blk = 16                      // what CoreAudio actually delivers here
    out.withUnsafeMutableBufferPointer { op in
      var i = 0
      while i + blk <= n {
        for k in i..<(i + blk) { g.noteFar(far[k]) }
        g.process(op.baseAddress! + i, blk)
        if active(i, nearSpans), g.vocal == .claim { sawClaim = true }
        i += blk
      }
    }
    var worst = 0.0
    for i in 0..<n where abs(src[i]) > 1e-4 {
      worst = max(worst, Double(abs(out[i] - src[i]) / abs(src[i])))
    }
    return (sawClaim, worst, g.claims)
  }

  // On headphones the microphone hears the near end and a whisper of bleed --
  // never the far end at any level that matters.
  var hp = [Float](repeating: 0, count: n)
  for i in 0..<n { hp[i] = near[i] + 0.004 * far[i] }
  // On speakers it hears the far end loudly, delayed by the trip through the room.
  var spk = [Float](repeating: 0, count: n)
  for i in 0..<n { spk[i] = near[i] + 0.8 * (i >= 400 ? far[i - 400] : 0) }

  print("\n  ── the route the gate was built for ──")
  let a = run(gateOn: true, mic: spk)
  show("speakers: a bid over the far end is still seen", a.claim ? "yes" : "no", "yes", a.claim)

  print("\n  ── headphones ──")
  let b = run(gateOn: false, mic: hp)
  show("headphones: the bid is seen", b.claim ? "yes" : "no", "yes", b.claim)
  show("headphones: the audio is untouched", String(format: "%.1e", b.changed), "0", b.changed < 1e-9)

  // THE PAIR. Same route, same far end, and NOBODY TALKING at this end -- only
  // the bleed. A classifier that answered `claim` to the test above because it
  // answers `claim` to everything fails here.
  var quiet = [Float](repeating: 0, count: n)
  for i in 0..<n { quiet[i] = 0.004 * far[i] }
  let c = run(gateOn: false, mic: quiet)
  show("headphones: silence is not a bid", "\(c.claims) bids", "0", c.claims == 0)

  // ── AND THE CASE THAT MOTIVATED THE FIX ──────────────────────────────────
  //
  // `coupling` is a MINIMUM tracker that only updates while this end is making
  // sound. Somebody who calls on speakers and then puts headphones on keeps the
  // coupling their room taught it -- so the far end's voice can still "explain"
  // their own, and the classifier goes deaf during simultaneous speech, which is
  // the one moment it exists for. It also starts at 0.5, so a cold headphone
  // call had the same defect without any learning at all.
  print("\n  ── headphones plugged in mid-call, after a loud room ──")
  let d = run(gateOn: false, mic: hp, warm: {
    // Teach it a very reflective room first, on speakers, exactly as a real
    // call would.
    let g = Audio.DuplexGate()
    var on = Audio.Gate(); on.on = true; on.yieldOn = false
    g.cfg = on
    var warmMic = spk
    warmMic.withUnsafeMutableBufferPointer { op in
      var i = 0
      while i + 16 <= n { for k in i..<(i + 16) { g.noteFar(far[k]) }; g.process(op.baseAddress! + i, 16); i += 16 }
    }
    return g
  })
  show("the bid survives the route change", d.claim ? "yes" : "no", "yes", d.claim)

  // ── AND WHAT THE SUBTITLE CLEANER DOES TO A HEADPHONE CALL ────────────────
  //
  // Measured on the SIGNAL, not on a transcript. The transcript rig cannot see
  // this at all -- its far end plays silence, so the cleaner has nothing to
  // subtract and returns almost exactly what it was given
  // (`blind-instruments-report-negatives`). It also has 25 points of run-to-run
  // noise, which would bury an effect this size several times over.
  //
  // Here the question is asked directly: how much of the near voice is left.
  print("\n  ── the subtitle cleaner, at 16 kHz ──")
  let m = Int(16000 * 6)
  var nearS = [Float](repeating: 0, count: m)
  var farS = [Float](repeating: 0, count: m)
  var s2: UInt64 = 0x3EED
  func r2() -> Float {
    s2 = s2 &* 6364136223846793005 &+ 1442695040888963407
    return Float(Int32(truncatingIfNeeded: Int(s2 >> 33))) / Float(Int32.max)
  }
  // Both talking at once, throughout -- the case the cues exist for, and the
  // only one where this matters.
  for i in 0..<m {
    let e = Float(0.6 + 0.4 * sin(2 * Double.pi * 3.1 * Double(i) / 16000))
    farS[i] = r2() * 0.5 * e
    nearS[i] = r2() * 0.3 * Float(0.6 + 0.4 * sin(2 * Double.pi * 4.7 * Double(i) / 16000))
  }
  func energyDb(_ a: [Float], from: Int) -> Double {
    var e = 0.0
    for i in from..<a.count { e += Double(a[i]) * Double(a[i]) }
    return 10 * log10(max(e / Double(a.count - from), 1e-20))
  }
  // HEADPHONES: the microphone has the near voice and nothing else, while the
  // far end is loud in the reference. Nothing should be removed.
  let hpOut = Audio.subtitleAudio(mic: nearS, ref: farS, onSpeakers: false,
                                  through: Audio.SubtitleCleaner())
  let lostHp = energyDb(nearS, from: 512) - energyDb(hpOut, from: 512)
  show("headphones: the near voice survives the cleaner",
       String(format: "-%.2f dB", lostHp), "< 0.01 dB", lostHp < 0.01)
  // AND THE REASON, kept as an assertion rather than a comment. If somebody
  // later makes the cleaner harmless on a route it has nothing to remove from,
  // this fires and says the skip above may no longer be needed -- which is a
  // far better failure than a skip nobody remembers the reason for.
  let harm = energyDb(nearS, from: 512)
           - energyDb(Audio.SubtitleCleaner().clean(mic: nearS, ref: farS), from: 512)
  show("  (and it WOULD cost this much, hence the skip)",
       String(format: "-%.1f dB", harm), "> 3 dB", harm > 3.0)

  // THE PAIR: on speakers the cleaner still has to do its job, or "skip it"
  // would be a fix that broke the thing it was skipping.
  var spkMic = [Float](repeating: 0, count: m)
  for i in 0..<m { spkMic[i] = nearS[i] + 0.5 * (i >= 128 ? farS[i - 128] : 0) }
  var echoOnly = [Float](repeating: 0, count: m)
  for i in 0..<m { echoOnly[i] = 0.5 * (i >= 128 ? farS[i - 128] : 0) }
  let c2 = Audio.SubtitleCleaner()
  // `probe` puts the echo alone through the gains the MIXTURE produced, which
  // is the only honest way to ask how much of the echo survived.
  _ = Audio.subtitleAudio(mic: spkMic, ref: farS, onSpeakers: true, through: c2)
  let echoAfter = c2.clean(mic: spkMic, ref: farS, probe: echoOnly)
  let echoDrop = energyDb(echoOnly, from: 512) - energyDb(echoAfter, from: 512)
  show("speakers: the echo is still removed", String(format: "%.1f dB", echoDrop),
       "> 8 dB", echoDrop > 8.0)

  print(bad ? "\n  HEADPHONE TEST FAILED"
            : "\n  HEADPHONE TEST PASSED -- the classifier is alive on headphones, the audio is"
              + " bit-for-bit untouched, silence is still silence, a coupling learned on"
              + " speakers cannot deafen it after the route changes, and the cleaner is skipped"
              + " where it would only do harm")
  exit(bad ? 1 : 0)
}

// ── DOES A TALKING NEAR END GET THROUGH UNTOUCHED? ────────────────────────
//
// That is the whole promise, and it is the half that a listening test is worst
// at confirming -- gentle damage to a voice sounds like a slightly worse
// microphone, not like a bug. So it is checked as an identity: build a far end
// talking, a near end talking over the top of it, and a microphone that hears
// both, then require the samples where the near end is speaking to come out
// EXACTLY as they went in, and the stretches where only the far end is speaking
// to come out quiet.
// ── WHOSE TURN IT IS, WITH A REAL DELAY BETWEEN THE TWO OPINIONS ────────────
//
// `--floor-owd` sweeps the one-way delay, because every bug this design can have
// is two ends disagreeing about the present, and a rig with no delay cannot
// produce one. Default 40 ms; try 100 for Delhi-NL.
if flag("quantile-test") { exit(Quantiles.selfTest() ? 0 : 1) }

if flag("corr-test") { exit(Audio.corrSelfTest() ? 0 : 1) }


if flag("turn-test") {
  let w = arg("turn-wav") ?? "testbed/media/real/realA.wav,testbed/media/real/realB.wav"
  exit(TurnRig.selfTest(paths: w.split(separator: ",").map(String.init),
                        owdMs: Double(arg("turn-owd") ?? "40") ?? 40,
                        coupling: Float(Double(arg("turn-coupling") ?? "0.25") ?? 0.25)) ? 0 : 1)
}

if flag("floor-test") {
  let owd = Double(arg("floor-owd") ?? "40") ?? 40
  let soft = Floor.selfTest(owdMs: owd)
  let far = Floor.predictFarSelfTest()
  let strict = Floor.strictSelfTest(owdMs: owd)
  exit(soft && far && strict ? 0 : 1)
}

if flag("gate-test") {
  let n = Int(SR * 12)
  var seed: UInt64 = 0x51ED
  func rnd() -> Float {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Float(Int32(truncatingIfNeeded: Int(seed >> 33))) / Float(Int32.max)
  }
  // Far end talks 1-5 s and 6-11 s. Near end talks 3-5 s (interrupting) and 8-9 s.
  func active(_ i: Int, _ spans: [(Double, Double)]) -> Bool {
    let t = Double(i) / SR
    return spans.contains { t >= $0.0 && t < $0.1 }
  }
  let farSpans = [(1.0, 5.0), (6.0, 11.0)]
  let nearSpans = [(3.0, 5.0), (8.0, 9.0)]
  var far = [Float](repeating: 0, count: n)
  var near = [Float](repeating: 0, count: n)
  for i in 0..<n {
    let env = Float(0.55 + 0.45 * sin(2 * Double.pi * 4.3 * Double(i) / SR))
    if active(i, farSpans) { far[i] = rnd() * 0.5 * env }
    if active(i, nearSpans) { near[i] = rnd() * 0.35 * env }
  }
  let couple = Float(Double(arg("gate-coupling") ?? "0.25") ?? 0.25)
  var mic = [Float](repeating: 0, count: n)
  for i in 0..<n { mic[i] = near[i] + couple * (i >= 400 ? far[i - 400] : 0) }

  // ── THE RIG PICKED ITS OWN BLOCK SIZE, WHICH IS HOW IT MISSED EVERYTHING ──
  //
  // This ran at 128 samples. The machine hands the gate SIXTEEN, and every
  // smoothing constant in the classifier was written per block -- so the rig was
  // testing a detector eight times slower than the one that ships, and passed it
  // while the shipped one could not produce a single bid in a fourteen-second
  // call. A rig that chooses a parameter the product does not choose is not
  // testing the product.
  //
  // So it sweeps: 16 is what CoreAudio actually delivers here, 128 is what this
  // test used to assume, 512 is a machine under load. All three have to pass,
  // and the classifier has to reach the same verdict in all three.
  var suppressed = 99.0, worstNear = 0.0, nearN = 0
  var perBlock: [String] = []
  var allOk = true
  for blk in [16, 128, 512] {
    let g = Audio.DuplexGate()
    g.cfg = Audio.gate
    var out = mic
    out.withUnsafeMutableBufferPointer { op in
      var i = 0
      while i + blk <= n {
        for k in i..<(i + blk) { g.noteFar(far[k]) }
        g.process(op.baseAddress! + i, blk)
        i += blk
      }
    }
    // Score the near-end stretches after the gate has had 200 ms to open.
    var wn = 0.0, farOnlyE = 0.0, farOnlyRef = 0.0, nn = 0
    for i in 0..<n {
      let t = Double(i) / SR
      let nearOn = nearSpans.contains { t >= $0.0 + 0.2 && t < $0.1 }
      let farOnly = active(i, farSpans) && !active(i, nearSpans)
      if nearOn, abs(mic[i]) > 1e-4 {
        wn = max(wn, Double(abs(out[i] - mic[i]) / abs(mic[i]))); nn += 1
      }
      if farOnly {
        farOnlyE += Double(out[i]) * Double(out[i])
        farOnlyRef += Double(mic[i]) * Double(mic[i])
      }
    }
    let sup = (farOnlyE > 0 && farOnlyRef > 0) ? 10 * log10(farOnlyRef / farOnlyE) : 99
    // ── AND THE CLASSIFIER HAS TO CLASSIFY ───────────────────────────────────
    //
    // The near end talks for two full seconds here. Anything that calls that a
    // listening noise is the defect this sweep exists to catch, and it is
    // invisible to the suppression and identity numbers above -- both of which
    // were green through the whole time the classifier was dead.
    let sawBid = g.claims > 0
    perBlock.append(String(format: "    %4d samples (%.2f ms): %.1f dB quieter, near voice %+.4f%%, %@",
                           blk, Double(blk) / SR * 1000, sup, wn * 100,
                           sawBid ? "\(g.claims) bid(s) seen" : "NO BID SEEN"))
    if !sawBid { allOk = false }
    if blk == 128 { suppressed = sup; worstNear = wn; nearN = nn }
  }
  for l in perBlock { print(l) }
  let untouched = worstNear < 0.001 && nearN > 1000
  print(String(format: "  while only they are talking, the microphone is %.1f dB quieter", suppressed))
  print(String(format: "  while you are talking, the worst sample differs by %.4f%% -- %@",
               worstNear * 100, untouched ? "untouched" : "CHANGED"))
  // ONE OF THESE IS ABSOLUTE AND THE OTHER IS NOT, AND SAYING SO IS THE POINT.
  // Never altering a talking near end is required in every room. How much echo
  // can be suppressed is a property of the room: when the microphone hears the
  // speaker at nearly the level it was played, no comparison of levels can
  // separate the two, and the right behaviour is to suppress less rather than
  // to gate somebody mid-sentence. So the suppression bar applies to rooms
  // where suppression is possible, and above that the number is reported.
  let hard = couple > 0.55
  let ok = untouched && allOk && (hard || suppressed > 15)
  print(String(format: "  (room: microphone hears the speaker at %.0f%% of playout)", couple * 100))
  print(ok ? (hard
        ? "  GATE TEST PASSED -- a hard room: less echo held back, and still not one sample of your voice touched"
        : "  GATE TEST PASSED -- your voice is bit-for-bit what the microphone heard")
     : "  GATE TEST FAILED" + (!untouched ? " (it altered the near voice)"
                              : !allOk ? " (the classifier never saw a bid at some block size)"
                              : " (it does not suppress enough)"))

  // ── THE CORRELATION VETO, ON THE ROOM THAT DEFEATS THE LEVEL TEST ──────────
  //
  // A room's coupling is not a constant, and the minimum tracker learns the
  // QUIETEST moment of it. Vary the coupling and the level test is beaten
  // honestly: the tracker holds the low ratio, the margin sits under the loud
  // stretches, and the speaker's own sound is classified as a person. That is
  // the defect measured live (a listening end's gate open 97% of a call it
  // spent alone), reproduced here so the veto has a case it must fix -- and a
  // twin it must NOT touch, because a test that cannot see the defect passes
  // either way (`green-metrics-can-hide-defects`).
  var vetoOk = true
  do {
    // Far end only. The coupling swings 0.2..0.9 at 0.3 Hz, like a person
    // shifting in front of a laptop.
    var emic = [Float](repeating: 0, count: n)
    for i in 0..<n where i >= 400 {
      let sway = Float(0.55 + 0.35 * sin(2 * Double.pi * 0.3 * Double(i) / SR))
      emic[i] = sway * far[i - 400]
    }
    func classify(veto: Bool) -> Int {
      Audio.corrVeto = veto
      defer { Audio.corrVeto = false }
      let g = Audio.DuplexGate()
      g.cfg = Audio.gate
      var buf = emic
      buf.withUnsafeMutableBufferPointer { op in
        var i = 0
        while i + 128 <= n {
          for k in i..<(i + 128) { g.noteFar(far[k]) }
          g.process(op.baseAddress! + i, 128)
          i += 128
        }
      }
      return g.claims + g.backchannels
    }
    let leak = classify(veto: false)
    let fixed = classify(veto: true)
    print("  the speaker's own sound, coupling swinging 20-90%:")
    print("    without the veto the classifier called it a voice \(leak)x -- the 0.93.0 leak")
    print("    with the veto: \(fixed)x")
    if leak == 0 {
      print("  VETO CHECK COULD NOT RUN -- the rig no longer reproduces the leak,")
      print("  so \"fixed\" above proves nothing.")
      vetoOk = false
    }
    if fixed > 0 { vetoOk = false }
    // What this deliberately does NOT assert: that a latched veto spares a real
    // near voice. It would not -- the veto kills whatever the level test
    // passes, by design -- and what spares a person in production is the
    // estimator WITHDRAWING the veto within one 500 ms tick of their voice
    // dominating the correlation. That half lives on the estimator thread,
    // which an offline rig cannot run; forcing the verdict here and calling the
    // resulting gag a failure would be testing a state the product cannot hold.
    Audio.corrVeto = false
    print(vetoOk ? "  VETO CHECK PASSED -- our own speaker is never a voice, and the leak was real"
                 : "  VETO CHECK FAILED")
  }
  exit(ok && vetoOk ? 0 : 1)
}

// ── BUILT AFTER THE TESTS, BECAUSE IT OPENS THE MICROPHONE ─────────────────
//
// This sat above every `--*-test` block, so `tk --gate-test` -- a pure
// computation over a synthetic buffer -- started CoreAudio and took the mic
// before running. gate-test has failed twice in about forty runs and could not
// be reproduced in twelve consecutive standalone runs, four runs straight after
// a rig script, or three passes of the whole suite; the cause is still unknown.
// This does not claim to fix it. It removes the one piece of ambient, shared,
// machine-owned state a test of arithmetic had no business touching, which is
// worth doing whether or not it is the culprit.
//
// Safe to move: nothing between the old position and here refers to `audio`,
// and no test reads `Audio.sharedGate`.
let audio = Audio()
audio.wire = wire

if let m = arg("presence") {
  guard let p = Audio.Presence.named(m) else {
    fputs("--presence takes off, leaning-in, next-to-you, in-the-room,"
        + " across-the-table or warmer, not \(m)\n", stderr)
    exit(2)
  }
  Audio.presence = p
  Metrics.fact("presence", m)
  // A ROOM LENGTHENS THE ECHO PATH. The reflections this adds are played by the
  // speaker like everything else, so they come back into the microphone that
  // much later. A canceller cancels what fits inside its window and nothing
  // past it, so a mode whose tail runs beyond it leaves echo the far end can
  // hear -- and the two modes with no reflections at all cannot, by
  // construction, cost anything here.
  if p.tailMs > 0 {
    fputs(String(format: "presence %@: reflections out to %.0f ms"
                 + " -- this is added to the echo path\n", m, p.tailMs), stderr)
    Metrics.fact("presence_tail_ms", String(format: "%.0f", p.tailMs))
  }
}

// ── TWO IMPLEMENTATIONS OF THE SAME SOUND ────────────────────────────────
//
// The mode is chosen by listening in Voice Lab, which renders in blocks over a
// whole recording; the call runs the same filter one sample at a time on the
// audio thread. Those are different pieces of code and there is no reason to
// believe they sound alike -- a mode picked by ear in one and delivered by the
// other is a guess unless somebody checks. This runs the call's filter over a
// file so the Lab can compare it against its own answer, sample by sample.
if let io = arg("presence-run") {
  let parts = io.split(separator: ",").map(String.init)
  guard parts.count == 2, let inData = FileManager.default.contents(atPath: parts[0]) else {
    fputs("--presence-run takes in.f32,out.f32\n", stderr); exit(2)
  }
  let n = inData.count / 4
  var x = [Float](repeating: 0, count: n)
  _ = x.withUnsafeMutableBytes { inData.copyBytes(to: $0) }
  let f = Audio.PresenceFilter()
  f.p = Audio.presence
  var y = [Float](repeating: 0, count: n)
  for i in 0..<n { y[i] = f.process(x[i]) }
  let out = y.withUnsafeBufferPointer { Data(buffer: $0) }
  try? out.write(to: URL(fileURLWithPath: parts[1]))
  fputs("presence-run: \(n) samples\n", stderr)
  exit(0)
}

// 16 frames is the HAL path's floor and it is measured, not guessed. Under
// VoiceProcessingIO it is the WRONG floor: that unit does its own block
// processing, and a 16-frame device buffer fights it -- swept on a loopback call
// with real speech, 16 gave 31.7% concealment where 64 gave none.
//
//    devbuf   m2e p50   conceal      (VoiceProcessingIO, loopback, real speech)
//      16      9.4 ms   455/s   <- unusable, the unit is being starved
//      64     14.8 ms     0/s   then 322/s on the very next run -- MARGINAL
//     128     20.8 ms     0/s   x3 (20.81 / 20.67 / 21.02) <- chosen
//     256     32.0 ms     0/s   x2
//     480     50.7 ms   272/s
//
// 64 is the number a single run would have chosen, and it is wrong: the repeat
// concealed 322/s and played 77.9%. Only 128 held across three runs, which is
// the difference between a measurement and a lucky sample. Cost against the HAL
// control (11.2 ms) is +9.6 ms, paid for an echo canceller that actually exists.
//
// So the default is per-path, and an explicit --devbuf still wins over both.
if Audio.ioKind == "vp" { Audio.devBuf = 128 }
if let db = arg("devbuf"), let v = Int(db), v >= 8, v <= 4096 { Audio.devBuf = v }
if flag("no-rt") { Wire.noRealtime = true }
if flag("pcm32") { Wire.forceFloat = true; fputs("audio wire: 32-bit float forced\n", stderr) }
if flag("no-lp") { Wire.forceNoLp = true; fputs("audio wire: payload compression off\n", stderr) }
if let ap = arg("audio") { fputs(audio.loadAudioSource(ap) + "\n", stderr) }
if let dp = arg("dump-playout") { fputs(audio.startDump(dp) + "\n", stderr) }
if let ed = arg("echo-sim") {
  // "18" or "18:0.3" -- delay in ms, optional linear gain.
  let parts = ed.split(separator: ":")
  let d = Double(parts[0]) ?? 18
  let g = parts.count > 1 ? (Double(parts[1]) ?? 0.3) : 0.3
  fputs(audio.armEchoSim(delayMs: d, gain: g) + "\n", stderr)
}
audio.concealZeros = (arg("conceal") == "zeros")
audio.concealGrain = (arg("conceal") == "grain")
audio.interpLinear = (arg("interp") == "linear")
audio.acoustic = flag("acoustic")
audio.cursorAheadMs = Double(arg("cursor-ahead") ?? "0") ?? 0
audio.stallOutAfterS = Double(arg("stall-out") ?? "0") ?? 0

// ── Self-test: decode(encode(x)) must equal x, for every x ────────────────────
//
// A lossless coder has the rare luxury of an ABSOLUTE test, so it gets one: real
// speech, then the shapes that break bit-packers -- silence, full scale, the
// alternating extremes that maximise every residual, and pseudo-random noise
// where prediction cannot help and the raw fallback must engage.
// ── Is the picture actually lossless? ────────────────────────────────────────
//
// "Video visually lossless" is half the goal and there has been no instrument for
// it. A bitrate cannot answer it and neither can a frame rate: this project has
// already shipped an upside-down camera past a green rig. So: push a real file
// through the real encoder into the real decoder, IN ONE PROCESS -- the two ends
// of a call are separate processes carrying different video, so there is nothing
// there to compare -- and measure what the codec did to it.
//
//   tk --vpsnr <file.mp4> [--vpsnr-frames 300] [--vbitrate 3000000]
//
// PSNR on the luma plane. Rough reading: above ~45 dB is visually lossless, 40-45
// is very good, 35-40 shows on detail, below 30 is visible. Reported with the p05
// as well as the p50, because the frame people notice is the worst one.
if let path = arg("vpsnr") {
  let want = Int(arg("vpsnr-frames") ?? "300") ?? 300
  let br = Int(arg("vbitrate") ?? "3000000") ?? 3_000_000
  var psnr = Quantiles(cap: 4096)
  var bytes = 0, frames = 0, compared = 0, sizeMismatch = 0
  var worst = (db: 1e9, at: 0)
  // capHost -> the source luma, so a decoded frame is compared against the exact
  // frame it came from rather than a neighbouring one.
  var srcLuma = [UInt64: (buf: [UInt8], w: Int, h: Int)]()
  let lock = NSLock()
  let done = DispatchSemaphore(value: 0)

  func luma(_ pb: CVPixelBuffer) -> (buf: [UInt8], w: Int, h: Int)? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let p = base.assumingMemoryBound(to: UInt8.self)
    var out = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h { memcpy(&out[y * w], p + y * stride, w) }
    return (out, w, h)
  }

  do {
    let dec = VDecoder()
    let enc = try VEncoder(width: 1280, height: 720, bitrate: br,
                           quality: arg("vquality").flatMap { Double($0) })
    enc.requestKeyframe()
    dec.onDecoded = { img, capHost in
      guard let pb = img as CVPixelBuffer?, let got = luma(pb) else { return }
      lock.lock()
      let original = srcLuma.removeValue(forKey: capHost)
      lock.unlock()
      guard let a = original else { return }
      // REFUSE rather than resample. Comparing a scaled picture to an unscaled one
      // measures the scaler, and would report the codec as far worse than it is.
      guard a.w == got.w, a.h == got.h else { sizeMismatch += 1; return }
      var sum = 0.0
      for i in 0..<(a.w * a.h) {
        let d = Double(Int(a.buf[i]) - Int(got.buf[i]))
        sum += d * d
      }
      let mse = sum / Double(a.w * a.h)
      // Identical frames give MSE 0 and infinite PSNR; cap it so a run of perfect
      // frames does not poison a percentile with infinities.
      let db = mse <= 0 ? 99.0 : 10.0 * log10(255.0 * 255.0 / mse)
      psnr.add(db)
      compared += 1
      if db < worst.db { worst = (db, compared) }
      if compared >= want { done.signal() }
    }
    enc.onEncoded = { data, host, _ in
      bytes += data.count
      dec.decode(data, hostTime: host)
    }
    let src = FileSource(path: path, fps: Double(arg("fps") ?? "30") ?? 30)
    src.onFrame = { pb, host in
      guard frames < want else { return }
      frames += 1
      if let l = luma(pb) { lock.lock(); srcLuma[host] = l; lock.unlock() }
      enc.encode(pb, hostTime: host)
    }
    fputs("vpsnr: \(path) -> H.264 1280x720 @ \(br / 1000) kbps, \(want) frames\n", stderr)
    try src.start()
    // The file plays in real time, so bound the wait by that plus slack rather
    // than spinning: 300 frames at 30 fps is ten seconds.
    _ = done.wait(timeout: .now() + Double(want) / 25.0 + 15.0)
  } catch {
    fputs("vpsnr: \(error)\n", stderr)
    exit(1)
  }
  let secs = Double(frames) / (Double(arg("fps") ?? "30") ?? 30)
  fputs("vpsnr: \(compared) frames compared of \(frames) encoded"
      + (sizeMismatch > 0 ? "  (\(sizeMismatch) REFUSED for size mismatch -- the source is not 1280x720,"
         + " so the scaler would be measured instead of the codec)" : "")
      + "\n  PSNR p50 \(psnr.p(0.50).map { String(format: "%.1f", $0) } ?? "-") dB"
      + "  p05 \(psnr.p(0.05).map { String(format: "%.1f", $0) } ?? "-") dB"
      + "  worst \(String(format: "%.1f", worst.db)) dB at frame \(worst.at)"
      + "\n  \(bytes / 1024) KiB in \(String(format: "%.1f", secs)) s"
      + " = \(String(format: "%.3f", Double(bytes) * 8 / 1e6 / max(secs, 0.001))) Mbps"
      + ", \(compared > 0 ? bytes / max(frames, 1) : 0) B/frame\n", stderr)
  let p50 = psnr.p(0.50) ?? 0
  fputs("  verdict: " + (p50 >= 45 ? "visually lossless"
                       : p50 >= 40 ? "very good, not lossless"
                       : p50 >= 35 ? "good; detail is being lost"
                       : "visibly compressed") + "\n", stderr)
  exit(compared > 0 ? 0 : 1)
}

if let path = arg("selftest-lpc") {
  var fail = 0, packets = 0, inBytes = 0, outBytes = 0
  var raws = 0
  var hist = [Int: Int]()
  func check(_ s: [Int16], _ label: String) {
    var enc = [UInt8](repeating: 0, count: Lpc.bound(s.count))
    var dec = [Int16](repeating: 0, count: s.count)
    let m = s.withUnsafeBufferPointer { sp in
      enc.withUnsafeMutableBufferPointer { ep in Lpc.encode(sp.baseAddress!, s.count, into: ep.baseAddress!) }
    }
    let ok = enc.withUnsafeBufferPointer { ep in
      dec.withUnsafeMutableBufferPointer { dp in Lpc.decode(ep.baseAddress!, m, s.count, into: dp.baseAddress!) }
    }
    packets += 1; inBytes += s.count * 2; outBytes += m
    if enc[0] & 0x80 != 0 { raws += 1 } else { hist[Int(enc[0] & 3), default: 0] += 1 }
    if !ok || dec != s {
      fail += 1
      if fail <= 3 {
        let bad = (0..<s.count).first { dec[$0] != s[$0] } ?? -1
        fputs("  MISMATCH \(label): ok=\(ok) first bad index \(bad)"
            + " want \(bad >= 0 ? Int(s[bad]) : 0) got \(bad >= 0 ? Int(dec[bad]) : 0)"
            + "  mode 0x\(String(enc[0], radix: 16)) bytes \(m)\n", stderr)
      }
    }
  }
  // Synthetic edge cases first: they are the ones that expose a bit-packer.
  check([Int16](repeating: 0, count: FPP), "silence")
  check([Int16](repeating: 32767, count: FPP), "full positive")
  check([Int16](repeating: -32768, count: FPP), "full negative")
  check((0..<FPP).map { $0 % 2 == 0 ? Int16(32767) : Int16(-32768) }, "alternating extremes")
  check((0..<FPP).map { Int16(truncatingIfNeeded: $0 * 1031) }, "ramp")
  var seed: UInt64 = 0x2545_F491_4F6C_DD1D
  for _ in 0..<2000 {
    let s = (0..<FPP).map { _ -> Int16 in
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return Int16(truncatingIfNeeded: seed >> 33)
    }
    check(s, "random")
  }
  // Then the thing it actually has to compress.
  if let d = FileManager.default.contents(atPath: path) {
    // Walk the chunks; realA.wav carries a LIST chunk so `data` starts at 78, not
    // 44, and assuming the canonical header silently feeds metadata to the coder.
    var off = 12
    while off + 8 <= d.count {
      let cid = String(bytes: d[off..<(off + 4)], encoding: .ascii) ?? ""
      let sz = d[(off + 4)..<(off + 8)].withUnsafeBytes { $0.load(as: UInt32.self) }
      if cid == "data" { off += 8; break }
      off += 8 + Int(sz) + (Int(sz) & 1)
    }
    let count = (d.count - off) / 2
    var pcm = [Int16](repeating: 0, count: count)
    _ = pcm.withUnsafeMutableBytes { d.copyBytes(to: $0, from: off..<(off + count * 2)) }
    var i = 0
    while i + FPP <= count { check(Array(pcm[i..<(i + FPP)]), "speech@\(i)"); i += FPP }
  } else { fputs("  (no wav at \(path) -- synthetic cases only)\n", stderr) }
  let ratio = Double(inBytes) / Double(max(1, outBytes))
  fputs("lpc self-test: \(packets) packets, \(fail) mismatches"
      + "  \(String(format: "%.2f", Double(outBytes) / Double(packets))) B/packet"
      + "  ratio \(String(format: "%.2f", ratio))x"
      + "  raw-fallback \(raws)  orders \(hist.sorted { $0.key < $1.key }.map { "p\($0.key)x\($0.value)" }.joined(separator: " "))\n", stderr)
  exit(fail == 0 ? 0 : 1)
}
audio.mute = flag("mute") || (ProcessInfo.processInfo.environment["TK_MUTE"] == "1")
if audio.acoustic && audio.mute {
  fputs("--acoustic needs to play a sound and playout is muted (--mute or TK_MUTE=1).\n"
      + "  Refusing rather than reporting zero clicks heard, which would look like a real negative.\n", stderr)
  exit(1)
}
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
// AIM AT VISUALLY LOSSLESS AND RETREAT WHEN THE LINK SAYS NO. `--vquality <n>`
// caps it; `--vquality 0` reproduces the old always-unset behaviour.
// `--no-vpause` is the control arm: a link bad enough to stop the picture is
// exactly the link where "is stopping it actually better" needs an answer, and
// an arm that cannot be pinned measures nothing. `--vpause-after 1` makes a
// ten-second rig prove in ten seconds what a real bad link takes minutes to do.
let vq = VQuality(ceiling: arg("vquality").flatMap { Double($0) }, hold: flag("vq-hold"),
                  pause: !flag("no-vpause"),
                  pauseAfter: arg("vpause-after").flatMap { Int($0) } ?? 3,
                  resumeQuiet: arg("vpause-quiet").flatMap { Int($0) } ?? 8)
// ── Prove a live encoder property, or do not believe it ─────────────────────
//
// `--vq-step 30:400000` drops the bitrate ceiling to 400 kbps at t=30 s on an
// otherwise untouched call. A step on a CLEAN link is the only way to separate
// "the property works" from "loss changed the picture": under impairment the
// keyframe storm moves the bytes by more than the knob does, which is exactly
// how a no-op property survived being watched for a whole release.
let vqStep: (at: Double, q: Double)? = arg("vq-step").flatMap { spec in
  let parts = spec.split(separator: ":")
  guard parts.count == 2, let t = Double(parts[0]), let q = Double(parts[1]) else {
    fputs("--vq-step wants seconds:quality, e.g. 40:0.3\n", stderr); exit(2)
  }
  return (t, q)
}
var vqStepDone = false
let vParityOff = flag("no-vparity")
var lastVqHarmed = false
// ── WHAT `--video` ACCEPTS, SAID OUT LOUD ──────────────────────────────────
//
// This was `videoArg == "camera" ? CameraSource() : FileSource(path: videoArg)`,
// so EVERY other string was a filename. The launcher passes `--video on`, which
// is the obvious thing to write and the obvious thing to mean -- and it became a
// hunt for a file called "on", which failed, so the double-clicked app has never
// once had a camera. It also never asked for a window. A person opening Tokkah.app
// got a name prompt and then an invisible process: not a video calling app.
//
// "on" is now an alias for the camera, and an argument that is neither a known
// keyword nor an existing file is refused with the list of what works, rather than
// being quietly treated as a path that happens not to exist.
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
// Decode on its OWN thread, not on the one receiving audio. See DecodeQueue for
// the measurement: inline decode cost 1.8 ms of audio latency on every video call
// by blocking the receive loop, and the cadence instrument proved it was arrival
// jitter rather than the sender.
let dq = DecodeQueue { p, n, host in
  vdec.decode(Data(bytes: p, count: n), hostTime: host)
}
vasm.onFrame = { data, host in
  data.withUnsafeBytes { raw in
    dq.submit(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count, host)
  }
}
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

let dumpTo = arg("dump")
var dumped = false
vdec.onDecoded = { img, capHost in
  gRxWidth = CVPixelBufferGetWidth(img); gRxHeight = CVPixelBufferGetHeight(img)
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

      // And how much the far end's picture was MOVING, from the same samples --
      // so "blocky" can be separated from "blocky while he moved", which are
      // different bugs with different fixes.
      var m = 0, mn = 0, yz = 0, w2 = 0
      while yz < h && w2 < gDecCur.count {
        var x = 0
        while x < w && w2 < gDecCur.count { gDecCur[w2] = p[yz * stride + x]; w2 += 1; x += 16 }
        yz += 16
      }
      if gDecPrevN == w2 && w2 > 0 {
        for i in 0..<w2 { m += abs(Int(gDecCur[i]) - Int(gDecPrev[i])); mn += 1 }
        if mn > 0 { gDecMotion = Double(m) / Double(mn) }
      }
      for i in 0..<w2 { gDecPrev[i] = gDecCur[i] }
      gDecPrevN = w2
    }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
  }
  // Same rule as audio: the capture stamp is the PEER's clock, so without the
  // offset this is not a latency, it is the difference between two epochs.
  if gThetaValid { vg2g.add(Clock.msSigned(Clock.now(), capHost) + gThetaMs) }
  vDecoded += 1
  // The other person's first frame. From here the window shows them instead of
  // you, and says so.
  if !sawRemote {
    sawRemote = true
    // Their picture takes the window; yours moves to the corner.
    display?.selfViewOn = true
    // ── AND THE CARD STAYS, BECAUSE THIS IS THE PICTURE ON THE CARD ─────────
    //
    // The single worst bug this feature could have, and it was here rather than
    // in any of the places guarded for it. The transport lock has a careful
    // ringPreview split a thousand lines up; this path does not go through it.
    // `markConnected()` sets `waiting.isHidden = true`, and the answer and
    // decline buttons are subviews of `waiting` -- so the caller's FIRST FRAME
    // took the card, both buttons and the whole decision away, left "connected"
    // in the status pill, and went on ringing for forty seconds at somebody with
    // nothing to press. `showIncoming` refuses to re-open it and `markConnected`
    // is one-shot, so there is no way back.
    //
    // Not caught by the rig because its caller ran `--video off`: a ring preview
    // that never receives a frame cannot reach the line that reacts to one.
    if !ringPreview {
      display?.controls?.markConnected()
      setWindowTitle("Kin — connected")
      display?.controls?.setStatus(gMicMuted ? "you are muted" : "connected")
    }
    if ringPreview {
      // The only line in this program that knows a picture EXISTS. Everything
      // above runs on the transport being up, which is a different question and
      // was answering this one wrongly -- see the lock path for what that cost.
      Metrics.count("ring_preview_picture")
      Metrics.mark("ring_preview_picture_ms", sinceLaunch())
    }
    fputs("the other side's picture is on screen"
        + (ringPreview ? " -- behind the ring card, still nobody's decision" : "") + "\n",
          stderr)
  }
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

// ── THE THIRD CAMERA BRING-UP, AND THE ONE THE PARK USED TO HIDE ──────────
//
// Two bring-ups above this are gated on `ringPending` and have been since 0.61.0.
// This one never needed a gate, because the park block returned long before the
// line was reached -- so the moment a ring was allowed to fall through to receive
// the caller's picture, the green light came on next to somebody who had agreed
// to nothing. The rig caught it in the first run: `camera: bring-up 95 ms` in an
// unanswered ring. Third instance of a guard that was really a side effect of
// control flow somewhere else.
if videoArg != "off", !ringPreview {
  do {
    // Reuse the preview camera. Opening a second AVCaptureSession on the same
    // device is how you get two permission prompts and one black picture.
    let src: FrameSource = earlyCam
      ?? (videoArg == "camera" ? CameraSource()
                              : FileSource(path: videoArg, fps: Double(arg("fps") ?? "30") ?? 30))
    // Non-nil means a source was built and adopted, not that its hardware came up:
    // the camera's bring-up is asynchronous now. A bring-up that FAILED clears
    // `earlyCam` on the main queue, and the rendezvous loop above drains that queue
    // on every poll, so by the time this line runs the pointer is honest. Belt and
    // braces at the other end too -- `CameraSource.bringUp` refuses to run twice.
    let reusing = earlyCam != nil
    // The controller owns the quality from here; the flag only sets its ceiling.
    // `--vquality 0` pins it to the old unset behaviour.
    let e = try VEncoder(width: 1280, height: 720,
                         bitrate: Int(arg("vbitrate") ?? "3000000") ?? 3_000_000,
                         quality: vq.quality)
    e.requestKeyframe()
    src.onFrame = { pb, host in
      // Camera off: stop encoding entirely rather than sending black. Black frames
      // still cost an encode, a packet and a decode, and the far end cannot tell
      // them from a dark room. Nothing sent is unambiguous, and the receiver's
      // last frame simply stays put.
      if camOff { return }
      // ── PAUSED: STILL YOUR CAMERA, JUST NOT THEIR PROBLEM ────────────────────
      //
      // The frame is dropped BEFORE the encoder, not after it: encoding a picture
      // and then discarding it would burn the same CPU and the same battery for a
      // packet nobody sends, on a machine whose link is already in trouble.
      //
      // But the self-view keeps updating. Your own camera did not fail, and a
      // corner tile that freezes at the same moment as the main picture is how
      // "their connection is weak" gets misread as "this app has hung".
      if gVideoPaused {
        display?.showSelf(pb)
        return
      }
      e.encode(pb, hostTime: host)
      // Same single owner as the early-camera path above.
      display?.showSelf(pb)
      if !sawRemote && !peerHere { mdisplay?.show(pb, at: Clock.now()) }
    }
    e.onEncoded = { data, host, _ in
      wire.sendVideo(seq: vseq, capHost: host, payload: data, scratch: vscratch)
      vseq += 1; vSentFrames += 1; vBytesSent += data.count
    }
    // Already running if it was the preview camera; starting a live session again
    // throws.
    if !reusing { try src.start() }
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
wire.onKeyRequest = { keyAsksIn += 1; venc?.requestKeyframe() }

// ── THE QUIET SIDE STILL GETS TO SAY SOMETHING ───────────────────────────────
//
// One person is audible at a time, and the entire design rests on the other one
// not being LOST. Their microphone never stops recording -- the gate turns it
// down on the way to the wire, it does not stop capturing -- so their own
// machine recognises what they said and sends the words. Their audio never
// travels, which is why this can keep up with somebody talking.
nonisolated(unsafe) var peerSaid = ""
nonisolated(unsafe) var peerSaidFinal = false
nonisolated(unsafe) var peerSaidAt = Date.distantPast
nonisolated(unsafe) var subSent = 0
nonisolated(unsafe) var subGot = 0
nonisolated(unsafe) var turnComplete = 0.0
/// Whether the utterance currently being recognised has stayed a listening noise
/// the whole way through. Written by the chunk thread, read by the recogniser's
/// callback; a bool either side of a 120 ms tick, which is why it needs nothing
/// around it.
nonisolated(unsafe) var utteranceWasListening = true
/// Samples the chunk reader handed over, and samples that survived the cleaner.
/// A gap between them is audio the recogniser never sees, and a gap that GROWS is
/// a transcript that falls further behind the longer the call runs.
nonisolated(unsafe) var fedIn = 0
nonisolated(unsafe) var fedOut = 0
let subtitles = flag("no-subtitles") ? nil
  : Subtitles(port: Int(arg("asr-port") ?? "8789") ?? 8789, prefer: arg("asr") ?? "apple")

// RECEIVING IS NOT SENDING, and this was inside the block that needs a
// recogniser -- so a machine without one could not DISPLAY the far end's words
// either, though displaying text requires nothing at all. The end-to-end test
// caught it immediately: the speaker recognised itself perfectly and the
// listener showed nothing.
nonisolated(unsafe) var peerSaidListening = false
/// ── SPEAKING, WITHOUT A MICROPHONE ───────────────────────────────────────────
///
/// The rule for subtitles lives in `subs.onText` -- who sends, when, and who is
/// allowed to draw them. None of that can be reached from a rig, because reaching
/// it needs a real voice and a real recogniser, and this repo has a law about
/// what a test that cannot see the thing under test is worth. The `said` and
/// `mine` press tokens write straight into the caption layer, so they prove the
/// BAND and can say nothing at all about the rule.
///
/// So the recogniser's own callback is published here and `--press utter:<words>`
/// calls it. Everything downstream of that point is the shipping path: the gate
/// that decides whether it goes on the wire, the packet, the far end's decode and
/// the far end's caption. Only the microphone is simulated, which is the one part
/// a headless Mac cannot supply.
nonisolated(unsafe) var gUtter: ((String, Bool) -> Void)?
wire.onSubtitle = { text, final, listening in
  peerSaid = text; peerSaidFinal = final; peerSaidAt = Date(); peerSaidListening = listening
  subGot += 1
  // ── TWO KINDS OF WORDS, TWO PLACES ────────────────────────────────────────
  //
  // A listening noise blooms over the picture for a second and a half and is
  // gone; a real utterance runs in the caption band. Which one it is was decided
  // by the machine that HEARD it, from how long it lasted and how hard it pushed
  // -- "yeah" is both of these things depending on nothing you can see in the
  // text.
  if let c = display?.controls {
    if listening { c.setListeningNoise(text) } else { c.setTheirWords(text, final: final) }
  }
  if flag("subtitle-debug") {
    fputs("  they said: \(text)\(final ? " ." : " ...")\(listening ? "  (listening)" : "")\n", stderr)
  }
}

// The wordless half, and the fast one. Fired from the receive thread the moment
// the far end's status byte changes, so it lands one hop after they open their
// mouth instead of waiting for a recogniser. The ledger rides along: somebody who
// is owed a turn gets a cue that arrives quicker and pushes harder.
wire.onPeerVocal = { v in
  display?.controls?.setFloor(peerVocal: v, nudge: audio.yieldNudge)
  if ProcessInfo.processInfo.environment["KIN_CUE_DEBUG"] != nil {
    fputs(String(format: "cue in  %.3f  peer -> %d\n", Date().timeIntervalSince1970, v), stderr)
  }
}

if let subs = subtitles {
  // Published for `--press utter:`. Assigned to the same closure the recogniser
  // gets, not a copy of its body, so a rig can never drift from the real path.
  defer { gUtter = subs.onText }
  subs.onText = { text, final in
    guard !text.isEmpty else { return }
    subSent += 1
    // What KIND of sound these words came from is this machine's to say -- it is
    // the only one that heard the waveform. The flag is latched for the whole
    // utterance rather than read at the moment the text lands: recognition
    // finishes after the sound does, and by then the gate has usually moved on.
    let listening = utteranceWasListening
    // ── SUBTITLES ARE FOR A VOICE THAT CANNOT BE HEARD ───────────────────────
    //
    // They went out on every utterance, and both ends drew them: the far end as
    // "theirs", and this end as "mine" whenever your own voice was not the
    // audible one. So two captions could be on one screen at once, and the
    // person reading their OWN words was the one person in the call who already
    // knew what they had just said.
    //
    // The rule now is the one the feature was always for: if somebody's voice is
    // not reaching the other person, the other person reads it instead. That
    // makes the decision the SENDER's, because the sender is the only end that
    // knows whether its microphone is off -- and it means nothing new on the
    // wire, no status bit for the far end to interpret and no older build to
    // keep in step. Nothing is sent while you can be heard, which also stops
    // paying for recognition traffic on the ordinary case, and the receiver
    // simply draws whatever arrives.
    //
    // The duck counts, not just the switch. `gain` is the echo gate and
    // `yieldGainNow` is the turn-taking one; a voice held down by either is a
    // voice the other person is not getting, which is the same problem the mute
    // switch causes deliberately.
    let audible = !gMicMuted
      && Audio.sharedGate.gain * Audio.sharedGate.yieldGainNow > 0.5
    if !audible { wire.sendSubtitle(text, final: final, listening: listening) }
    // ── AND NEVER ON YOUR OWN SCREEN ─────────────────────────────────────────
    //
    // This used to show you your own sentence while you were the quiet one, and
    // then it used to CLEAR that -- `setMyWords("", showing: false)`, right here,
    // the only call to it left anywhere in the app, wiping a caption that nothing
    // could put up any more. A whole second line of the band existed to be
    // cleared by this line. Both are gone; see the note above `CaptionBand`.
    //
    // The sending half of the subtitle stopwatch, paired with `sub in` on the far
    // end's `setTheirWords`. Absolute epoch, like `cue out` below it, because the
    // two ends of this measurement are two processes.
    if ProcessInfo.processInfo.environment["KIN_CUE_DEBUG"] != nil {
      fputs(String(format: "sub out %.3f  \"%@\"%@\n", Date().timeIntervalSince1970,
                   text, audible ? "  (not sent -- audible)" : ""), stderr)
    }
    if flag("subtitle-debug") {
      fputs("  \(sinceLaunch()) ms you said: \(text)\(final ? " ." : " ...")"
          + "\(listening ? "  (listening)" : "")\n", stderr)
    }
  }
  // Smart-turn reads the WAVEFORM, so it is judging prosody: a sentence that
  // landed against one that trailed off, which no transcript can recover. It is
  // what lets a handover happen at the end of a thought rather than after a
  // silence long enough to be uncomfortable.
  subs.onComplete = { p in turnComplete = p }

  // Off the audio thread entirely. It reads the two histories the audio thread
  // has already written, a safe distance behind the write head.
  Thread {
    let cleaner = Audio.SubtitleCleaner()
    var wasVocal = false
    var spokeFor = 0.0
    var resetListening = true
    while !shuttingDown {
      Thread.sleep(forTimeInterval: 0.12)
      // NO `guard Audio.gate.on`. It was here, and `gate.on` is false on
      // headphones, so this thread returned immediately and NOBODY WEARING
      // HEADPHONES EVER SAW A SUBTITLE. Recognising speech has nothing to do
      // with whether there is an echo path to protect against.
      let vocal = Audio.sharedGate.vocal != .quiet
      // ── THE FLAG BELONGS TO THE UTTERANCE BEING TRANSCRIBED ────────────────
      //
      // Third time around on this one, and the fix is finally about SCOPE rather
      // than about timing. The gate's vocalisation and the recogniser's utterance
      // are not the same span: a long sentence contains pauses over 450 ms, so
      // the gate ends and restarts several times inside one utterance, and every
      // restart begins as a listening noise again. Measured on a live call, a
      // 47-word sentence went out labelled a listening noise because its TAIL was
      // a fresh vocalisation less than 700 ms old.
      //
      // So it latches false the moment anything in this utterance becomes a bid,
      // and it only resets when the RECOGNISER's utterance ends -- and even then
      // not immediately, but at the next onset, because the final revision is
      // published asynchronously after that call and would otherwise read the
      // reset value.
      if !wasVocal, vocal, resetListening { utteranceWasListening = true; resetListening = false }
      if vocal, Audio.sharedGate.everClaimed { utteranceWasListening = false }
      if let c = audio.subtitleChunk(), !c.mic.isEmpty {
        fedIn += c.mic.count
        // Cleaned before it is recognised, because on speakers this microphone
        // also hears the far end and their words would otherwise land in this
        // person's subtitles under this person's name.
        // ── THE CLEANER IS NOT FREE, SO IT HAS AN OFF SWITCH ─────────────────
        //
        // It exists for the case where this microphone hears the far end off the
        // speaker. When it does not -- headphones, or the far end silent -- it is
        // spectral surgery on a signal that needed none, and the only way to know
        // what it costs the transcript is to measure both arms on the same call.
        // ── AND IT IS SKIPPED ENTIRELY ON HEADPHONES ─────────────────────────
        //
        // Not as an optimisation. `coupling` starts at 0.35 in every band and
        // `over` is 9, so before it has adapted the cleaner removes 3.15x the
        // far end's magnitude from bands the far end is loud in -- and on
        // headphones NONE of that far end is in this microphone. The near voice
        // occupies those same bands, so it clamps to `floorFrac`: 30 dB down,
        // on the speaker, during simultaneous speech.
        //
        // It does adapt away, but only while this end is QUIET and the far end
        // is talking, which is exactly what somebody who joins and immediately
        // talks over the far end never provides. So the danger window is open
        // precisely for the person the cues exist to help.
        //
        // `onSpeakers` and not `Audio.gate.on`: the gate is a decision, this is
        // the physical route, and reading a decision as a fact is what put the
        // whole feature behind a pair of headphones in the first place.
        let clean = flag("no-sub-clean") ? c.mic
          : Audio.subtitleAudio(mic: c.mic, ref: c.ref,
                                onSpeakers: audio.onSpeakers, through: cleaner)
        fedOut += clean.count
        clean.withUnsafeBufferPointer { subs.feed($0.baseAddress!, $0.count) }
      }
      if vocal { subs.tick() } else if wasVocal { subs.endUtterance(); resetListening = true }

      // ── A SENTENCE ENDS WHEN IT LANDS, AND ONLY AT A PAUSE ─────────────────
      //
      // Waiting for the 450 ms of silence that ends a vocalisation is what made a
      // long turn grow into a paragraph: the recogniser was handed a longer window
      // every time, the caption never committed, and the request cost climbed with
      // it. Somebody talking steadily for a minute never produces that gap.
      //
      // Smart-turn answers the right question -- it reads the WAVEFORM, so it
      // hears a sentence that landed against one that trailed off, which no
      // transcript can recover. But it has to be ASKED AT A PAUSE. Thresholding
      // it against a continuous stream chopped read speech every 1.2 seconds:
      // measured against ground truth on a live call, 85.8% word error, a
      // transcript of "Mr. Quilter is the." / "Cool." / "Matter."
      //
      // So: a real breath (220 ms, shorter than the 450 that ends a turn and
      // longer than a plosive), and prosody that says it landed, and enough
      // material behind it to be a sentence at all.
      spokeFor = vocal ? spokeFor + 0.12 : 0
      let breath = Audio.sharedGate.quietMsNow
      if vocal, spokeFor > 1.5, breath > 220, turnComplete > 0.8 {
        subs.endUtterance()
        resetListening = true
        spokeFor = 0
        // Consumed. The probability belongs to the response that produced it, and
        // leaving it high would end the next sentence the moment it drew breath.
        turnComplete = 0
      } else if vocal, spokeFor > 12 {
        // A monologue still has to commit. Twelve seconds is past any sentence
        // and just inside the recogniser's own 14 s window, so this is also what
        // stops the request growing without bound.
        subs.endUtterance()
        resetListening = true
        spokeFor = 0
      }
      wasVocal = vocal
    }
  }.start()
}
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
                    jitterMs: Double(arg("imp-jitter") ?? "0") ?? 0,
                    delayMs: Double(arg("imp-delay") ?? "0") ?? 0,
                    spikeMs: Double(arg("imp-spike") ?? "0") ?? 0,
                    spikeHz: Double(arg("imp-spike-hz") ?? "0.3") ?? 0.3,
                    untilS: Double(arg("imp-until") ?? "0") ?? 0)
if impair.enabled {
  wire.impair = impair
  if impair.holdsPackets { wire.armDelayQueue() }
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
  // Time-based rather than counted, because the wait below can now end early and
  // a counter would shorten the warm-up by however often somebody spoke.
  let fastUntil = Date().addingTimeInterval(3.6)
  while true {
    wire.sendTimeProbe()
    // ── THE CUE CANNOT WAIT FOR THE NEXT SECOND ──────────────────────────────
    //
    // The far end's floor state rides this packet, and this packet settles to one
    // a second. A cue whose entire claim is that it lands inside a syllable was
    // therefore arriving up to a second after the syllable, and on a live call it
    // showed a listening noise through six seconds of somebody talking.
    //
    // So the wait is broken into 20 ms slices and ends the moment the
    // classification moves -- the next line of the loop is the probe. 20 ms is a
    // twentieth of the shortest listening noise and a fiftieth of a bid, under
    // the resolution of the thing being reported, and this thread is asleep for
    // every one of those slices.
    //
    // ── AND THE STEADY BEAT CANNOT EQUAL THE STALENESS LIMIT ─────────────────
    //
    // The floor stops believing far cues `staleMs` (1000 ms) after the last one,
    // and this probe settled to exactly 1000 ms -- zero margin, so one late or
    // lost probe put the far end's floor into full-open fallback for a second
    // at a time. Measured on call 8q0nwcduogm2: the TALKING end ran on fallback
    // for 20.1% of the call, both ears open, which is where the echo lived.
    // Three probes now fit inside one staleness window; 32 bytes at 3/s is
    // nothing against a 3 Mbps call.
    let until = Date().addingTimeInterval(Date() < fastUntil ? 0.15 : 0.3)
    while Date() < until {
      Thread.sleep(forTimeInterval: 0.02)
      if wire.vocalChanged() || wire.predictCrossed() {
        if ProcessInfo.processInfo.environment["KIN_CUE_DEBUG"] != nil {
          fputs(String(format: "cue out %.3f  me -> %d\n", Date().timeIntervalSince1970,
                       Audio.sharedGate.vocal.rawValue), stderr)
        }
        break
      }
    }
    if let th = tsync.thetaNs {
      audio.thetaMs = Double(th) / 1e6
      audio.thetaValid = true
      gThetaMs = audio.thetaMs
      gThetaValid = true
    }
  }
}.start()

// ── THE OTHER END HUNG UP ────────────────────────────────────────────────────
//
// The one message that ends a call. Assigned BEFORE the receive loop starts, not
// after: this is the same ordering trap as `Update.onPending` and `beforeReexec`
// -- a handler installed after the thread that fires it can miss the very first
// event, and the first event here is somebody pressing the button.
//
// It runs on the receive thread, so everything slow is handed to a queue and the
// exit is the last thing. The record goes first: if anything below this line
// hangs, the call must already be over on this disk, or the next launch would
// reopen a room the person deliberately left.
wire.onPeerBye = {
  Resume.end(why: "they hung up")
  Metrics.count("bye_recv_inband")
  Metrics.fact("outcome", "they hung up")
  shuttingDown = true
  display?.controls?.setStatus("the other person hung up")
  fputs("call: the other person hung up -- ending\n", stderr)
  // Off the receive thread: postFinalBeat waits on a semaphore for up to 1.5 s,
  // and blocking the media reader for that long would stall audio for anybody
  // else still arriving. Nothing is left to receive, but the rule holds anyway.
  DispatchQueue.global().async {
    postFinalBeat(why: "they hung up")
    exit(0)
  }
}

let t = Thread { wire.recvLoop(into: audio.ring, video: vasm) }
t.start()

// ── THE ONE LINE THAT WOULD OPEN THE MICROPHONE ───────────────────────────
//
// Skipped while a ring is only being offered. Everything above this point is
// receive-side -- the rendezvous, the socket, the assembler, the decoder and the
// display -- and none of it touches a device. `start()` is what opens the input
// and output units, and it is also what arms the capture callback that sends. So
// not calling it is simultaneously "no green light", "nothing on the wire" and
// "their voice is not played into this room". One line, three guarantees, and no
// new state to get out of step.
if ringPreview {
  fputs("ring: audio engine not started -- nothing captured, nothing sent,"
      + " nothing played\n", stderr)
} else {
do { try audio.start() } catch {
  fputs("audio start failed: \(error)\n", stderr)
  fputs("if this is a permission error, macOS must be allowed to use the microphone for the terminal running this.\n", stderr)
  exit(1)
}
}

// ── The report ──────────────────────────────────────────────────────────────
//
// Once a second, and every line is a RATE from differenced cumulative counters.
// Not a moving average: a windowed average read across a state change has
// already inverted a result in this project, and a rate you can verify by
// arithmetic is worth more than a smooth one.
var last = (sent: 0, recv: 0, played: 0, concealed: 0, dup: 0, tooOld: 0, jumps: 0, cap: 0)
var lastBytes = (up: 0, down: 0)
var lastGen = (a: 0, v: 0, p: 0, c: 0, fec: 0)
var lastUiLost = 0, lastUiRecovered = 0
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
    // A TRICKLE OF LATE PACKETS IS NOT A BUFFER THAT IS TOO SMALL.
    //
    // Measured over 568 s: the buffer ratcheted 6 -> 7 -> 8 -> 9 -> 10 and m2e
    // climbed 13.15 -> 15.84 ms with no recovery, on grows of "3 late arrivals",
    // "5", "3", "11", "3" -- three packets out of three thousand. And the slack
    // ROSE at every step (2.69 -> 3.36 -> 4.70 -> 5.35 ms of margin) while it kept
    // growing, which is the proof: four grows did not stop the lateness, so a
    // bigger buffer does not prevent it. Those are far-tail scheduling outliers,
    // and chasing a long tail with buffer makes everyone wait to rescue a few
    // packets -- the queue-tolerance mistake in another costume.
    //
    // Total cost of NOT growing: 25 concealed packets in 568 s, one 0.67 ms gap
    // every 23 seconds, which is inaudible. Cost of growing: 2.7 ms of latency on
    // every word, forever. That is not a close call.
    //
    // So lateness has to be SUSTAINED to count. Thin margin still grows instantly,
    // because that is the signal that the buffer really is too small.
    let GROW_LATE_MIN = 8      // per 2 s window, out of ~3000 packets (0.27%)
    // ── How much proven margin is worth one packet of latency ─────────────────
    //
    // 2.0 ms pinned the buffer one packet high for entire calls, and where it
    // pinned was decided by the first fifteen seconds. Measured on a clean rig,
    // both ends running 1.6 Mbps of video: at jit 4 the steady-state head sat at
    // 1.84 ms and never once cleared 2.0 in fifty windows, so the descent stopped
    // at 4 and stayed for the whole call -- 0.67 ms of pure latency, charged to
    // every syllable, for a threshold missed by 0.16 ms. With video OFF the same
    // build reached jit 3, ran 87 seconds with head 1.19 ms and concealed NOTHING.
    // So 2.0 was not the safety line, it was an untested constant that happened to
    // be above the margin one traffic mix produces.
    //
    // `head` is already the headroom that would REMAIN one packet smaller, and it
    // is computed from the WORST arrival in the window, not a percentile. So the
    // break-even point is head > 0, and this constant is pure extra safety on top
    // of a worst-case measurement. 1.0 ms is still 1.5 packets of it.
    //
    // Traded against more evidence, not less: the hold below goes to 5 windows in
    // both cases, so a smaller margin has to hold for 10 s rather than 4.
    let SHRINK_ABOVE_MS = arg("jit-shrink-margin").flatMap { Double($0) } ?? 1.0
    let SHRINK_HOLD = 5         // consecutive 2 s windows -- 10 s of agreement
    // Was 2. A smaller margin buys its way in with more agreement, so the
    // descent from the deliberately safe start is no longer the fast path.
    let SHRINK_HOLD_FAST = 5
    var calm = 0
    var lastConcealed = 0
    var lastSnapsBehind = 0
    var lastLate = 0
    var lastNearLate = 0
    var lastStarved = 0
    var deepRefused = 0
    var enoughRefused = 0
    let STARVE_AUDIBLE_PCT = Double(arg("starve-pct") ?? "0.02") ?? 0.02
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
    var fecLocalWarned = false
    // A LEVEL THAT FAILED IS REMEMBERED. Without this the controller shrinks,
    // hears a click, grows, waits out its hold and shrinks into the same click
    // forever -- observed on this rig cycling 2 -> 1 -> 2 -> 1 with three
    // concealed packets each lap. Backoff doubles, so a path that genuinely
    // improves is still re-probed, just not at the cost of a click a minute.
    var growSuppressed = 0       // thin-margin grows refused because the governor was still moving
    var marginExcused = 0        // ...and refused because the far end, not the path, caused the dip
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
      let near = r.nearLate - lastNearLate
      lastNearLate = r.nearLate
      // Of the late arrivals in this window, how many missed by less than one
      // packet. Those are the ones growing by one packet would have saved; the
      // rest are outliers that a buffer can only catch by covering the whole
      // excursion, and covering it costs that much on every word forever.
      let deep = late - near

      // REDUNDANCY FOLLOWS THE EVIDENCE, not a setting. It doubles the audio
      // payload, so a clean call must not pay for it -- and a call that IS losing
      // packets should not wait for anyone to notice. One lost packet in a
      // two-second window turns it on; thirty seconds clean turns it off.
      //
      // Driven by LOST, not by concealed: concealment also covers starvation, and
      // a second copy of a packet that has not been sent yet is not a thing.
      //
      // AND IT IS THE PEER'S LOSS THAT MATTERS, not this machine's. Redundancy
      // here protects the path from here to there, and only the far end can see
      // what that path did. Reading the local counters -- which is what this did
      // until now -- protects the wrong direction; it is right only when the two
      // directions are equally lossy, which the loopback rig always is and a real
      // asymmetric uplink never is.
      let usePeer = wire.peerReportsLoss
      let lostTotal = usePeer ? wire.peerRxLost : r.concealLost
      let recTotal = usePeer ? wire.peerRxRecovered : r.recovered
      if !usePeer, !fecLocalWarned, t > 20 {
        fecLocalWarned = true
        fputs("redundancy: the far end does not report its receive loss (older build), "
            + "so this is steering on LOCAL loss -- correct only if both directions "
            + "lose equally\n", stderr)
      }
      // A peer restart zeroes its counters, so the delta can be negative. That is
      // not a repair, it is a new baseline.
      var lostNow = lostTotal - lastLostForFec
      if lostNow < 0 { lostNow = 0; fecRecovered0 = recTotal; fecLost0 = lostTotal }
      lastLostForFec = lostTotal
      if fecAllowed, lostNow > 0, !audio.redundancy, t >= fecUselessUntil {
        audio.redundancy = true
        fecRecovered0 = recTotal
        fecLost0 = lostTotal
        fecWindows = 0
        fputs("redundancy ON (\(lostNow) lost in 2 s\(usePeer ? ", as reported by the far end" : ", LOCAL -- peer does not report")) "
            + "-- each packet now carries the previous one\n", stderr)
        fecCalm = 0
      } else if audio.redundancy {
        fecWindows += 1
        // Judge it on its own record, once there is enough of one to judge. A
        // recovery rate this low means the losses are bursts, and an offset of one
        // packet cannot reach past a burst -- so the bandwidth is being spent for
        // almost nothing and is better not spent.
        let rec = max(0, recTotal - fecRecovered0)
        let lost = max(0, lostTotal - fecLost0)
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
      // Attribution, not just a count. Only a BACKLOG snap is evidence that a
      // bigger buffer would not have helped; a starvation snap is the opposite.
      let snappedBehind = r.snapsBehind - lastSnapsBehind
      lastSnapsBehind = r.snapsBehind
      // ── What growing is FOR, and when it has finished ──────────────────────
      //
      // A buffer exists to stop starvation. So the question "should it grow?" has
      // an answer that does not depend on any threshold about margins or counts:
      // grow while starvation is still audible, and stop when it is not.
      //
      // Starvation, specifically -- not concealment. Concealment also covers lost
      // packets, and no buffer size catches a packet that was never sent. That
      // distinction already exists in the ring and was already being used for the
      // redundancy controller; this is the same evidence answering the other
      // question.
      //
      // Why a rule and not a judgement: on a path that stalls 15 ms every three
      // seconds the controller grew from 6 packets to 26 and was still climbing at
      // four minutes, converging on "cover the worst excursion" -- 15 ms of latency
      // on every word, forever, to avoid concealing 1% of packets in 0.67 ms
      // pieces that are now filled at the speaker's own pitch. The project made
      // exactly this trade by hand once before (25 concealed packets in 568 s is
      // inaudible against 2.7 ms on every word). Writing it down makes it apply
      // every time instead of whenever someone reads a log.
      //
      // 0.02% is one 0.67 ms gap every three seconds at 1500 packets/s. Where
      // exactly the audible line sits is a listening question, not a measurement
      // one, so the number is a flag and the log always says what was traded.
      let starved = r.concealStarved - lastStarved
      lastStarved = r.concealStarved
      let expected = 2.0 * SR / Double(FPP)
      let starvedPct = Double(starved) / expected * 100.0
      let starving = starvedPct > STARVE_AUDIBLE_PCT
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
      // THE SAME RULE THE SHRINK BRANCH ALREADY OBEYS, APPLIED TO GROWING.
      //
      // The comment above says slack describes the cursor rather than the network
      // whenever the governor has not converged. That was applied to shrinking and
      // not to growing, and the asymmetry is a shrink-grow oscillation: the level
      // goes 4 -> 3, the governor works harder to hold the new target, the slack
      // distribution widens while it hunts -- measured on the published 0.11.0
      // binary, the p01/p50 gap was 0.02 ms at jit 4 and 1.27 ms in the one window
      // at jit 3 -- p01 reads 1.04, and the controller grows straight back and
      // marks 3 unsafe with a doubling backoff. It then spends the rest of the call
      // 0.67 ms worse on the strength of a measurement of its own transient.
      //
      // LATENESS STILL GROWS INSTANTLY, converged or not. A late arrival is not a
      // margin estimate: the packet's play time passed before it arrived, which is
      // a fact about the packet, not about the cursor. The emergency path is
      // untouched. Only the JUDGEMENT waits for the evidence to mean what it says.
      if p01 < GROW_BELOW_MS, !converged { growSuppressed += 1 }
      // AND ATTRIBUTE THE THIN MARGIN, now that it can be attributed.
      //
      // The cadence instrument separates the two halves of "arrival": the gap
      // between consecutive CAPTURE stamps is the far end's own emission cadence,
      // and the gap between arrivals is that plus the path. Measured on loopback:
      // sender p99 0.67 max 1.33, arrival p99 0.70 max 1.37, nominal 0.67. The path
      // and this machine contribute 0.03 ms. THE ENTIRE TAIL IS THE FAR END MISSING
      // AN INPUT WAKEUP -- exactly 2x nominal, one skipped packet slot, 4-10 times
      // per 450k callbacks.
      //
      // A bigger buffer here does absorb that. It also charges every syllable for
      // the rest of the call to cover a 0.67 ms hiccup that arrives once every
      // twenty seconds with 1.3 ms still to spare and conceals NOTHING. That is the
      // same trade this controller already refused for a trickle of late packets,
      // and refusing it again is the consistent answer -- but only when the dip is
      // actually explained and nothing was actually concealed.
      let senderGap = r.ipiCapWinMax
      let senderHiccup = senderGap > pktMs * 1.5
      r.ipiCapWinMax = 0
      let excusedDip = p01 < GROW_BELOW_MS && senderHiccup && conc == 0 && late == 0
      if excusedDip { marginExcused += 1 }
      // ── I TRIED TO NARROW THIS VETO AND THE MEASUREMENT SAID NO ──────────────
      //
      // The veto reads a backlog snap as "this machine stalled, so a bigger buffer
      // would have prevented nothing". That justification is genuinely wrong for a
      // bursty path -- a link that holds packets 120 ms and releases them in a
      // clump leaves the same over-full ring as a callback that did not run -- and
      // the two are separable here: a render stall makes the CURSOR late and the
      // packets punctual, a burst makes the PACKETS late and starves first.
      //
      // So the veto was narrowed to `snappedBehind > 0 && snappedPast == 0 &&
      // late == 0`. Against known inputs it bought almost nothing and cost real
      // audio on a clean path:
      //
      //   --imp-spike 120 --imp-spike-hz 1   10.00% -> 9.59% concealed (buffer 8 -> 13)
      //   clean, 3 runs each                 0.00 / 0.00 / 0.54%  ->  0.22 / 0.83 / 4.98%
      //
      // The spike case barely moved because a 120 ms hold once a second IS 12% of
      // dead air unless the buffer swallows the whole 120 ms, which is a latency
      // price the rest of this file exists to refuse. And the clean path got worse
      // because growing more readily moves the cursor, the move starves, the
      // starvation argues for growing again -- the self-feeding transient the
      // comments above already warn about twice.
      //
      // Kept as a comment rather than deleted because the reasoning is sound and
      // the conclusion is still no: the flaw is real, and fixing it is not worth
      // what it costs. What DID survive is the attribution itself -- snapsBehind
      // and snapsPast are now separate counters and ride in every beat, so the
      // question "was the buffer too small, or did this machine stall" is
      // answerable from a call record instead of from a guess.
      if snappedBehind > 0 {
        calm = 0
        fputs("jit: \(snappedBehind) backlog snap(s), \(conc) concealed -- stall, not jitter;"
            + " holding at \(audio.jitTarget)\n", stderr)
      } else if excusedDip {
        // Held, not grown, and said out loud -- a controller that silently declines
        // to act looks identical to one that never saw anything.
        calm = 0
        fputs("jit: slack p01 \(String(format: "%.2f", p01)) ms but the far end skipped an input"
            + " wakeup (cadence gap \(String(format: "%.2f", senderGap)) ms vs \(String(format: "%.2f", pktMs)) nominal),"
            + " 0 concealed, 0 late -- holding at \(audio.jitTarget)\n", stderr)
      } else if !starving, audio.jitTarget > JIT_MIN + 1,
                (late >= GROW_LATE_MIN || p01 < GROW_BELOW_MS) {
        // The thing a buffer prevents is not happening. Whatever the margin looks
        // like, there is nothing left for another packet of latency to buy.
        enoughRefused += 1
        calm = 0
        if enoughRefused % 10 == 1 {
          fputs("jit: \(late) late, slack p01 \(String(format: "%.2f", p01)) ms, but starvation is"
              + " \(String(format: "%.3f", starvedPct))% of packets (\(starved) in 2 s) -- under the"
              + " \(STARVE_AUDIBLE_PCT)% line, so holding at \(audio.jitTarget) and concealing the"
              + " excursions at the pitch period rather than buying \(String(format: "%.2f", pktMs)) ms"
              + " more on every word\n", stderr)
        }
      } else if late >= GROW_LATE_MIN, near < GROW_LATE_MIN, p01 >= GROW_BELOW_MS {
        // Late, but not by an amount a packet of buffer reaches, and the margin is
        // fine. Chasing this is the queue-tolerance mistake wearing a new hat.
        deepRefused += 1
        calm = 0
        if deepRefused % 5 == 1 {
          fputs("jit: \(late) late arrivals but only \(near) missed by under one packet"
              + " (\(deep) were deeper), slack p01 \(String(format: "%.2f", p01)) ms"
              + " -- one more packet would not have caught them; holding at \(audio.jitTarget)."
              + " Deep excursions are concealed at the pitch period instead.\n", stderr)
        }
      } else if (late >= GROW_LATE_MIN && near >= GROW_LATE_MIN) || (p01 < GROW_BELOW_MS && converged) {
        if audio.jitTarget < JIT_MAX {
          audio.jitTarget += 1
          audio.jitGrows += 1
          // What just failed was the level we were AT, so nothing below the new
          // one is safe either.
          unsafeBelow = max(unsafeBelow, audio.jitTarget)
          probeAt = t + backoff
          // Capped low on purpose. At 900 s a single bad minute locked the
          // buffer high for a quarter of an hour, and a path that recovers
          // deserves to be re-probed sooner than that.
          backoff = min(backoff * 2, 120)
          fputs("jit -> \(audio.jitTarget) (grew: \(late) late arrivals, \(near) of them by under one packet, slack p01 \(String(format: "%.2f", p01)) ms"
              + (growSuppressed > 0 ? ", \(growSuppressed) refused mid-slew" : "")
              + (marginExcused > 0 ? ", \(marginExcused) refused as far-end hiccups" : "") + ")"
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
var beatTick = 0
/// Held so the sources are not deallocated the moment the loop above ends.
var signalSources: [DispatchSourceSignal] = []
/// The last per-second figures the report loop computed. The final beat used to
/// send zeros for these, which the dashboard then displayed as a call that used
/// 0.00 Mbps -- a made-up number is worse than a missing one.
var lastRates = (up: 0.0, down: 0.0, played: 0, concealed: 0, cap: 0)
/// Percentiles the report loop already computed. leaveCall and SIGTERM read
/// these instead of sorting the live histogram — that sort was the hang-up crash.
var lastM2e = (p50: Optional<Double>.none, p95: Optional<Double>.none, p99: Optional<Double>.none)
/// Set the moment a quit is requested. Without it the report loop kept beating
/// during the handler's grace period and posted a LIVE beat after the FINAL one
/// -- so the last beat of the call was not the final beat, and a dashboard that
/// preferred `final` showed a clean snapshot while hiding the second in which
/// the peer vanished and everything was concealed. A record is only final if
/// nothing can be written after it.
nonisolated(unsafe) var shuttingDown = false
/// Video figures, stashed by the report loop's video section for the beat that
/// follows it at the end of the same pass.
nonisolated(unsafe) var videoBeat: [String: Any] = [:]
/// Previous-tick values for the picture-quality controller.
nonisolated(unsafe) var lastVqLost = 0, lastVqConc = 0, lastVqJit = 0
nonisolated(unsafe) var lastVqPeerLost = 0, lastVqPeerRec = 0
/// Whether `lastVqPeerLost`/`lastVqPeerRec` have been set from a real report yet.
/// See the priming block at the controller: the peer's counters are cumulative
/// since ITS process start, so subtracting a zero baseline books the peer's entire
/// history as one second of harm.
// Pause bookkeeping. Seconds rather than events alone: two pauses of one second
// each and one pause of forty are the same count and completely different calls.
nonisolated(unsafe) var vPausedSecs = 0
nonisolated(unsafe) var vPeerPausedSecs = 0
nonisolated(unsafe) var vPeerPauses = 0
nonisolated(unsafe) var lastPeerPaused = false
nonisolated(unsafe) var lastPeerCamOff = false
nonisolated(unsafe) var lastPeerMuted = false
nonisolated(unsafe) var vqPrimed = false
/// Separate from `vqPrimed`: the peer's baseline is only valid once the peer has
/// actually reported. See the comment at the priming site.
nonisolated(unsafe) var vqPrimedPeer = false
nonisolated(unsafe) var vqWarnedLocal = false

// Everything the beat reads now exists. Set HERE, on the line after the last of
// those globals, so the flag cannot drift away from the thing it describes.
beatReady = true

/// One beat's worth of fields. Raw numbers only -- no verdicts, no thresholds.
/// The dashboard decides what "good" means, so changing that opinion does not
/// need every installed copy to update first.
func audioBeat(uptime: Double, up: Double, down: Double,
               played: Int, concealed: Int, cap: Int,
               p50: Double?, p95: Double?, p99: Double?) -> [String: Any] {
  // A BEAT FOR A CALL THAT NEVER STARTED.
  //
  // Every global below -- `audio`, `tsync`, `vg2g`, `videoBeat` -- is created by
  // the top-level code AFTER the rendezvous. The window and its Leave button are
  // created BEFORE it. So `leave` clicked while the title still says "waiting for
  // the other person" ran this function against zero-filled memory and read
  // `audio.ring` off a null pointer: SIGSEGV at 0x40, which is exactly where
  // `ring` sits in Audio's layout. Confirmed from a user's 0.44.0 crash report
  // (main.swift:1800, leaveCall, closure #15) and reproduced with
  // `--room <empty> --press leave,leave`. Fourth instance of this shape in this
  // file: `mute` (Audio.swift's header) and `pressControl` both carry the scar.
  //
  // The beat is NOT skipped. A person who waited thirty seconds and gave up is
  // the single most interesting thing this app can report, and a call that ends
  // with no final record at all reads on the dashboard like a call still running.
  // So it goes out with the numbers that are honestly known -- the caller passes
  // those by value -- and `pre_connect` says why the rest is missing, instead of
  // zeros pretending to be measurements.
  //
  // The percentiles are dropped rather than forwarded on this path. `lastM2e` is
  // one of the globals that does not exist yet, and a zero-filled
  // Optional<Double> does not read back as nil -- Double has no spare bits, so
  // the tag byte is 0 and the value reads as `.some(0.0)`. Forwarding it would
  // post a mouth-to-ear of 0.00 ms for a call with no audio at all, which is the
  // one kind of number this file refuses to invent.
  guard beatReady else {
    // ── WHAT IS TRUE BEFORE A CALL CONNECTS IS STILL TRUE ────────────────────
    //
    // The counters below are not measurements of a media pipeline that does not
    // exist yet -- they are a record of what the PERSON did, and it is complete
    // whether or not anyone ever answered. Leaving them out meant a call that
    // never connected reported no button presses at all, which is exactly the
    // call where somebody pressed things and gave up: three runs pressing eight
    // controls each produced `taps` absent, `events` absent, every time.
    let m = Metrics.snapshot()   // same call, one lock, see the note below
    return [
      "uptime_s": uptime,
      // Zero because the report loop never ran, not because it measured zero --
      // `pre_connect` is what tells those two apart.
      "up_mbps": up, "down_mbps": down,
      "played_ps": played, "conceal_ps": concealed, "cap_ps": cap,
      "pre_connect": 1,
      "taps": m.taps, "tap_fails": m.fails, "marks": m.marks, "events": m.counts,
      "facts": m.facts,
      "mic_access": gMicAccess, "io": Audio.ioKind,
      "mic_muted": (display?.controls?.micMuted ?? false) ? 1 : 0,
    ]
  }
  let r = audio.ring
  let mSnap = Metrics.snapshot()
  // Sampled exactly once per beat, and read many times below: two calls would
  // be two DIFFERENT windows sharing one name, and the second would report the
  // microseconds between them rather than the beat.
  let pwr = Power.sample()
  var f: [String: Any] = [
    "uptime_s": uptime,
    "up_mbps": up, "down_mbps": down,
    "played_ps": played, "conceal_ps": concealed, "cap_ps": cap,
    "jit": audio.jitTarget,
    // ── THE AUDIO FACTS THE DIAGNOSIS WAS ASKING FOR ────────────────────────
    //
    // Every audio verdict on the server reads fields the client had never sent:
    // in_rate, out_rate, aec_on. A rule whose evidence never arrives returns the
    // same "unknown" as a healthy call, which is how a call nobody could hear
    // produced a clean dashboard.
    // ── THE FAR END, THE MIC, AND THE PATH ──────────────────────────────────
    //
    // All nine of these were already sitting in memory and none of them were
    // reported, which is why the dashboard could not name either fault from a
    // real call: "they cannot hear me" needs the PEER's numbers, and "why is the
    // picture soft" needs to know whether we are on a relay.
    //
    // `peer_rx_lost` is the closest thing available to "is the far end actually
    // playing what I send". The true answer needs the peer's played count, and the
    // probe packet carries exactly two counters today (Net.swift appendRxReport),
    // so that one is a wire change and therefore two releases away -- an old peer
    // cannot send a field it has never heard of.
    // ── WHICH BUTTON, HOW MANY TIMES, AND DID IT WORK ───────────────────────
    //
    // Four objects rather than forty fields, so `packFields` can drop the whole
    // group under the size cap instead of truncating one -- a truncated JSON
    // prefix once turned an oversized beat into a record that read as fully
    // blind. Empty dictionaries are sent deliberately: "nobody pressed anything"
    // and "the field went missing" must not look alike.
    // One snapshot, not four: the previous line called it once per field, which
    // took the lock four times and could interleave a camera switch between them.
    "taps": mSnap.taps, "tap_fails": mSnap.fails,
    "marks": mSnap.marks, "events": mSnap.counts,
    // What this call was made WITH -- camera, its pixel format, the encoder, the
    // audio devices. The result numbers say a call was bad; these say what it was
    // running on, which is the half you need to fix it rather than notice it.
    "facts": mSnap.facts,
    // The far end's own state, from the TPKTY arm. `peer_played` is what makes
    // "they cannot hear me" a verdict instead of a guess: a peer playing nothing
    // while we send 1500 packets a second is one-way audio, and no amount of
    // local instrumentation could ever have said so.
    "peer_played": wire.peerPlayed, "mute": wire.peerMuted ? 1 : 0,
    "peer_q_level": wire.peerQLevel, "peer_status": wire.peerStatus,
    "peer_state_reports": wire.peerReportsState ? 1 : 0,
    "sig_rms": audio.sigRms, "cap_callbacks": audio.capCallbacks,
    // ── THE THREE QUESTIONS A PERSON ACTUALLY ASKS ABOUT AUDIO ────────────────
    //
    // "Was I too loud / distorted" (clipping, which nothing downstream can undo),
    // "did I lose a word" (the LONGEST hole, not the average number of holes),
    // and "did they hear themselves" (how long the canceller was leaking, in
    // seconds, rather than a correlation nobody can act on).
    "a_mic_peak": audio.micPeak,
    "a_mic_rms": audio.micRms,
    "a_clip_pct": audio.micSamples > 0
      ? Double(audio.micClipped) * 100.0 / Double(audio.micSamples) : 0,
    // How much of the call the correlation veto refused to classify as a voice
    // -- sound the level test passed and the echo detector recognised as this
    // machine's own speaker. Zero on a healthy call; the 0.93.0 leak it exists
    // for would have read ~90% at the listening end.
    "a_corr_veto_pct": audio.micSamples > 0
      ? Double(Audio.sharedGate.vetoFrames) * 100.0 / Double(audio.micSamples) : 0,
    "a_conceal_ms_max": Double(audio.concealMaxRun) * 1000.0 / SR,
    "a_quality_s": audio.qualityTicks,
    "floor_held_pct": audio.floorHeldPct, "mic_access": gMicAccess,
    // ── THE FLOOR'S OWN NUMBERS, WHICH NOTHING PUBLISHED ────────────────────
    //
    // `floor_held_pct` above is named for the floor and does not measure it: it
    // counts the local voice gate and ignores `floorGain` entirely. So a call
    // could be investigated end to end -- both ends, every beat -- without ever
    // learning whether the floor muted a microphone once. It could not.
    //
    // These three are the fractions that answer it, and they existed already;
    // they were printed under `--floor-debug`, which no real call passes.
    "floor_blocks": audio.turns.floorBlocks,
    // What the turn-end predictor is actually saving. It was read by the floor
    // and assigned nowhere until 0.92.0, so these start at the first release
    // where the number means anything.
    // The idle echo guard: how much of the call it muted a mic that would
    // otherwise have sat live next to a playing loudspeaker, and how much of the
    // call it could have. Both, because a bare count has no denominator.
    "echo_guard_pct": audio.turns.floorBlocks > 0
      ? Double(Audio.sharedFloor.echoGuardBlocks) / Double(audio.turns.floorBlocks) * 100 : 0,
    "echo_guard_idle_pct": audio.turns.floorBlocks > 0
      ? Double(Audio.sharedFloor.guardableBlocks) / Double(audio.turns.floorBlocks) * 100 : 0,
    "playout_rms": audio.playoutRmsNow,
    "predict_releases": Audio.sharedFloor.predictedReleases,
    "predict_saved_ms": Audio.sharedFloor.predictedSavedMs,
    "predict_far_releases": Audio.sharedFloor.farPredictedReleases,
    "predict_far_saved_ms": Audio.sharedFloor.farPredictedSavedMs,
    "predict_p_now": Audio.turnEndProb,
    "predict_peer_p_now": Audio.peerTurnEndProb,
    "predict_peer_p_peak": Audio.sharedFloor.farEndProbPeak,
    "floor_muted_pct": audio.turns.floorBlocks > 0
      ? Double(audio.turns.floorHeldBlocks) / Double(audio.turns.floorBlocks) * 100 : 0,
    // The share of the call this end had stopped believing the far end's cues
    // and was running on the local gate alone. An instrument that cannot see its
    // own fallback reports the fallback as health.
    "floor_fallback_pct": audio.turns.floorBlocks > 0
      ? Double(audio.turns.floorFallbackBlocks) / Double(audio.turns.floorBlocks) * 100 : 0,
    // Which floor is in force, and strict's own honesty meter: the share of the
    // call this end was on the wire while the far end's decoded stream also
    // carried voice. The stated cost of a simultaneous start is deadlock plus a
    // hop; anything past that is the rule failing.
    "floor_strict": Audio.sharedFloor.cfg.strict ? 1 : 0,
    "strict_overlap_pct": audio.turns.floorBlocks > 0
      ? Double(audio.turns.strictOverlapBlocks) / Double(audio.turns.floorBlocks) * 100 : 0,
    // ── AND THE MICROPHONE'S LEVEL, WHICH DECIDES ALL OF IT ─────────────────
    //
    // `mic_gain_end` was a fact and said 0.15 -- the floor of a loop that had
    // given up. Whether it was STUCK there is the thing worth knowing.
    "mic_trim": Double(audio.inputTrim), "mic_trim_moves": audio.trimMoves,
    "mic_gain_rail": audio.gainAtRail ? 1 : 0,
    // Turn-taking is the product now, so it reports like the product.
    "turn_claims": audio.turns.claims, "turn_granted": audio.turns.claimsGranted,
    "turn_to_floor_p50": audio.timeToFloorP50,
    "turn_collisions": audio.turns.collisions,
    "turn_collision_ms": audio.turns.collisionMs,
    "turn_yielded": audio.turns.yieldedToPeer, "turn_peer_yielded": audio.turns.peerYielded,
    "turn_yield_unclear": audio.turns.ambiguousYields,
    "turn_backchannels": audio.turns.backchannels, "turn_escalated": audio.turns.escalated,
    // The deadlock rule, published from BOTH ends so the server can see whether
    // it is splitting them evenly or picking on the same person every call.
    "turn_yields": audio.turns.yields, "turn_yielded_pct": audio.yieldedPct,
    "turn_flaps": audio.turns.gateFlaps,
    "v_rx_w": gRxWidth, "v_rx_h": gRxHeight,
    "peer_rx_lost": wire.peerRxLost, "peer_rx_recovered": wire.peerRxRecovered,
    "peer_reports": wire.peerReportsLoss ? 1 : 0,
    // 1 direct, 2 relayed, 0 not locked yet. A relayed call is a different
    // product to a direct one and the dashboard could not tell them apart.
    "route": wire.lockedFrom.hasPrefix("relay") ? 2 : (wire.lockedFrom.isEmpty ? 0 : 1),
    "turn_ok": wire.turn != nil ? 1 : 0,
    "mic_muted": (display?.controls?.micMuted ?? false) ? 1 : 0,
    // The INSTANT, kept for continuity, and the PEAK beside it -- the final beat
    // of a call that reached 0.71 reported 0.04, so every summary built on the
    // last value said "no echo" about a call with a measured one.
    "echo_corr": audio.echoCorr, "echo_corr_peak": audio.echoCorrPeak, "backchannels": audio.backchannels,
    // ── WHAT THIS CALL COSTS THE BATTERY ──────────────────────────────────
    //
    // A RATE: CPU seconds per wall second since the previous beat, so 0.15 is
    // one seventh of a core. `usr` and `sys` stay apart because they move for
    // unrelated reasons -- a hot loop in one, the audio device and the socket
    // in the other -- and a single number cannot tell them apart.
    //
    // `cpu_valid` is 0 on the first beat of a call: one reading cannot be a
    // rate, and publishing a zero for a thing not measured is exactly the
    // shape that makes a blind instrument read like a healthy one.
    //
    // THESE WERE DELETED BY ACCIDENT AND THE RIG CAUGHT IT. Removing the eight
    // room_* fields took a slice of this dictionary, and the slice began at a
    // comment that sat ABOVE these lines rather than below them -- so the
    // battery telemetry added an hour earlier went out with the feature being
    // retired. Nothing failed to compile; the beats simply arrived with `cpu`
    // absent, which is why the measurement rig checks the FIELD and not the
    // exit code.
    "cpu": pwr.cpu, "cpu_usr": pwr.usr, "cpu_sys": pwr.sys,
    "cpu_valid": pwr.valid ? 1 : 0,
    "threads": pwr.threads, "rss_peak_mb": pwr.rssPeakMb,
    // The eight room_* fields that were here are gone with the detector they
    // reported. They were added and removed the same day: added because the
    // same-room case could not be diagnosed from the server, removed because
    // the case itself was retired as a test artifact. Reporting a feature
    // nobody needs is still something somebody has to read past.
    "floor_claims": audio.floorClaims,
    "dec_luma": gDecLuma,
    "io": Audio.ioKind, "aec_on": Audio.ioKind == "vp" ? 1 : 0,
    // Zero on every build so far. A non-zero number here is a telemetry
    // call that landed on the real-time audio thread and was refused --
    // a latency bug reported as a number instead of as a mystery stall.
    "tel_hot_refused": Metrics.refusedOnAudioThread,
    "agc_on": Audio.agcOn ? 1 : 0, "devbuf": Audio.devBuf,
    "in_rate": Int(audio.hwInRate), "out_rate": Int(audio.hwOutRate),
    "in_lat_ms": audio.inLatencyMs, "out_lat_ms": audio.outLatencyMs,
    // THE DENOMINATOR. Concealment was recorded as a bare count for the whole of
    // this project's life, and a count cannot answer the only question anybody
    // asks of it -- 4657 concealed samples is either a rounding error or a fifth
    // of the call, and nothing in the record said which. `played` is the other
    // half of the ratio: every sample the speaker produced was one or the other.
    "played": r.played,
    "conceal_total": r.concealed, "conceal_lost": r.concealLost,
    "conceal_starved": r.concealStarved,
    "late": r.lateArrivals, "near_late": r.nearLate,
    "snaps": r.snaps, "snaps_behind": r.snapsBehind, "snaps_past": r.snapsPast, "dup": r.dup, "too_old": r.tooOld, "jumps": r.jumps,
    "recv": r.recv, "accepted": r.accepted,
    // Health flags. These are the ones that mean "something is wrong that the
    // person on the call cannot see".
    "stalls": audio.audioStalls, "rate_events": audio.rateEvents,
    "render_errs": audio.xruns, "cap_skips": audio.capSkips,
    "fmt_mismatch": wire.fmtMismatch, "relocks": wire.relocks,
    "peer_restarts": r.restarts,
    // The sample audit is an identity, so a non-zero difference is a real defect
    // and worth carrying even when nothing else looks wrong.
    "audit_delta": audio.renderFrames - (r.playedS + r.concealedS),
    "gate_lock_max": audio.offZeroRunMax,
    "lp_in": wire.lpIn, "lp_out": wire.lpOut, "lp_raws": wire.lpRaws,
    "lp_bad": wire.lpBadDecode,
    "probes": tsync.samples,
  ]
  if let v = p50 { f["m2e_p50"] = v }
  if let v = p95 { f["m2e_p95"] = v }
  if let v = p99 { f["m2e_p99"] = v }
  if let v = r.slack.p(0.50) { f["slack_p50"] = v }
  if let v = r.slack.p(0.01) { f["slack_p01"] = v }
  if let v = tsync.bestRttMs { f["rtt_ms"] = v }
  if let v = tsync.rttSpreadMs { f["rtt_jit_ms"] = v }
  if let c = crypto { f["crypt"] = c.established ? 1 : 0; f["crypt_bad"] = c.openFails }
  if let v = vg2g.p(0.50) { f["g2g_p50"] = v }
  if let v = vg2g.p(0.95) { f["g2g_p95"] = v }
  if vDecoded > 0 { f["v_decoded"] = vDecoded; f["v_sent"] = vSentFrames }
  if let e = venc {
    f["v_encodes"] = e.encodes
    if let v = e.encLatMs.p(0.50) { f["v_enc_ms_p50"] = v }
    if let v = e.encLatMs.p(0.99) { f["v_enc_ms_p99"] = v }
  }
  for (k, v) in videoBeat { f[k] = v }
  return f
}

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
  lastM2e = (p50, p95, p99)
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
  let upMbps = Double(wire.sentBytes - lastBytes.up) * 8.0 / 1_000_000.0
  let downMbps = Double(wire.recvBytes - lastBytes.down) * 8.0 / 1_000_000.0
  lastBytes = (wire.sentBytes, wire.recvBytes)
  fputs("cap \(d.cap)/s  sent \(d.sent)/s  recv \(d.recv)/s  played \(d.played)/s (\(pct)%)"
      + "  conceal \(d.concealed)/s (lost \(r.concealLost) late \(r.lateArrivals)"
      + " recovered \(r.recovered)\(audio.redundancy ? " FEC-on" : ""))  dup \(d.dup)  old \(d.tooOld)  jump \(d.jumps)"
      + (r.restarts > 0 ? " peer-restarts \(r.restarts)" : "")
      + (wire.relocks > 0 ? " re-found-peer \(wire.relocks)" : "")
      + "  \(String(format: "%.2f", upMbps))/\(String(format: "%.2f", downMbps)) Mbps up/down"
      + "   m2e p50 \(f(p50)) p95 \(f(p95)) p99 \(f(p99)) ms"
      + "  slack p50 \(f(r.slack.p(0.50))) p01 \(f(r.slack.p(0.01))) min \(f(r.slackMin == 1e9 ? nil : r.slackMin)) ms"
      + "  jit \(audio.jitTarget) snap \(r.snaps)(\(r.snapsBehind)b/\(r.snapsPast)p)"
      + (wire.fmtMismatch > 0 ? "  VERSION-MISMATCH \(wire.fmtMismatch)" : "")
      + "  net rtt \(tsync.bestRttMs.map { String(format: "%.2f", $0) } ?? "-")"
      + " jit \(tsync.rttSpreadMs.map { String(format: "%.2f", $0) } ?? "-")"
      + " (\(tsync.samples) probes)"
      + (crypto.map { c in c.established
           ? "  crypt on (\(c.sealed)/\(c.opened) sealed/opened, \(c.openFails) bad"
             + (c.plaintextRx > 0 ? ", \(c.plaintextRx) plaintext refused" : "") + ")"
           : "  CRYPT PENDING (plaintext \(c.plaintextTx) sent)" } ?? "  crypt off")
      + (impair.enabled ? "  [IMPAIRED \(impair.description), \(impair.dropped) dropped]" : "")
      + (audio.audioStalls > 0 ? "  [\(audio.audioStalls) capture stall(s) recovered]" : "")
      + (audio.rateEvents > 0 ? "  [\(audio.rateEvents) device rate change(s)]" : "") + "\n", stderr)

  // ── AND TELL THE PERSON ON THE CALL ─────────────────────────────────────────
  //
  // Same numbers, same second, one place. The bar reads from what the report line
  // just computed rather than sampling anything itself, so the window and the log
  // can never disagree about how the call is going -- which is the whole reason
  // the beat is built here too.
  if let c = display?.controls {
    // Concealment as a PERCENTAGE of what should have played, not a count: a count
    // means nothing without a rate behind it, and this is the number that decides
    // whether a person hears a problem.
    let expectedPkts = max(1.0, expected)
    let concealPct = Double(d.concealed) / expectedPkts * 100.0
    // Loss on the path INTO here, before repair -- what the network did, not what
    // survived it.
    let lostNow = Double(r.concealLost - lastUiLost) + Double(r.recovered - lastUiRecovered)
    lastUiLost = r.concealLost; lastUiRecovered = r.recovered
    let lossPct = lostNow / expectedPkts * 100.0
    // ── DO NOT DESCRIBE SOMEBODY WHO HAS LEFT ────────────────────────────────
    //
    // These readouts hold their last value, and this loop republishes them every
    // second, so clearing them on departure was overwritten a second later. After
    // somebody left, the window said
    //
    //     the other person left     breaking up     their camera is off
    //
    // all at once -- which reads as a person still on the call with a bad line
    // and their camera off, the opposite of what happened. A stale fact beside a
    // fresh one is read as current.
    // `peerHeld` joins `peerHere` here rather than replacing it. A held call has
    // not ended -- peerHere stays true so nothing tears down -- but there is
    // nobody on the far end to measure, and these numbers hold their last value
    // and are republished every second. So a peer who vanished mid-call showed
    // "they'll be right back" beside "23 ms - breaking up": a fresh sentence and
    // a stale measurement, and the stale one reads as current. Exactly the fault
    // named above, reached through the one door that did not exist when it was
    // written.
    if peerHere, !peerHeld {
      c.setQuality(m2eMs: p50, concealPct: concealPct, lossPct: lossPct)
    } else {
      c.setQuality(m2eMs: nil, concealPct: 0, lossPct: 0)
      c.setWarning("")
    }
    // ── NO SPEAKER, NO ECHO ───────────────────────────────────────────────────
    //
    // The on-screen echo warning is gone (Controls.setEcho), so this line no
    // longer shows anything. The mute clamp stays because it is the correct
    // reading and not just a display rule: with nothing coming out of the speaker
    // there is no acoustic path back into the microphone, so a correlation
    // measured with playout muted is not echo. Keep it here, next to the mute
    // flag it depends on, for whatever reads the correlation next.
    c.setEcho(audio.mute ? 0 : audio.echoCorr)
    // ── AND THE ONE SENTENCE ABOUT THE ROOM, ON MAIN ─────────────────────────
    //
    // Plain words, no numbers: the person cannot act on a correlation and should
    // not have to read one (`consumer-app-not-a-lab`). It clears itself the
    // moment the detector stops agreeing, which is the half a banner usually
    // gets wrong.
    //
    // `setWarning` assigns `Pill.text`, whose didSet calls `-[NSView
    // _setHidden:]`. From this thread that is an NSException and the process
    // aborts: SIGABRT in `Pill.text.didset` <- `reportLoop`, caught the first
    // time this line ever set a non-empty string on a live call.
    //
    // The `setWarning("")` above has been reached from this same thread for a
    // long time without crashing, and only because of its `guard line !=
    // warnText`: clearing something already clear returns before it touches
    // anything. It is one non-empty warning away from the same abort.
    //
    // Its OWN slot, not the shared one. Written every second into the same pill
    // `Display.setPaused` writes, these two sentences overwrote each other 150
    // times in one rig run -- and because a new warning shows the control row,
    // the row could never fade again. `setRoomWarning` states the fact and lets
    // `CallControls` decide which sentence wins; stating it unconditionally is
    // also what makes it clear itself, with no read-back of the pill to work out
    // whether the last thing in it was ours.
    // The same-room warning was here. Both it and the condition that raised it
    // are gone; the pill still clears itself unconditionally, which is what made
    // stating it every tick the right shape in the first place.
    c.setRoomWarning("")
    // The code both people read aloud. Only exists once the key exchange has
    // happened, and it is stable for the rest of the call.
    if let code = wire.crypto?.safetyCode { c.setSafetyCode(code) }
  }

  // ── WHERE THE BANDWIDTH WENT ────────────────────────────────────────────────
  //
  // Because one number could not answer it. DESIGN 17.105 recorded an
  // "unexplained" send-rate inflation under loss and guessed at the video
  // encoder; the bytes were audio redundancy, which this program turns on
  // deliberately when the path loses packets. The aggregate was not wrong, it was
  // unattributable, and an unattributable number sends you looking in the wrong
  // file. Printed every second so the next surprise arrives pre-attributed.
  // Named `gen`, not `g`: the video block below has its own `g` and a silently
  // shadowed name has already cost this session an hour.
  let gen = (wire.genAudio, wire.genVideo, wire.genProbe, wire.genCtl, wire.genFec)
  let dg = (a: gen.0 - lastGen.a, v: gen.1 - lastGen.v, p: gen.2 - lastGen.p,
            c: gen.3 - lastGen.c, fec: gen.4 - lastGen.fec)
  lastGen = (gen.0, gen.1, gen.2, gen.3, gen.4)
  let mb = { (x: Int) in String(format: "%.2f", Double(x) * 8.0 / 1_000_000.0) }
  fputs("  bytes out: audio \(mb(dg.a)) (repair copies \(mb(dg.fec)))"
      + "  video \(mb(dg.v))  probes \(mb(dg.p))  keyreqs \(mb(dg.c)) Mbps\n", stderr)
  // FEC is a 100% surcharge on audio, and it buys repair of ISOLATED loss. Said
  // out loud when it is on, because doubling what you send down a path that is
  // already dropping packets is the textbook first step of congestion collapse,
  // and this program should never do that without the number being visible.
  if dg.fec > 0, dg.a > 0 {
    let share = Double(dg.fec) / Double(dg.a) * 100.0
    fputs("  repair overhead: \(String(format: "%.0f", share))% of the audio stream\n", stderr)
  }

  // ── The same numbers, somewhere they survive ────────────────────────────────
  //
  // Built here because this is where every value already is, so the beat and the
  // line above it can never disagree about what the call did. Every five seconds,
  // and once more at the end.
  beatTick += 1
  lastRates = (upMbps, downMbps, d.played, d.concealed, d.cap)
  // Where the milliseconds actually are. cap->send is this machine's send side;
  // recv->play is this machine's receive side including the jitter buffer. What
  // m2e has left over after those two and the two device latencies is the wire.
  // The tail that sets the jitter buffer, split by where it comes from. Nominal
  // is one packet period; anything above it in the sender column is the sender
  // failing to emit on time, and anything above it only in the arrival column is
  // the path plus this machine noticing.
  if let cp = audio.ring.ipiCap.p(0.50), let rp = audio.ring.ipiRecv.p(0.50) {
    let nom = Double(FPP) / SR * 1000.0
    let f = { (v: Double?) in String(format: "%.2f", v ?? 0) }
    fputs("  cadence (nominal \(f(nom)) ms): sender p50 \(f(cp)) p99 \(f(audio.ring.ipiCap.p(0.99)))"
        + " max \(f(audio.ring.ipiCapMax))"
        + " | arrival p50 \(f(rp)) p99 \(f(audio.ring.ipiRecv.p(0.99)))"
        + " max \(f(audio.ring.ipiRecvMax))\n", stderr)
  }
  // Split the two stage numbers into CoreAudio's scheduling and this program's
  // own work, because a millisecond nobody can name is a millisecond nobody can
  // remove.
  if let cl = audio.capLag.p(0.50), let sc = audio.sendCost.p(0.50), let rl = audio.renderLead.p(0.50) {
    let fill = Double(FPP) / SR * 1000.0
    fputs("  soft: capLag \(String(format: "%.2f", cl)) ms (fill \(String(format: "%.2f", fill))"
        + " + sched \(String(format: "%.2f", cl - fill)))"
        + "  sendCost \(String(format: "%.2f", sc))"
        + "  renderLead \(String(format: "%.2f", rl))"
        + "  p95 \(String(format: "%.2f", audio.capLag.p(0.95) ?? 0))/"
        + "\(String(format: "%.2f", audio.sendCost.p(0.95) ?? 0))/"
        + "\(String(format: "%.2f", audio.renderLead.p(0.95) ?? 0))\n", stderr)
    // Serviceability, printed every window whether or not it is bad news. A
    // skipped buffer is a doubled gap; the render cost says how close the work is
    // to the deadline it has.
    let budgetUs = Double(Audio.devBuf) / SR * 1_000_000.0
    if wire.lpIn > 0 {
      let ratio = Double(wire.lpIn) / Double(max(1, wire.lpOut))
      fputs("  payload: \(wire.lpIn / 1024) KiB of samples sent as \(wire.lpOut / 1024) KiB"
          + " (\(String(format: "%.2f", ratio))x lossless)"
          + "  raw-fallback \(wire.lpRaws)  bad decodes \(wire.lpBadDecode)\n", stderr)
    }
    // EVERY rendered sample takes exactly one of the two branches, so this is an
    // identity, not an estimate. If it ever fails to hold, a sample was played
    // that no counter saw -- which is the class of bug that made a healthy call
    // look silent.
    let counted = audio.ring.playedS + audio.ring.concealedS
    fputs("  sample audit: played \(audio.ring.playedS) + concealed \(audio.ring.concealedS)"
        + " = \(counted) vs \(audio.renderFrames) rendered"
        + " \(counted == audio.renderFrames ? "(exact)" : "*** MISMATCH \(audio.renderFrames - counted) ***")\n", stderr)
    fputs("  packet gate: \(audio.offZeroMiss) of \(audio.renderTicks) callbacks crossed no"
        + " packet boundary, longest run \(audio.offZeroRunMax)"
        + " (\(String(format: "%.0f", Double(audio.offZeroRunMax) * Double(Audio.devBuf) / SR * 1000)) ms)"
        + "  n \(audio.nHistDescribe)\n", stderr)
    fputs("  buffer \(Audio.devBuf) frames (\(String(format: "%.2f", budgetUs / 1000)) ms):"
        + " skips \(audio.capSkips)/\(audio.capTicks) in, \(audio.renderSkips)/\(audio.renderTicks) out"
        + "  renderErrs \(audio.xruns)"
        + "  work p50 \(String(format: "%.0f", (audio.renderCost.p(0.50) ?? 0) * 1000)) us"
        + " p99 \(String(format: "%.0f", (audio.renderCost.p(0.99) ?? 0) * 1000)) us"
        + " of \(String(format: "%.0f", budgetUs)) us"
        + " (\(String(format: "%.0f", (audio.renderCost.p(0.99) ?? 0) * 1000 / budgetUs * 100))% p99)"
        + "  frames \(audio.capFrames) vs clock, deficit "
        + "\(String(format: "%.0f", audio.capFrameDeficit)) samples "
        + "(\(String(format: "%.2f", audio.capFrameDeficit / SR * 1000)) ms)\n", stderr)
  }
  if let j = audio.jumpAtEdge.p(0.95), audio.jumpAtEdge.count > 4 {
    let rms = audio.sigRms
    fputs("  conceal edges: \(audio.jumpAtEdge.count) sampled, step p95 \(String(format: "%.4f", j))"
        + "  signal rms \(String(format: "%.4f", rms))"
        + (rms > 1e-9 ? "  step/rms \(String(format: "%.2f", j / rms))" : "  step/rms n/a (silent input)")
        + " (\(audio.concealZeros ? "zeros" : audio.concealGrain ? "grain repeat" : "pitch plc"))\n", stderr)
    // The search runs on the render thread. If it ever approached the callback
    // budget it would cause the very glitch it exists to prevent, so its cost is
    // printed beside the result rather than argued about.
    if let us = audio.plcSearchUs.p(0.95), audio.plcSearchUs.count > 0 {
      let budgetUs = Double(FPP) / SR * 1_000_000.0
      fputs("  plc: \(audio.plcSearchUs.count) searches, p95 \(String(format: "%.0f", us)) us"
          + " of a \(String(format: "%.0f", budgetUs)) us callback (\(String(format: "%.1f", us / budgetUs * 100))%)"
          + (audio.plcPeriodMs.p(0.50) != nil
             ? ", period p50 \(String(format: "%.2f", audio.plcPeriodMs.p(0.50)!)) ms"
               + " (\(String(format: "%.0f", 1000.0 / audio.plcPeriodMs.p(0.50)!)) Hz)" : ", no pitch found")
          + "\n", stderr)
    }
  }
  // Is the speaker feeding the microphone? A question worth an answer on every
  // call, not only when a canceller is being tested.
  // Is the speaker feeding the microphone? Not so that anything can subtract it
  // -- nothing subtracts any more -- but because it is the fact that decides
  // whether this end has to take turns at all.
  if audio.echoDelayMs >= 0 {
    let corr = String(format: "%.2f", audio.echoCorr)
    let at = String(format: "%.1f", audio.echoDelayMs)
    // 0.45, not 0.2. The null -- two unrelated speech signals, no echo path at
    // all -- measured 0.26, so a threshold under that reports an echo on every
    // healthy call. The floor was measured before the threshold was chosen.
    let verdict = audio.echoCorr > 0.45
      ? "  -- this machine's speaker reaches its own microphone" : ""
    let sim = audio.echoSim ? "  [SIMULATED echo path armed]" : ""
    fputs("  room: \(corr) correlation at \(at) ms\(sim)\(verdict)\n", stderr)
  }
  // Reported on every call, not only the gated ones: these are turns taken, and
  // a headphone call has those too.
  let t = audio.turns
  let held = String(format: "%.0f", audio.floorHeldPct)
  let ttf = audio.timeToFloorP50 >= 0 ? String(format: "%.0f ms", audio.timeToFloorP50) : "-"
  fputs("  floor: yours \(held)% of the call, \(t.backchannels) listening noises,"
      + " \(t.claims) bids (\(t.claimsGranted) heard, median \(ttf) to be audible)"
      + "  now \(["quiet", "listening", "bidding"][Audio.sharedGate.vocal.rawValue])"
      + (t.yields > 0 ? String(format: "  gave way %d time(s), %.1f%% of the call%@",
                               t.yields, audio.yieldedPct,
                               audio.yieldingNow ? " (NOW)" : "") : "")
      + String(format: "  fed %.2f/%.2f s", Double(fedOut) / SR, Double(fedIn) / SR)
      + (subtitles.map { "  words(\($0.engine)): \($0.requests) asked, \($0.failures) failed,"
                       + " \(String(format: "%.0f", $0.lastMs)) ms, \(subSent) sent \(subGot) got" } ?? "")
      + "\n", stderr)
  if ProcessInfo.processInfo.environment["KIN_GATE_DEBUG"] != nil {
    fputs("  gate: \(Audio.sharedGate.innards)\n", stderr)
  }
  // ── THE TURN LAYER, WITH ITS DENOMINATOR ──────────────────────────────────
  //
  // Printed whenever it decided anything, and printed as FRACTIONS, because a
  // bare count of held blocks says nothing without the number of blocks
  // (`counted-without-a-denominator`). `fallback` is the important one: it is
  // the share of the call during which this end had stopped believing the far
  // end's cues and was running on the local gate alone, and an instrument that
  // cannot see its own fallback reports the fallback as health.
  // ── AND ON EVERY CALL, NOT ONLY A DEBUG ONE ───────────────────────────────
  //
  // The line above is named `floor:` and does not measure the floor. This one
  // does, and it prints unconditionally: the whole point of a readout is to be
  // there on the call somebody is complaining about.
  if t.floorBlocks > 0 {
    let n = Double(t.floorBlocks)
    let muted = Double(t.floorHeldBlocks) / n * 100
    let fb = Double(t.floorFallbackBlocks) / n * 100
    fputs(String(format: "  one-at-a-time: mic muted for the other person %.1f%% of the call"
               + "  (running on the local gate alone %.1f%%)", muted, fb)
        + (audio.gainAtRail
           ? String(format: "  MIC AT THE RAIL, trim %.2f", audio.inputTrim) : "")
        + String(format: "  echo peak %.2f", audio.echoCorrPeak)
        // The predictor, as a saving rather than as a score. `0 turns` here on a
        // call where somebody talked means it is not firing, which is the state
        // this line was added to make impossible to miss.
        + String(format: "  idle-echo guard muted %.0f%% of the call (idle was %.0f%%)",
                 audio.turns.floorBlocks > 0
                   ? Double(Audio.sharedFloor.echoGuardBlocks) / Double(audio.turns.floorBlocks) * 100 : 0,
                 audio.turns.floorBlocks > 0
                   ? Double(Audio.sharedFloor.guardableBlocks) / Double(audio.turns.floorBlocks) * 100 : 0)
        + String(format: "  handed over early %d time(s), saving %.0f ms"
               + " (far %d / %.0f ms, their p peaked %.2f)",
                 Audio.sharedFloor.predictedReleases,
                 Audio.sharedFloor.predictedSavedMs,
                 Audio.sharedFloor.farPredictedReleases,
                 Audio.sharedFloor.farPredictedSavedMs,
                 Audio.sharedFloor.farEndProbPeak) + "\n", stderr)
  }
  if flag("floor-debug"), t.floorBlocks > 0 {
    let n = Double(t.floorBlocks)
    fputs(String(format: "  floor: %@  held %.1f%%  fallback %.1f%%  ear %@  owd %.0f ms\n",
                 ["idle", "MINE", "theirs"][Audio.sharedFloor.state.rawValue],
                 Double(t.floorHeldBlocks) / n * 100,
                 Double(t.floorFallbackBlocks) / n * 100,
                 Audio.earOpen ? "open" : "SHUT", Audio.owdMsNow), stderr)
  }
  if t.collisions > 0 || t.gateFlaps > 0 {
    let avg = t.collisions > 0 ? String(format: "%.0f ms", t.collisionMs / Double(t.collisions)) : "-"
    fputs("  overlap: \(t.collisions) times both talking, \(avg) each"
        + " (who stopped first is not decidable from one end -- see the beat)"
        + (t.gateFlaps > 0 ? "  \(t.gateFlaps) CHOPPY OPENINGS" : "") + "\n", stderr)
  }
  if audio.acoustic {
    let heard = audio.acRound.p(0.50)
    let devSum = audio.inLatencyMs + audio.outLatencyMs
    fputs("  acoustic: \(audio.acHeard)/\(audio.acFired) clicks heard"
        + (heard != nil ? ", speaker->air->mic p50 \(String(format: "%.2f", heard!)) ms" : "")
        + "  vs mic+spk latency \(String(format: "%.2f", devSum)) ms"
        + (heard != nil ? "  => device terms are \(heard! > devSum * 0.6 ? "REAL and separate" : "ALREADY IN THE TIMESTAMPS (m2e overstates)")" : "")
        + "\n", stderr)
  }
  if let cs = audio.capToSend.p(0.50), let rp = audio.recvToPlay.p(0.50) {
    let acct = cs + rp + audio.inLatencyMs + audio.outLatencyMs
    fputs("  stages: cap->send \(String(format: "%.2f", cs))"
        + "  recv->play \(String(format: "%.2f", rp))"
        + "  mic \(String(format: "%.2f", audio.inLatencyMs))"
        + "  spk \(String(format: "%.2f", audio.outLatencyMs))"
        + "  = \(String(format: "%.2f", acct)) ms accounted"
        // ── NAME THE PROPAGATION, OR THE CHECK IS USELESS ────────────────────
        //
        // This said "unexplained 104.89" on an antipodal call, where 103 ms of it
        // was the speed of light. A residual that is 98% propagation trains a
        // reader to ignore the line, which is the opposite of what an accounting
        // line is for -- and this project's whole target is stated as overhead
        // ABOVE propagation, so the interesting number was the one being buried.
        //
        // rtt/2 is the one-way wire time the clock probes measured, so it is
        // subtracted explicitly and what remains is genuinely unnamed.
        + (audio.m2eLast > 0 ? { () -> String in
            let wire = (tsync.bestRttMs ?? 0) / 2.0
            let left = audio.m2eLast - acct - wire
            return ", m2e \(String(format: "%.2f", audio.m2eLast))"
                 + "  = wire \(String(format: "%.2f", wire)) (rtt/2)"
                 + " + \(String(format: "%.2f", acct)) accounted"
                 + " + \(String(format: "%.2f", left)) unnamed"
          }() : "") + "\n", stderr)
  }
  // Say WHY there is no audio, in the same line as the zero. An instrument that
  // reports a zero and not its cause points investigation at the wrong end.
  if vsource != nil || vasm.fragsIn > 0 {
    let e = venc?.encLatMs ?? Quantiles(); var dl = vdec.decLatMs, g = vg2g
    let dv = vDecoded - lastV.dec
    let sv = vSentFrames - lastV.sent
    let mbps = Double(vBytesSent - lastV.bytes) * 8 / 1e6
    lastV = (vDecoded, vSentFrames, vBytesSent)
    let perFrame = sv > 0 ? (vBytesSent - lastVBytesPrev) / max(sv, 1) : 0
    lastVBytesPrev = vBytesSent
    // Stashed for the telemetry beat at the end of the loop. These deltas only
    // exist inside this block, and a beat built before it ran said nothing at all
    // about the picture -- on a video call, which is most of them.
    // ── PUBLISHED WITH ONE STORE, NOT MUTATED IN PLACE ───────────────────────
    //
    // `videoBeat` is iterated by audioBeat(), which the shutdown signal handler
    // also calls -- from a different queue. Mutating a Dictionary in place while
    // another thread walks it is the same defect that crashed the render-callback
    // histogram, just rarer because it needs the call to be ending. Built into a
    // local and assigned once: a reference store, so a reader sees the old map or
    // the new one and both are whole.
    var vb: [String: Any] = [
      "v_enc_ps": sv, "v_dec_ps": dv, "v_mbps": mbps, "v_bytes_frame": perFrame,
      "v_frags": vasm.fragsIn, "v_frames_lost": vasm.missing,
      "v_partial_drops": vasm.dropped, "v_dec_fails": vdec.decFails,
      "v_no_fmt": vdec.noFormat, "v_repair_keys": keyAsksOnLoss,
      "v_key_asks_in": keyAsksIn,
      "v_luma": venc?.lastLuma ?? -1, "v_motion": venc?.lastDiff ?? -1,
      // ── THE TWO QUESTIONS A PERSON ACTUALLY ASKS ABOUT A PICTURE ───────────
      //
      // "Did it go blocky when he moved" and "did it freeze". Neither was
      // answerable from anything above: a rate stays healthy through both.
      //
      // Measured on the decoded far-end picture, not inferred from bitrate. The
      // bitrate version of this failed calibration at full quality and is gone.
      // ── NO PICTURE-QUALITY NUMBER IS COMPUTED FROM THE IMAGE HERE ──────────
      //
      // Three were tried and two were caught by their own calibration:
      //   bits per pixel under motion -- called 23 of 30 frames blocky at FULL
      //     quality, because a talking head is cheap and cheap is not damage;
      //   block-edge contrast -- ranked BACKWARDS (1.356 at quality 0.9, 1.155 at
      //     0.05), because H.264 deblocking erases that signature by design and a
      //     starved picture goes smooth rather than blocky;
      //   decoded detail -- moved 1.99 -> 1.87 -> 1.88 while the sender's bytes
      //     per frame moved twelve-fold, i.e. it was reading the CONTENT.
      //
      // What is left is the honest one, and it needs no image analysis at all:
      // the far end already tells us which rung of its own quality ladder it
      // settled on, per direction, over the wire. `peer_q_level` is that. A
      // picture pinned to the bottom rung IS the pixelation complaint, said by
      // the only party that knows -- the one that made the picture.
      "v_dec_motion": gDecMotion,
      "v_freeze_ms_max": display?.freezeMaxMs ?? 0,
      "v_freezes_150": display?.freezes150 ?? 0,
      "v_freezes_400": display?.freezes400 ?? 0,
    ]
    if let v = e.p(0.50) { vb["v_enc_ms_p50"] = v }
    if let v = dl.p(0.50) { vb["v_dec_ms_p50"] = v }
    vb["v_q_level"] = vq.level
    vb["v_q_downs"] = vq.stepDowns
    vb["v_q_ups"] = vq.stepUps
    // ── THE PAUSE, FROM BOTH ENDS ────────────────────────────────────────────
    //
    // Both directions, because they are different faults with the same name: our
    // uplink giving out is something this machine could act on, theirs is not,
    // and a single "video was paused" field would merge the two into a number
    // that cannot be acted on at all. Second instance of the rule that a
    // directional property has to be recorded at the end that owns it.
    vb["v_pauses"] = vq.pauses
    vb["v_paused_s"] = vPausedSecs
    vb["v_paused_now"] = gVideoPaused ? 1 : 0
    vb["v_peer_pauses"] = vPeerPauses
    vb["v_peer_paused_s"] = vPeerPausedSecs
    vb["v_peer_paused_now"] = lastPeerPaused ? 1 : 0
    vb["v_peer_cam_off"] = lastPeerCamOff ? 1 : 0
    vb["a_peer_muted"] = lastPeerMuted ? 1 : 0
    // Which arm this call ran, so a pause that never happened can be told from a
    // pause that was switched off. An A/B with an unlabelled control arm is not
    // an A/B.
    if flag("no-vpause") { vb["v_pause_armed"] = 0 }
    if let q = venc?.qualityNow { vb["v_quality"] = q }
    vb["v_dq_queued"] = dq.queued
    vb["v_dq_inline_full"] = dq.inlineFull
    vb["v_dq_inline_big"] = dq.inlineTooBig
    vb["v_dq_depth_max"] = dq.maxDepth
    if let d = display { vb["v_shown"] = d.shown; vb["v_enq_fail"] = d.enqueueFails }
    if let m = mdisplay {
      vb["v_shown"] = m.shown
      // Coverage travels WITH the number, because a percentile over a tenth of the
      // frames is not a latency -- and it once looked like the best result of the
      // day. The dashboard can refuse to draw it; it cannot invent the coverage
      // after the fact.
      vb["v_glass_cov"] = m.shown > 0 ? Double(m.present.count) / Double(m.shown) : 0
      if let v = m.present.p(0.50) { vb["v_glass_ms_p50"] = v }
    }
    videoBeat = vb
    fputs("  video  enc \(sv)/s  dec \(dv)/s  \(String(format: "%.2f", mbps)) Mbps  \(perFrame) B/frame"
        + "  luma \(venc?.lastLuma ?? -1) motion \(venc?.lastDiff ?? -1)"
        + "  encLat \(f(e.p(0.50)))  decLat \(f(dl.p(0.50)))"
        + "  g2g p50 \(f(g.p(0.50))) p95 \(f(g.p(0.95))) ms"
        + "  frags \(vasm.fragsIn) frames-lost \(vasm.missing) partial-drops \(vasm.dropped) decFails \(vdec.decFails) noFmt \(vdec.noFormat)"
        + "  repairKeys \(keyAsksOnLoss) decLuma \(String(format: "%.0f", gDecLuma))"
        // Say how many frames took the INLINE path anyway. A queue whose whole
        // purpose is to keep decode off the receive thread, and which quietly
        // falls back to doing it there when full, is a queue that looks like it is
        // working while the defect continues.
        + "  picture \(vq.describe)"
        // Which kind of frame the bytes went into, averaged over the call. A
        // keyframe is meant to be rare and large; if it is neither rare nor the
        // large one, the thing to look at is not the encoder.
        + (venc.map { v in
            "  keyframes \(v.keyFrames) avg \(v.keyFrames > 0 ? v.keyBytes / v.keyFrames : 0) B"
            + " | P \(v.pFrames) avg \(v.pFrames > 0 ? v.pBytes / v.pFrames : 0) B" } ?? "")
        + "  decodeq \(dq.queued) queued, depth<=\(dq.maxDepth)"
        + (wire.parityFragsSent > 0 || vasm.parityUsed > 0
           ? "  parity sent \(wire.parityFragsSent) got \(vasm.parityUsed)"
             + " REPAIRED \(vasm.parityRecovered)"
             + " (\(vasm.parityLate) arrived after the frame was already whole)"
             + (vasm.parityWasted > 0 ? " wasted \(vasm.parityWasted)" : "") : "")

        + (dq.inlineFull + dq.inlineTooBig > 0
           ? "  INLINE \(dq.inlineFull) full + \(dq.inlineTooBig) oversize" : "")
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

  // The step injector, if armed. Deliberately BEFORE the controller so a manual
  // step and an automatic one cannot both move the knob in the same second and
  // leave the result unattributable.
  if let st = vqStep, !vqStepDone, Double(beatTick) >= st.at, let e = venc {
    vqStepDone = true
    e.pendingQuality = st.q
    fputs("  vq-step: quality -> \(st.q) by session rebuild"
        + " -- WATCH THE B/FRAME, not any readback\n", stderr)
  }

  // ── Steer the picture on evidence about the path THESE BYTES TRAVEL ─────────
  //
  // This read the WRONG END, and a one-directional impairment proved it. With 3%
  // loss injected on A's send only, B's inbound was damaged and B's outbound was
  // perfectly clean -- and B drove its OWN outbound video to the floor and held
  // it there for 87 of 98 seconds. Less video from B could not have helped: the
  // congested direction was the other one. In the same run video was not even
  // running, so a controller whose entire job is video volume retreated three
  // levels on evidence that had nothing to do with video at all.
  //
  // `vasm.missing` is video WE failed to assemble and `ring.concealed` is audio WE
  // had to fill in. Both are inbound. `jitTarget` growing is our own receive
  // buffer. All three describe the path INTO this machine, and the only thing
  // this controller can change is what leaves it.
  //
  // A symmetric rig can never show this -- loss both ways makes the wrong end
  // look like the right one, which is why it survived 17.105's measurements.
  // Third instance of "directional property, wrong end" in this program, and the
  // second consumer of THIS signal: the redundancy controller had the identical
  // bug (it read local receive counters and turned on redundancy in the transmit
  // path) and was fixed by switching to the peer's report. The report was already
  // on the wire. This is the same fix, in the file that did not get it.
  if let e = venc {
    // What the far end says about the path FROM HERE. lost + recovered, not lost
    // alone: our own FEC repaired 4209 of 4443 outbound losses in the run above,
    // so watching only what survived would report a 3% path as healthy. A packet
    // that had to be repaired still did not arrive the first time.
    wire.selfQLevel = vq.level
    let pLost = wire.peerRxLost, pRec = wire.peerRxRecovered
    // ── THE FIRST REPORT IS A BASELINE, NOT A DELTA ───────────────────────────
    //
    // `wire.peerRxLost` and `peerRxRecovered` are CUMULATIVE since the PEER's
    // process start, and these baselines start at zero. So the first report that
    // ever arrived was subtracted from nothing and the whole of the peer's history
    // -- a peer that had been up for an hour, or a leg restarted by the updater --
    // was booked as harm inside one second. That is a free step down handed to
    // every fresh call before a single packet of ours had been lost, and the
    // picture then needed fifteen quiet seconds to earn the rung back.
    //
    // Startup poisons estimators: sampling before the inputs are aligned learns a
    // large wrong value. Prime, then measure.
    // Two baselines, primed on two different events, because they become true at
    // different moments. The LOCAL counters are this process's own and monotonic
    // from the first tick, so the first tick is the right place for them. The
    // PEER's counters do not exist until its first report arrives, and priming
    // them on a tick that beat that report captures a baseline of zero -- which
    // books the peer's entire accumulated history as one second of harm the
    // instant it does report. That is the startup-poisoning bug verbatim, so the
    // peer baseline waits for the evidence it is a baseline OF.
    if !vqPrimed {
      vqPrimed = true
      lastVqConc = r.concealLost; lastVqLost = vasm.missing
    }
    if !vqPrimedPeer, wire.peerReportsLoss {
      vqPrimedPeer = true
      lastVqPeerLost = pLost; lastVqPeerRec = pRec
    }
    var outboundHarm = (pLost - lastVqPeerLost) + (pRec - lastVqPeerRec)
    // ── A PEER RESTART IS A NEW BASELINE, NOT A REPAIR ────────────────────────
    //
    // These are the PEER's counters, cumulative since the PEER's process start,
    // and its process restarts for real: the self-updater does it, and the field
    // beside this one exists because it happens. When it does, both counters drop
    // to zero and this delta is one large NEGATIVE number for exactly one tick.
    //
    // A negative harm is not "less than no loss". It armed nothing and, worse, it
    // flickered `wire.videoParity` OFF at the precise moment the peer came back --
    // which is the moment its receive path is least able to afford a missing
    // fragment. The redundancy controller a few hundred lines up already gets this
    // right in the same shape: clamp to zero, and re-baseline on the new counters
    // (the assignment below is the re-baseline, and runs either way).
    if outboundHarm < 0 { outboundHarm = 0 }
    lastVqPeerLost = pLost; lastVqPeerRec = pRec
    // An older peer does not report, and falling back silently to the local
    // numbers would restore the exact bug this comment describes. So it falls
    // back and SAYS SO, once.
    if !wire.peerReportsLoss {
      // `concealLost`, not `concealed`. The redundancy controller above says why
      // in its own words: concealment also covers STARVATION, which is this
      // machine's own receive buffer running dry -- and no amount of sending less
      // picture can improve it. Using the aggregate here let a jitter buffer one
      // packet too small drive the picture down three rungs on a call whose
      // uplink was never the problem.
      outboundHarm = (r.concealLost - lastVqConc) + (vasm.missing - lastVqLost)
      if !vqWarnedLocal, beatTick > 10 {
        vqWarnedLocal = true
        fputs("picture: the far end does not report its receive loss (older build), "
            + "so quality is steered from LOCAL inbound harm -- which is the wrong "
            + "direction and can lower the picture for a problem it cannot fix\n", stderr)
      }
    }
    // Same evidence, same direction, a different action: a path that is dropping
    // packets gets a parity fragment per frame, so a sharp picture stops being
    // fragile. `--no-vparity` exists so it can be A/B'd against itself. Armed on
    // ANY loss, because it is cheap and it measured out cheaper than the keyframe
    // storm it prevents.
    wire.videoParity = !vParityOff && outboundHarm > 0

    // ── HARM IS A RATE, NOT A COUNT ────────────────────────────────────────────
    //
    // `outboundHarm > 0` collapsed the picture to the floor on any path losing
    // anything at all, and 1% loss is an ordinary internet path. That was the
    // right call while a sharp picture was fragile -- measured: q0.7 lost 7.8% of
    // frames against q0.3's 0.9%. Parity changes the answer. At 1% loss q0.7 with
    // parity loses 0.26%, which is BETTER than the floor was without it, so
    // retreating now costs quality and buys nothing.
    //
    // Parity recovers any ONE lost fragment of seven, so it fails when two go
    // missing: 0.2% of frames at 1% loss, 1.7% at 3%, 4.5% at 5%. The picture is
    // therefore safe to hold up to roughly 3%, and 2% is the line -- expressed as
    // a fraction of what was sent, so it means the same thing at every packet rate
    // rather than being a hidden function of one.
    let sentNow = max(1, d.sent)
    let harmRate = Double(outboundHarm) / Double(sentNow)
    let HARM_RETREAT = Double(arg("vq-harm-pct") ?? "2") ?? 2.0
    let harmed = harmRate * 100.0 > HARM_RETREAT
    if harmed != lastVqHarmed {
      lastVqHarmed = harmed
      fputs("  picture: outbound loss \(String(format: "%.2f", harmRate * 100))% of packets"
          + " -- \(harmed ? "above" : "below") the \(String(format: "%.1f", HARM_RETREAT))% line,"
          + " so quality \(harmed ? "retreats" : "holds")\n", stderr)
    }
    let wasPaused = vq.paused
    let changed = vq.tick(now: Double(beatTick),
                          framesLost: harmed ? outboundHarm : 0,
                          concealed: 0,
                          jitGrew: false)
    // ── STOPPING THE PICTURE, AND SAYING SO IN THREE PLACES ───────────────────
    //
    // The decision is made here and has to reach three separate consumers, none
    // of which can work it out for itself: the capture thread (stop handing
    // frames to the encoder), the far end (blur and explain), and the record
    // (how long, how often -- a pause nobody can see afterwards cannot be judged
    // as a good trade or a bad one).
    //
    // `--vpause-test` forces the state without needing a bad link, which is the
    // only way to prove the far end's half on a clean LAN. It is deliberately
    // crude: the point is to exercise the wire bit, the blur and the sentence.
    if let at = arg("vpause-test").flatMap({ Int($0) }) {
      gVideoPaused = beatTick >= at && beatTick < at + 20
    } else {
      gVideoPaused = vq.paused
    }
    if vq.paused != wasPaused {
      Metrics.count(vq.paused ? "video_pause" : "video_resume")
      fputs("  picture: video \(vq.paused ? "PAUSED -- the link could not carry the floor" : "resumed")"
          + " (pause \(vq.pauses), \(vq.pausedTicks)s paused so far)\n", stderr)
    }
    if gVideoPaused { vPausedSecs += 1 }
    // Our half of the status byte. Both bits every tick rather than a bitwise
    // update, so a stale bit cannot survive a state change -- an OR-only status
    // byte is a latch, and a latch is how "their camera is off" outlives the
    // moment they turned it back on.


    // `r.concealLost`, matching the priming above and the read below it. This line
    // said `r.concealed`, and one word was the whole defect: `concealed` is exactly
    // `concealLost + concealStarved` (Audio.swift), and `concealStarved` is
    // cumulative and monotonic, so from the second tick onward the baseline sat
    // permanently ABOVE the quantity it is subtracted from. The harm delta carried
    // a growing negative bias, `wire.videoParity` never armed, the picture never
    // retreated, and the log said "below the line, so quality holds" the whole
    // time. Three sites read and write this quantity -- the prime, the fallback
    // read, and this write -- and all three must name the same expression.
    lastVqLost = vasm.missing; lastVqConc = r.concealLost; lastVqJit = audio.jitTarget
    if let newQ = changed {
      // Hand it to the encoder thread, which rebuilds the session. NOT setQuality:
      // that is accepted, reads back, and changes nothing on a live session.
      e.pendingQuality = newQ
      fputs("  picture: \(vq.describe) -- rebuilding encoder at \(newQ)"
          + " (rebuilds so far \(e.rebuilds))\n", stderr)
    }
  }

  // ── WHAT THE FAR END SAYS ABOUT ITSELF ──────────────────────────────────────
  //
  // OUTSIDE the encoder block above, and that placement is the point: a machine
  // with no camera still has to blur and explain when THEIR picture stops. Tying
  // this to `venc` would mean the person who joined without a camera -- the one
  // with the least other evidence about what is happening -- is the one shown a
  // frozen face with no caption.
  //
  // Counted as a duration because that is what a person complains about: "video
  // was gone for forty seconds" is a report, "the status bit was set" is not.
  // Our half of the same byte. Both bits are written every tick rather than
  // OR'd in, so a stale bit cannot survive the state changing -- an OR-only
  // status byte is a latch, and a latch is how "their camera is off" outlives
  // the moment they switched it back on.
  // ── YOUR MUTE IS NOT A VIDEO FACT ────────────────────────────────────────
  //
  // This line lived inside `if let e = venc`, the VIDEO ENCODER block, because
  // that is where the rest of the peer report is assembled. So a call with no
  // camera -- `--video off`, a camera that refused to open, or an audio call by
  // choice -- never told the far end you had muted. That is the call where mute
  // matters MOST: there is no picture to read, so an unexplained silence is the
  // only thing the other person has, and it looks exactly like a dead line.
  //
  // Fourth instance today of one condition answering two questions. "Do I have a
  // video encoder" was deciding "does the other person find out I muted".
  wire.selfMuted = display?.controls?.micMuted ?? false
  wire.selfStatus = (gVideoPaused ? Wire.ST_VPAUSED : 0)
                  | ((camOff || noCameraHere) ? Wire.ST_CAMOFF : 0)
                  // The bit that stops a ring answering itself. See the block
                  // above `ringPreview`: packets arriving from here mean somebody
                  // is being ASKED, not that they said yes.
                  | (ringPreview ? Wire.ST_RINGING : 0)
  let pPaused = wire.peerVideoPaused, pCamOff = wire.peerCamOff
  if pPaused { vPeerPausedSecs += 1 }
  if pPaused != lastPeerPaused {
    lastPeerPaused = pPaused
    if pPaused { vPeerPauses += 1 }
    Metrics.count(pPaused ? "peer_video_pause" : "peer_video_resume")
    fputs("  picture: the far end's video \(pPaused ? "PAUSED (their link)" : "resumed")\n", stderr)
  }
  if pCamOff != lastPeerCamOff {
    lastPeerCamOff = pCamOff
    Metrics.count(pCamOff ? "peer_cam_off" : "peer_cam_on")
    // Said out loud, like the pause above it. This transition decides whether the
    // far end sees "their camera is off" or an unexplained empty picture, and it
    // was the only one of the two that happened silently.
    fputs("  picture: the far end's camera is \(pCamOff ? "OFF" : "on")\n", stderr)
  }
  let pMuted = wire.peerMuted
  if pMuted != lastPeerMuted {
    lastPeerMuted = pMuted
    Metrics.count(pMuted ? "peer_muted" : "peer_unmuted")
    fputs("  voice: the far end's microphone is \(pMuted ? "OFF" : "on")\n", stderr)
  }
  // Same rule as the quality readout above: nothing about a peer who is not here.
  if peerHere {
    display?.setPaused(peer: pPaused, selfSide: gVideoPaused, peerCamOff: pCamOff, peerMuted: pMuted)
  }

  // LAST in the loop, on purpose: every section above has now computed its
  // numbers, so the beat and the lines printed beside it cannot disagree about
  // what this second looked like.
  // Once a second, on the report thread: turns two instantaneous signals into a
  // duration. Never from a callback -- see the note in Audio.sampleQuality.
  audio.sampleQuality()
  // ── "THIS CALL WAS ALIVE AS OF NOW" ────────────────────────────────────────
  //
  // One small atomic write a second, on the thread that was already waking once a
  // second, nowhere near audio or video. It is the freshness stamp the next launch
  // reads to decide whether walking back in is safe -- without it a record could
  // only ever say when the call STARTED, and a four-hour call would look four
  // hours stale the moment it crashed.
  Resume.touch()
  // Same cadence, same thread, same reason: never from a callback.
  audio.tuneInputGain()
  // Same cadence: headphones appearing mid-call open it to full duplex.
  audio.checkOutputRoute()
  if Telemetry.enabled, !shuttingDown, beatTick % 5 == 0 {
    Telemetry.post(audioBeat(uptime: Double(beatTick), up: upMbps, down: downMbps,
                             played: d.played, concealed: d.concealed, cap: d.cap,
                             p50: p50, p95: p95, p99: p99))
  }
}
}

// ── One last beat on the way out ─────────────────────────────────────────────
//
// A call's most interesting moment is often its end -- someone gave up. Without
// this the record simply stops, which looks identical to a laptop lid closing.
//
// A DispatchSource rather than signal(2): the handler needs to make a network
// request and wait for it, and neither is safe inside a real signal handler.
// SIGINT is IGNORED for a background job of a non-interactive shell, so SIGTERM
// is watched too -- that difference once left eight test processes running and
// silently corrupted a day of measurements.
for sig in [SIGINT, SIGTERM] {
  signal(sig, SIG_IGN)
  let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
  src.setEventHandler {
    shuttingDown = true
    // THE SAME FUNCTION as Leave and as a re-exec, not the same shape as them.
    // It used to be a second copy of the wait-for-the-post logic, and the copies
    // had already drifted: this one sent no `ended`, so a dashboard reading that
    // field found it on some final beats and missing on others -- which reads as
    // a call that ended in a way nobody named, rather than as an un-instrumented
    // code path. `audioBeat` is safe here even before the audio engine exists: it
    // checks `beatReady` and sends the pre-connect beat instead.
    postFinalBeat(why: sig == SIGINT ? "interrupt" : "terminated")
    fputs("\nbye\n", stderr)
    exit(0)
  }
  src.resume()
  signalSources.append(src)
}

if display != nil || mdisplay != nil {
  Thread { reportLoop() }.start()
  // Third and last activation site. The ring-preview image no longer stops at
  // the park, so it reaches this one -- and an unconditional activate here undid
  // the whole of TK_NO_RAISE for exactly the process that rings.
  if ProcessInfo.processInfo.environment["TK_NO_RAISE"] != "1" {
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
  NSApplication.shared.run()
} else {
  reportLoop()
}
