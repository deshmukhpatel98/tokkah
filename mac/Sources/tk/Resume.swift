import CryptoKit
import Foundation

// ── A CALL ENDS WHEN SOMEBODY HANGS UP, AND AT NO OTHER TIME ─────────────────
//
// Said in the words it was asked for: "even if one side closes the app, they
// should hop into the call as soon as they start the app again, unless they have
// disconnected the call. Only disconnecting the call will disconnect the call --
// otherwise the call should stay open. Either of the sides has to disconnect."
//
// Everything this app knew about being in a call lived in the PROCESS. So every
// way a process can stop -- a self-update's `execv`, a crash, a force-quit, a
// closed window, a Mac going to sleep -- ended the call for both people, and the
// side that stayed was shown "the other person left" over a frozen face. That is
// four different accidents wearing the same costume as a decision, and only one
// of them was ever a decision.
//
// So being in a call becomes a fact ON DISK. It is written when the transport
// locks, refreshed once a second while media flows, and DELETED by exactly one
// class of event: a person hanging up, at either end. Nothing else removes it --
// not a signal, not a crash, not the updater. A process that dies without saying
// goodbye has not left; it has stepped out, and the record is what walks it back
// in.
//
// This is the web app's shape, deliberately: `tape-app/public/app.js` boots with
// `?rejoin=1` and presses join on the way in, and its comment for the equivalent
// move is "the recovery IS that rejoin, done for them". The far side there needs
// no new code because a rejoin simply arrives as a peer joining. The same is true
// here and it is the property that makes this shippable one end at a time -- see
// ROLLOUT below.
//
// ── WHY A FILE AND NOT UserDefaults ─────────────────────────────────────────
//
// It has to survive `kill -9`. `UserDefaults` writes are coalesced and flushed by
// a daemon on its own schedule, so a value set a moment before a crash may never
// reach the disk -- which is precisely the case this exists for. A file written
// atomically is on the disk when the write returns.
//
// It lives beside identity.json, under `Identity.dir`, so `TK_KIN_DIR` isolates a
// rig from the real install the same way it does for everything else. That is not
// politeness: `rig-isolation-that-does-not-isolate` is a recorded failure here,
// and a test that resumed the user's actual call would be exactly it.
//
// ── ROLLOUT: WHICH HALF NEEDS WHICH END UPDATED ─────────────────────────────
//
// Worth stating plainly, because the far Mac may still be on an old build.
//
//   REJOINING needs only the RETURNING end. To an old peer a rejoin is a peer
//   that went quiet and came back, which its rediscovery loop already handles --
//   it keeps probing forever and re-locks. The only difference is that an old
//   peer says "the other person left" in between and puts its waiting card up.
//   The call still comes back.
//
//   HOLDING -- not saying "left", not putting the card up, keeping the timer
//   running -- needs the STAYING end. Cosmetic in the sense that media recovers
//   either way, and not cosmetic at all in the sense that what a person SEES is
//   whether the app looks broken.
//
//   THE GOODBYE needs both ends to be understood. An old build drops the packet
//   as an unknown magic (Net.swift dispatches on magic and falls through to
//   `continue`), so nothing breaks -- it simply falls back to the bound below.
enum Resume {

  // ── HOW THE TWO SIDES AGREE ABOUT WHEN A CALL IS OVER ─────────────────────
  //
  // `held-is-a-one-way-door` is a recorded bug class here: a recovery gate whose
  // evidence the other side switches off, two timeouts that had to agree with
  // nothing connecting them. This feature is exactly that shape -- one side holds
  // waiting for a rejoin while the other may already have given up -- so the
  // agreement is spelled out rather than left to two constants that happen to be
  // ordered correctly today.
  //
  // There are two channels, and they are ranked:
  //
  //  1. THE GOODBYE, in band, on the media socket. A person hangs up, four
  //     datagrams go out, and the far end ends the call and deletes its record.
  //     Instant, needs no server, and works for a link-invite call where neither
  //     side knows the other's handle -- which the mailbox `bye` cannot do,
  //     because it is addressed to a handle.
  //
  //  2. THE ROOM DIRECTORY, for when the goodbye never arrives -- an old build at
  //     the far end, a Mac that lost power, a packet lost on the way out. Both
  //     ends read ONE fact from it: is the other end still publishing an address?
  //     A living process republishes every half second; a dead one stops, and the
  //     worker sweeps its entry after 90 s ("short enough that a stale mapping is
  //     never offered as a live one" -- worker.ts). So the holding side gives up
  //     exactly when the room forgets the peer, and the returning side republishes
  //     within about a second of launch, hundreds of times inside that window.
  //
  // That is what connects the two timeouts: they are not two timeouts. There is
  // one shared fact -- the directory entry -- and the returning side's first act
  // is to refresh it. The bound is the room lease that already existed, not a new
  // number invented here.
  //
  // AND THE DIRECTORY MUST NOT LIE BY SILENCE. `Rendezvous.exchange` returns nil
  // rather than an empty list when it could not ask, because "the server says
  // nobody is in that room" and "this Mac has no network" were the same `[]` --
  // `blind-instruments-report-negatives`, and this is a gate where the negative
  // ends somebody's call.
  static let roomLeaseMs = 90_000

  /// Rejoin with no questions asked when the record is fresher than the room
  /// lease: inside that window the directory still holds both ends, so walking
  /// back in is guaranteed to find whoever stayed. This covers every case the
  /// user actually named -- an update re-exec, a crash, a force-quit, a closed
  /// window -- because all of them come back in seconds.
  static let walkInMs = roomLeaseMs

  /// Beyond the lease the room has forgotten us, so a rejoin is a guess. Asked
  /// once, against the directory, before anything opens a camera. Twelve hours is
  /// the outer bound on "this is still the call you were on"; past it the record
  /// is dropped and the app behaves as it always did.
  static let askFirstMs = 12 * 3600 * 1000

  struct Live: Codable {
    var room: String
    /// Wall clock, ms. Refreshed once a second by the live call; this is what
    /// makes "the record is stale" a measurement rather than a guess.
    var at: Double
    var startedAt: Double
    /// The telemetry id of the call this record belongs to. Handed to the
    /// rejoining image as `--prev-call`, so the dashboard reads one call that
    /// survived a restart rather than two unrelated calls.
    var call: String
    var port: Int
    var peer: String
    var video: String
    /// The far end's handle when the call came from a ring; empty for a link
    /// invite. Only used to say their name while the call is held.
    var who: String
    /// ── THE ADDRESS THE CALL WAS ACTUALLY ON ──────────────────────────────────
    ///
    /// `ip:port`, as this end last had it. This is the honest, cheap version of
    /// handing the bound socket across the exec: the socket cannot survive a
    /// crash and the ADDRESS can, and the address is most of what the socket was
    /// worth. The far end's NAT binding is still open -- it has been sending to
    /// us the whole time -- so one datagram to this address, sent before STUN has
    /// even answered, restarts their media hundreds of milliseconds before the
    /// rendezvous could have told us where they are.
    ///
    /// Optional because a record written by an earlier build does not have it,
    /// and a synthesised `Decodable` refuses a missing non-optional key outright
    /// -- which would turn every pre-existing record into "unreadable, dropped",
    /// i.e. one silent release where nothing rejoins.
    var path: String?
  }

  static var file: URL { Identity.dir.appendingPathComponent("call.json") }

  private static let lock = NSLock()
  private static var current: Live?

  /// Written the moment the transport locks, and re-written once a second after
  /// that. Atomic, because the failure this exists for is a process dying between
  /// two writes and a half-written record is worse than none: it would parse as
  /// garbage or, worse, as a plausible room nobody is in.
  private static func store(_ l: Live) {
    let fm = FileManager.default
    try? fm.createDirectory(at: Identity.dir, withIntermediateDirectories: true)
    guard let d = try? JSONEncoder().encode(l) else { return }
    try? d.write(to: file, options: .atomic)
  }

  static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

  /// The call is real. Called at the transport lock rather than at launch: a
  /// process that never found anybody was never in a call, and a record written
  /// hopefully at startup would send the next launch back into an empty room.
  static func begin(room: String, port: Int, peer: String, video: String,
                    who: String, call: String, path: String? = nil) {
    lock.lock()
    let started = current?.startedAt ?? now()
    let l = Live(room: room, at: now(), startedAt: started, call: call,
                 port: port, peer: peer, video: video, who: who, path: path)
    current = l
    lock.unlock()
    store(l)
  }

  /// The remembered address, read WITHOUT the side effects of `pending()` --
  /// which deletes records it decides against, and must be called exactly once
  /// per launch. This is the resumed image asking "where were we", and the answer
  /// is only ever used to aim a few datagrams.
  static func rememberedPath() -> (ip: String, port: UInt16)? {
    guard let d = try? Data(contentsOf: file),
          let l = try? JSONDecoder().decode(Live.self, from: d),
          // `lockedFrom` reads either `1.2.3.4:5` or `direct 1.2.3.4:5` depending
          // on which half of the path race set it, so the kind is dropped here
          // rather than being stored twice and allowed to disagree.
          let raw = l.path?.split(separator: " ").last.map(String.init),
          case let bits = raw.split(separator: ":"), bits.count == 2,
          let p = UInt16(bits[1]), !bits[0].isEmpty
    else { return nil }
    return (String(bits[0]), p)
  }

  /// "This call was alive as of now." Once a second from the report loop, which
  /// is already a once-a-second thread and is nowhere near the media path.
  static func touch() {
    lock.lock()
    guard var l = current else { lock.unlock(); return }
    l.at = now()
    current = l
    lock.unlock()
    store(l)
  }

  /// ── THE ONE THING THAT ENDS A CALL ────────────────────────────────────────
  ///
  /// A person hung up -- here, or at the far end. Nothing else may call this.
  /// Not the signal handler: a Ctrl-C or a SIGTERM is a process ending, and this
  /// whole file exists because a process ending is not a call ending. Not the
  /// updater. Not a crash, which could not call anything anyway, which is the
  /// point.
  static func end(why: String) {
    lock.lock()
    let had = current != nil || FileManager.default.fileExists(atPath: file.path)
    current = nil
    lock.unlock()
    try? FileManager.default.removeItem(at: file)
    if had { fputs("call: ended (\(why)) -- the record is gone, nothing will rejoin\n", stderr) }
  }

  /// True while this process believes it is in a call nobody has ended. Read by
  /// the departure detector to decide between "they left" and "they will be back".
  static var holding: Bool {
    lock.lock(); defer { lock.unlock() }
    return current != nil
  }

  /// Read the record at launch and decide whether to walk back into it.
  ///
  /// `askDirectory` is injected rather than called directly so this can be
  /// reasoned about -- and tested -- without a network. It returns nil when it
  /// could not ask, which is NOT the same as "nobody is there": a launch with no
  /// network must not delete a live call's record.
  /// ── AND IT MUST NOT COST A LAUNCH ────────────────────────────────────────
  ///
  /// `Rendezvous.exchange` has an 8 s request timeout and a 10 s wait, and this
  /// runs before the window exists. A blocking network call on the launch path is
  /// the exact defect this app deleted from its update check -- "1155 ms of
  /// nothing, measured, on every launch", where the word "cheap" was doing all
  /// the work. So it gets a deadline of its own, and blowing that deadline is
  /// read as "could not ask" rather than as "nobody is there": the record
  /// survives, and the app opens as it always did.
  ///
  /// It is also only reachable on a path that is already rare -- there has to BE
  /// a record, and it has to be older than the room lease. A launch with no held
  /// call touches none of this.
  private static func askRoomBriefly(_ room: String) -> Bool? {
    var out: Bool?
    let done = DispatchSemaphore(value: 0)
    Thread {
      // A throwaway id. Publishing nothing (`addr: nil`) means this asks without
      // claiming a slot in the room, so a launch that decides NOT to rejoin
      // cannot leave a ghost behind it -- which is the failure this whole file
      // spends its longest comment on.
      out = Rendezvous.exchange(room: room, me: "kinask\(getpid())", addr: nil).map { !$0.isEmpty }
      done.signal()
    }.start()
    guard done.wait(timeout: .now() + 1.2) == .success else {
      fputs("call: the room directory did not answer in 1.2 s -- not holding a launch for it\n",
            stderr)
      return nil
    }
    return out
  }

  static func pending(askDirectory: (String) -> Bool? = { askRoomBriefly($0) }) -> Live? {
    guard let d = try? Data(contentsOf: file) else { return nil }
    guard let l = try? JSONDecoder().decode(Live.self, from: d), !l.room.isEmpty else {
      // A record that will not parse is a record from a build that wrote a
      // different shape, or a truncated write. Named, and removed, because a file
      // that fails to parse on every launch forever is a permanent stall with no
      // symptom. `size-guard-corrupts-the-record` is why this is not tolerated
      // quietly.
      fputs("call: the resume record is unreadable -- dropping it\n", stderr)
      try? FileManager.default.removeItem(at: file)
      return nil
    }
    let age = now() - l.at
    if age > Double(askFirstMs) {
      fputs("call: last in \(l.room) \(Int(age / 3600_000)) h ago -- too long, not rejoining\n", stderr)
      try? FileManager.default.removeItem(at: file)
      return nil
    }
    if age <= Double(walkInMs) {
      fputs("call: still in \(l.room) (\(Int(age)) ms ago) -- rejoining\n", stderr)
      return l
    }
    // Past the lease. Ask once, and treat "could not ask" as "hold on to it":
    // deleting a live call's record because the wifi was down for one launch is
    // the expensive direction to be wrong in.
    switch askDirectory(l.room) {
    case .some(true):
      fputs("call: \(l.room) still has somebody in it after \(Int(age / 1000)) s -- rejoining\n", stderr)
      return l
    case .some(false):
      fputs("call: nobody is in \(l.room) any more -- not rejoining\n", stderr)
      try? FileManager.default.removeItem(at: file)
      return nil
    case .none:
      fputs("call: cannot reach the room directory -- keeping \(l.room) for next time,"
          + " but not opening a camera on a guess\n", stderr)
      return nil
    }
  }

  /// What the rejoining image has to be told, beyond the room. A fresh launch has
  /// no argv, so everything that defined the call has to come back off the disk.
  static func argv(_ l: Live, bundled: Bool) -> [String] {
    // `--resumed` is not decoration and not a no-op: it is what stops the window
    // opening on "waiting for the other person" with an invite link over a call
    // that is thirty seconds old, and it is what marks the telemetry row as a
    // continuation. `--prev-call` is the existing chain field, so a dashboard
    // reading `prev_call` sees one call across every restart it survived.
    var a = ["--video", l.video, "--listen", String(l.port), "--peer", l.peer,
             "--prev-call", l.call, "--resumed"]
    if bundled { a.append("--window") }
    return a
  }

  // ── THE NAME THIS MAC USES IN THE ROOM DIRECTORY ───────────────────────────
  //
  // It was `mac-<pid>`, and that is the ghost-slot bug this project has already
  // paid for on the web side, waiting to be found on this one.
  //
  // `rvPeers` in worker.ts is a Map keyed by `me`, swept after 90 s, and the
  // reply lists every OTHER key. A process that crashes and comes back has a new
  // pid, so it publishes under a new key -- and its corpse sits in that Map for a
  // minute and a half. Three consequences, all bad and none of them noisy:
  //
  //   * the peer's `peers.first` is insertion-ordered, so it is the DEAD entry,
  //     and the departure detector reads `ageMs` off a machine that no longer
  //     exists while the live one is second in the list;
  //   * the returning process sees its OWN corpse listed as a peer -- the filter
  //     is `k !== me` and its `me` just changed -- so it races candidates against
  //     its own public address;
  //   * two entries for one Mac in a room the product treats as holding two
  //     people.
  //
  // The web app's fix is `sid`, and its comment names the same failure: "a phone
  // that loses its network mid-call leaves a socket the room still counts as
  // OPEN, and the phone's own rejoin then 409s against its own corpse". The fix
  // there is a stable per-tab id that survives the recovery reload, so the room
  // can evict the old entry. Here it is simpler still: the Map is keyed by this
  // string, so a STABLE id overwrites its own previous entry and no ghost is ever
  // created. No server change at all.
  //
  // DERIVED, NOT STORED RAW, and per room. A stable public identifier posted to
  // an unauthenticated directory would let anyone who knows two room codes tell
  // that the same Mac was in both. Hashing the machine seed together with the
  // room gives an id that is stable where it needs to be and unlinkable
  // everywhere else.
  //
  // The PORT is in the hash because two copies of tk on one Mac in one room is
  // the normal shape of every rig in this repo, and they must not collide. In
  // production the port is the default and contributes nothing.
  static func rendezvousId(room: String, port: Int) -> String {
    var h = SHA256()
    h.update(data: Data("kin-rv-v1".utf8))
    h.update(data: Data(machineSeed().utf8))
    h.update(data: Data(room.utf8))
    h.update(data: Data(String(port).utf8))
    let hex = h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    // The worker validates `^[A-Za-z0-9_-]{1,64}$`, so hex with a prefix is safe
    // and stays readable in a log next to the old `mac-<pid>` form.
    return "kin-\(hex)"
  }

  /// A random number made once per install and kept beside the identity, for the
  /// same reason `Telemetry.install` exists -- except that this one has to follow
  /// `TK_KIN_DIR`, because two rig processes on one Mac must be two machines as
  /// far as the directory is concerned. `UserDefaults` is per bundle id and does
  /// not follow it, which is what `rig-isolation-that-does-not-isolate` is about.
  private static func machineSeed() -> String {
    let f = Identity.dir.appendingPathComponent("machine.json")
    if let d = try? Data(contentsOf: f),
       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let s = o["seed"] as? String, !s.isEmpty { return s }
    let s = String(UInt64.random(in: 0..<UInt64.max), radix: 36)
    try? FileManager.default.createDirectory(at: Identity.dir, withIntermediateDirectories: true)
    if let d = try? JSONSerialization.data(withJSONObject: ["seed": s]) {
      try? d.write(to: f, options: .atomic)
    }
    return s
  }
}
