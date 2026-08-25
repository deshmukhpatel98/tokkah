import Foundation

// ── THE CRASH THAT NOBODY TELLS US ABOUT ─────────────────────────────────────
//
// Every crash this app has ever had on somebody else's Mac has been invisible.
// The window goes away, the person shrugs and opens it again, and the only trace
// is an .ips file in a folder they will never look in. Apple's own "send to the
// developer" checkbox goes to Apple, not to us -- and this app is not on the App
// Store, so there is no crash feed to read either.
//
// That was survivable while a release only reached whoever ran the curl line by
// hand. It stopped being survivable the moment the always-on watcher started
// updating itself unattended: a release that crashes on launch now propagates to
// every Mac with nobody watching, and the FIRST evidence anybody would ever get
// is somebody eventually saying "it stopped working". This file is how that gets
// noticed at all.
//
// THREE SOURCES, BECAUSE A CRASH HAS MORE THAN ONE SHAPE:
//
//   1. A real crash report. macOS writes one to ~/Library/Logs/DiagnosticReports
//      for every signal death. It is the good case: it carries the exception, the
//      signal, and a symbolicated stack of the thread that died.
//   2. A run that never said goodbye. A hang the user force-quit, a SIGKILL from
//      a watchdog, a panic, a power cut -- none of these write a crash report at
//      all. This app already files a final beat at every ending (Leave, Ctrl-C,
//      SIGTERM, and a re-exec, which is an ending too), so the ABSENCE of one is
//      itself evidence. `unexplained-death-is-a-bug` is a law here; this makes
//      the law enforceable from a distance.
//   3. A run that was open when the Mac rebooted. Weaker evidence -- a normal
//      shutdown SIGTERMs us and we do file an ending -- but a power loss or a
//      kernel panic looks exactly like this and nothing else records it.
//
// WHAT MAKES THIS HARD, AND WHAT EACH DECISION BELOW IS FOR:
//
// THE APP HAS HAD FOUR NAMES. Crash reports are named after the PROCESS, and
// this binary has run as `tk`, `tk_new`, `tkreal`, `Tokkah` and (next) `Kin` --
// all five are sitting in that folder on this machine right now. A matcher that
// knows only today's name silently misses every crash from an older build, which
// is exactly the population worth hearing from: the copies that are behind.
// `isOurs` therefore never asks "what is it called".
//
// IT MUST COST NOTHING WHEN NOTHING CRASHED, which is almost always. The steady
// state is one directory listing and zero file reads: `sweptUntil` remembers the
// newest report already accounted for, and everything older than it is skipped by
// its modification date without being opened. It all runs on its own thread, so
// the main thread's only cost is starting it.
//
// A CRASH MUST NEVER BE SENT TWICE, AND MUST NEVER BE LOST. Both halves matter
// and they pull in opposite directions. The mark that says "already sent" is
// written AFTER the server has acknowledged, never before -- so a send that fails
// because the network was down is simply retried at the next launch. The key is
// the report's own `incident_id`, a UUID macOS mints per crash, so a file that is
// moved into Retired/ or re-read from a different directory is still recognised.
//
// SIZE IS DROPPED BY WHOLE FIELDS, NEVER BY PREFIX. A crash report is large and a
// stack can be hundreds of frames. This codebase has already shipped a size guard
// that TRUNCATED a JSON body: the record parsed, looked complete, and read as a
// call that was blind to everything -- worse than no record. So when this has to
// shed weight it names what it dropped and drops the whole thing.
//
// AND IT CARRIES SOMEBODY'S NAME. `/Users/devesh/...` is in every path in the
// file. macOS pre-redacts some of them and not others, so `scrub` does it again
// unconditionally, and the fields that exist only to identify a machine --
// crashReporterKey, the boot UUID, the user id, register contents -- are simply
// never read.
enum Crash {

  // ── WHERE THINGS LIVE ──────────────────────────────────────────────────────

  /// macOS's own crash folder. `TK_CRASH_DIR` is a rig override and production
  /// never sets it -- the sibling of `TK_KIN_DIR`, and for the same reason
  /// (`rig-isolation-that-does-not-isolate`): a test that plants a synthetic
  /// report must not plant it in the real folder, and a test that reads must not
  /// read the machine's real history.
  static var reportsDir: URL {
    if let d = ProcessInfo.processInfo.environment["TK_CRASH_DIR"] {
      return URL(fileURLWithPath: d, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
  }

  /// State goes beside the identity, so `TK_KIN_DIR` isolates it for free.
  private static var seenFile: URL { Identity.dir.appendingPathComponent("crashes.json") }
  private static var runsFile: URL { Identity.dir.appendingPathComponent("runs.json") }
  private static var lockFile: URL { Identity.dir.appendingPathComponent("crashes.lock") }

  /// How long a run must have been visibly dead before its silence is reported.
  ///
  /// Not a politeness delay -- it is the window macOS needs to finish writing the
  /// crash report. A crash loop relaunches in under a second, so the sweep that
  /// notices the death often runs BEFORE the .ips exists, and reporting
  /// immediately would file "it vanished with no explanation" for a death that
  /// has a perfectly good explanation arriving two seconds later. So a dead run
  /// is stamped on the sweep that first sees it and reported by a LATER sweep,
  /// which gives the report time to land and be matched.
  ///
  /// `TK_CRASH_GRACE_S` compresses it for the rig. Every production cadence in
  /// this project gets an override, because a thing provable in ten seconds
  /// should be proved in ten seconds.
  private static var graceS: Double {
    Double(ProcessInfo.processInfo.environment["TK_CRASH_GRACE_S"] ?? "") ?? 45
  }

  /// How far back a fresh install looks. On a Mac that has been crashing for a
  /// week, the week is the finding.
  private static let historyS: Double = 14 * 86400
  /// Per launch. A backlog is drained a few at a time rather than in one burst,
  /// because the first launch after this ships could otherwise post thirty
  /// reports at once from a machine that has been quietly falling over.
  private static let maxPerLaunch = 5

  // ── THIS PROCESS'S OWN RUN RECORD ──────────────────────────────────────────

  private static let lock = NSLock()
  nonisolated(unsafe) private static var myRunId: String?
  nonisolated(unsafe) private static var started = false
  /// Set the moment this process decides to end, whichever thread decides it.
  /// It exists to close the window between writing this run onto the books and
  /// being able to say which row is ours: a process that exits inside that window
  /// leaves a record nothing will ever strike off, and the next launch reports
  /// it as a death that never happened. A crash reporter that invents crashes is
  /// worse than one that misses them.
  nonisolated(unsafe) private static var ended = false

  /// Called once at launch, from a thread of its own. Writes this run's open
  /// record, then looks at what the last ones left behind.
  ///
  /// Everything in here is best effort and nothing it can do is fatal: a crash
  /// reporter that takes the app down is worse than no crash reporter, and this
  /// runs on every single launch.
  static func begin() {
    guard Telemetry.enabled else { return }
    lock.lock()
    if started { lock.unlock(); return }
    started = true
    lock.unlock()
    openRun()
    sweep()
  }

  /// This process is about to stop existing, and it is doing so on purpose.
  ///
  /// Called from `postFinalBeat` -- which is the one place Leave, Ctrl-C, SIGTERM
  /// and a re-exec all pass through -- and again from an `atexit` handler, which
  /// catches every other ordinary `exit()` in the program (a bind failure, a
  /// rendezvous that timed out, a self test that finished). What does NOT run an
  /// atexit handler is precisely what should not: a signal death, an `abort()`,
  /// a SIGKILL, and `execv`. The re-exec case is why `postFinalBeat` calls this
  /// as well -- `execv` replaces the image without unwinding anything, and a
  /// re-exec that looked like a death would report a crash every time somebody
  /// answered a ring.
  static func endRun() {
    lock.lock(); ended = true; let id = myRunId; myRunId = nil; lock.unlock()
    guard let id else { return }
    withLock {
      var runs = readRuns()
      runs.removeAll { ($0["id"] as? String) == id }
      writeRuns(runs)
    }
  }

  private static func openRun() {
    let id = String(UInt64.random(in: 0..<UInt64.max), radix: 36)
    let rec: [String: Any] = [
      "id": id,
      "pid": Int(getpid()),
      // Together these two make "is it still alive" answerable without being
      // fooled by pid reuse: a recycled pid belongs to a process that started
      // later than this one did.
      "pstart": procStart(getpid()) ?? 0,
      "boot": bootTime(),
      "start": Date().timeIntervalSince1970,
      "version": VERSION,
      "proc": ProcessInfo.processInfo.processName,
      // The call id this run was reporting under. It is the join back to
      // `mac_beats`: given it, the server knows when this run last spoke, which
      // is when it died -- so a death needs no heartbeat of its own here.
      "call": Telemetry.call,
    ]
    // CLAIM THE ID BEFORE WRITING IT. An ending that arrives while this is
    // mid-write must be able to name the row it has to strike off; the other
    // order leaves a window in which `endRun` sees no id, does nothing, and the
    // row it should have removed is written a moment later and stands forever as
    // a death that never happened.
    lock.lock()
    if ended { lock.unlock(); return }   // already on the way out; do not open books
    myRunId = id
    lock.unlock()
    withLock {
      var runs = readRuns()
      // Bounded. A machine that never launches this again would otherwise grow
      // this file forever; 64 open runs is far past anything real.
      if runs.count > 64 { runs.removeFirst(runs.count - 64) }
      runs.append(rec)
      writeRuns(runs)
    }
    // And if the ending landed DURING that write, take it back out. This is the
    // other half of the same window: `endRun` ran, found the row absent, and
    // cleared the id -- so the row it was looking for is the one just written.
    lock.lock(); let stillOurs = myRunId == id; lock.unlock()
    guard stillOurs else {
      withLock { writeRuns(readRuns().filter { ($0["id"] as? String) != id }) }
      return
    }
    fputs("crash: this run is on the books (\(id))\n", stderr)
  }

  // ── THE SWEEP ──────────────────────────────────────────────────────────────

  private static func sweep() {
    var sent = withLock { readSeen()["sent"] as? [String] ?? [] }
    let sweptUntil = withLock { readSeen()["sweptUntil"] as? Double }
      ?? (Date().timeIntervalSince1970 - historyS)

    // ── 1. REAL CRASH REPORTS ────────────────────────────────────────────────
    //
    // Oldest first, and the mark stops at the FIRST file that could not be
    // accounted for. A later file must never carry the mark past an earlier one
    // that never made it, which is the whole of "never lose one because the
    // network happened to be down at that moment".
    // The open-run list, read once, so a crash report can be joined to the run it
    // ended. `pid` is the join, and the run knows the CALL ID it was reporting
    // under -- which turns "0.58.0 crashed" into "0.58.0 crashed, and here are
    // the five seconds of that call leading up to it" on the dashboard. Nothing
    // else can supply that: the crash report has never heard of a call.
    lock.lock(); let mine = myRunId; lock.unlock()
    var runByPid: [Int: [String: Any]] = [:]
    withLock {
      for r in readRuns() where (r["id"] as? String) != mine {
        if let p = r["pid"] as? Int { runByPid[p] = r }
      }
    }

    var posted = 0
    var crashedPids: Set<Int> = []   // deaths that already have an explanation
    var highWater = sweptUntil
    for (url, mtime) in candidates(newerThan: sweptUntil) {
      if posted >= maxPerLaunch { break }
      guard let r = parse(url) else {
        // Unreadable, not a crash report, or somebody else's. Either way it is
        // accounted for and the mark may move past it -- which is what keeps a
        // folder full of other people's crashes to one read each, once, ever.
        highWater = max(highWater, mtime)
        continue
      }
      crashedPids.insert(r.pid)
      if sent.contains(r.incident) { highWater = max(highWater, mtime); continue }
      posted += 1
      Metrics.count("crash_found")
      fputs("crash: found \(r.fields["exc"] as? String ?? "a crash") in "
          + "\(r.fields["proc"] as? String ?? "?") v\(r.fields["app_version"] as? String ?? "?")"
          + " -- reporting it\n", stderr)
      var f = r.fields
      f["crashed_pid"] = r.pid
      if let run = runByPid[r.pid], let started = run["start"] as? Double, started <= r.at + 5 {
        f["crashed_call"] = run["call"] as? String ?? ""
        // The version the RUN recorded for itself. Believed over the report's
        // when the report has none, which is every copy run straight out of a
        // build directory rather than from an app bundle -- and those are the
        // copies the people testing a new release are using.
        if (f["app_version"] as? String ?? "").isEmpty { f["app_version"] = run["version"] as? String ?? "" }
      }
      guard post(f) else {
        Metrics.count("crash_send_fail")
        fputs("crash: could not send it (\(Telemetry.lastError)) -- keeping it for next launch\n", stderr)
        break
      }
      sent.append(r.incident)
      Metrics.count("crash_sent")
      highWater = max(highWater, mtime)
      // COMMITTED HERE, not at the end of the sweep. Writing the marks in one
      // batch at the end looks tidier and is wrong: this thread can be killed at
      // any moment -- the process it is reporting on has just crashed, so a
      // second crash or an impatient relaunch is exactly what is likely -- and a
      // report that was delivered but not yet marked is a report that gets
      // delivered again. Measured: one death was filed ten times.
      commit(sent: sent, sweptUntil: highWater)
    }
    commit(sent: sent, sweptUntil: highWater)

    // ── 2. RUNS THAT NEVER SAID GOODBYE ──────────────────────────────────────
    //
    // Classified under the lock, posted outside it. Holding an inter-process lock
    // across a ten-second network call would stall the launch of any other copy
    // starting at that moment, and the copy most likely to be starting is the one
    // relaunching after the crash being reported.
    let now = Date().timeIntervalSince1970
    let boot = bootTime()
    var toReport: [(String, [String: Any])] = []
    withLock {
      var keep: [[String: Any]] = []
      for var r in readRuns() {
        guard let id = r["id"] as? String else { continue }
        if id == mine { keep.append(r); continue }
        let pid = r["pid"] as? Int ?? 0
        let rebooted = abs((r["boot"] as? Double ?? 0) - boot) > 1
        // Alive means THE SAME PROCESS is alive: a pid on its own is a name that
        // gets handed on, and treating a recycled one as our own would quietly
        // lose the death that recycled it.
        let alive = !rebooted && pid > 0
          && procStart(pid_t(pid)).map { abs($0 - (r["pstart"] as? Double ?? -1)) < 1 } == true
        if alive { keep.append(r); continue }
        // Explained by a real crash report that this sweep just sent? Then it is
        // already reported, with a stack attached, and a second vaguer record of
        // the same death is noise. Closed out here rather than left open, so a
        // later sweep -- which will no longer be reading that file -- cannot
        // mistake an explained death for an unexplained one.
        if crashedPids.contains(pid), !rebooted { continue }
        if sent.contains("run-" + id) { continue }
        guard let seenDead = r["deadSeen"] as? Double else {
          r["deadSeen"] = now
          keep.append(r)
          continue
        }
        guard now - seenDead >= graceS else { keep.append(r); continue }
        keep.append(r)                       // stays until the post succeeds
        // Capped like the crash reports are. A Mac that has been force-quitting
        // this app all week has a backlog, and a backlog should be drained a few
        // at a time rather than posted in one burst at whoever launches next.
        if toReport.count < maxPerLaunch { toReport.append((id, r)) }
      }
      writeRuns(keep)
    }
    for (id, r) in toReport {
      let rebooted = abs((r["boot"] as? Double ?? 0) - boot) > 1
      let kind = rebooted ? "restart" : "vanished"
      Metrics.count(rebooted ? "died_at_restart" : "died_without_ending")
      fputs("crash: a previous run (\(r["proc"] as? String ?? "?") v\(r["version"] as? String ?? "?"))"
          + " left no ending and no crash report -- reporting it as \(kind)\n", stderr)
      var f: [String: Any] = [
        "kind": kind,
        "incident": "run-" + id,
        "at": r["start"] as? Double ?? now,
        "app_version": r["version"] as? String ?? "",
        "proc": scrub(r["proc"] as? String ?? ""),
        // The join back to `mac_beats`. Given it, the server already knows when
        // this run last spoke, which is when it died -- so the death needs no
        // heartbeat of its own on this machine.
        "crashed_call": r["call"] as? String ?? "",
        "crashed_pid": r["pid"] as? Int ?? 0,
        "ran_ms": Int(max(0, (r["deadSeen"] as? Double ?? now) - (r["start"] as? Double ?? now)) * 1000),
        "os": osVersionString(),
        "hw": Telemetry.model,
        "why": rebooted
          ? "the Mac restarted while this run was open -- a power cut or a panic looks like this"
          : "the process was gone, it had filed no ending, and macOS wrote no crash report",
      ]
      f["ran_ms_is_upper_bound"] = 1
      guard post(f) else { continue }
      sent.append("run-" + id)
      // Marked AND struck off in one locked step, immediately, for the same
      // reason the crash reports above are: whatever is happening on this machine
      // that made a run vanish can happen again to this one, and a death that was
      // reported but not yet written down is a death that gets reported again.
      commit(sent: sent, sweptUntil: highWater)
      withLock { writeRuns(readRuns().filter { ($0["id"] as? String) != id }) }
    }
  }

  /// Write down what has been delivered, as one locked read-modify-write over
  /// whatever is on disk NOW rather than over the snapshot this sweep started
  /// with. Two copies of this app can be launching at the same moment -- a ring
  /// answered during a call does exactly that -- and a last-writer-wins update
  /// would drop the other one's marks and re-send its crashes.
  private static func commit(sent: [String], sweptUntil: Double) {
    withLock {
      var s = readSeen()
      var all = s["sent"] as? [String] ?? []
      for i in sent where !all.contains(i) { all.append(i) }
      // Bounded, newest kept. An incident id is 40 bytes and this list is the
      // only thing standing between one crash and one crash reported at every
      // launch forever, so it is generous.
      if all.count > 300 { all.removeFirst(all.count - 300) }
      s["sent"] = all
      s["sweptUntil"] = max(sweptUntil, s["sweptUntil"] as? Double ?? 0)
      s["v"] = 1
      writeSeen(s)
    }
  }

  /// Every file that could be a crash report and has not been accounted for,
  /// oldest first. Two directories, because macOS moves reports into `Retired/`
  /// on a rolling basis and a report can move between one launch and the next.
  ///
  /// This is the whole zero-cost story. It stats the directory and compares
  /// modification dates; on a machine that has not crashed since the last launch
  /// it opens nothing at all.
  private static func candidates(newerThan cut: Double) -> [(URL, Double)] {
    let fm = FileManager.default
    var out: [(URL, Double)] = []
    for dir in [reportsDir, reportsDir.appendingPathComponent("Retired", isDirectory: true)] {
      guard let items = try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { continue }
      for u in items where u.pathExtension == "ips" {
        guard let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate?.timeIntervalSince1970 else { continue }
        if m <= cut { continue }
        out.append((u, m))
      }
    }
    return out.sorted { $0.1 < $1.1 }
  }

  // ── READING AN .ips ────────────────────────────────────────────────────────

  private struct Report { var incident: String; var at: Double; var pid: Int; var fields: [String: Any] }

  /// The modern format is TWO JSON documents in one file: a one-line header, then
  /// the body. Confirmed by reading the ones on this machine rather than assumed
  /// -- the header carries `incident_id`, `app_name`, `app_version` and
  /// `bug_type`, and the body carries everything that explains anything.
  ///
  /// Returns nil for a file that is not a crash report or not ours. The caller
  /// treats nil as "accounted for", so a folder full of other people's crashes
  /// costs one read each, once, ever.
  private static func parse(_ url: URL) -> Report? {
    guard let data = try? Data(contentsOf: url), data.count > 32 else { return nil }
    // A crash report is tens of kilobytes. Anything enormous is not one, and
    // reading it would be the only expensive thing this file does.
    guard data.count < 4_000_000 else { return nil }
    guard let nl = data.firstIndex(of: 0x0A) else { return nil }
    guard let head = try? JSONSerialization.jsonObject(with: data[..<nl]) as? [String: Any],
          let body = try? JSONSerialization.jsonObject(with: data[data.index(after: nl)...])
            as? [String: Any] else { return nil }
    // STRUCTURAL, not a magic-number lookup: a report worth having is a document
    // with a set of threads and something saying how it ended. `bug_type` is
    // carried as evidence rather than used as the test, because the numbers in
    // that field are Apple's and this app should not be the place that memorises
    // them -- a new one appearing should widen what arrives, not narrow it.
    //
    // `exception` is optional for the same reason. Every crash report on this Mac
    // has one; a hang report is the same shape with a `termination` and no
    // exception, and refusing it would have been a rule written from the four
    // files that happened to be in this folder.
    let exc = body["exception"] as? [String: Any] ?? [:]
    guard body["threads"] is [[String: Any]],
          !exc.isEmpty || body["termination"] is [String: Any] else { return nil }
    guard isOurs(head: head, body: body) else { return nil }
    guard let incident = (head["incident_id"] as? String) ?? (body["incident"] as? String)
    else { return nil }

    let at = parseStamp(head["timestamp"] as? String)
      ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate?.timeIntervalSince1970
      ?? Date().timeIntervalSince1970

    var f: [String: Any] = [
      "kind": "crash",
      "incident": incident,
      "at": at,
      "bug": head["bug_type"] as? String ?? "",
      "proc": scrub(body["procName"] as? String ?? head["app_name"] as? String ?? ""),
      "path": scrub(body["procPath"] as? String ?? ""),
      // THE VERSION THAT DIED, which is not the version doing the reporting. The
      // beat pipeline stamps `version` with the running copy's number; without
      // this field a crash in 0.58 read as a crash in whatever shipped after it,
      // and the one question a crash feed exists to answer -- did the release we
      // just pushed break -- would have been answered backwards.
      "app_version": (head["app_version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? ((body["bundleInfo"] as? [String: Any])?["CFBundleShortVersionString"] as? String ?? ""),
      "os": head["os_version"] as? String ?? osVersionString(),
      "hw": body["modelCode"] as? String ?? Telemetry.model,
      "exc": exc["type"] as? String ?? "",
      "sig": exc["signal"] as? String ?? "",
      "parent": body["parentProc"] as? String ?? "",
    ]
    if let st = exc["subtype"] as? String { f["subtype"] = scrub(st) }

    // ── WHY IT DIED, IN THE SYSTEM'S OWN WORDS ───────────────────────────────
    //
    // `termination` is the most explanatory field in the whole document and it is
    // the one a stack trace cannot replace. The report sitting in this folder
    // right now reads, in full: "This app has crashed because it attempted to
    // access privacy-sensitive data without a usage description. The app's
    // Info.plist must contain an NSMicrophoneUsageDescription key". That is the
    // entire bug report. Nothing in the stack says it.
    if let t = body["termination"] as? [String: Any] {
      let ns = t["namespace"] as? String ?? ""
      let ind = t["indicator"] as? String ?? ""
      f["term"] = scrub([ns, ind].filter { !$0.isEmpty }.joined(separator: ": "))
      if let d = t["details"] as? [String], !d.isEmpty {
        f["term_details"] = String(scrub(d.joined(separator: " | ")).prefix(400))
      }
      if let by = t["byProc"] as? String, !by.isEmpty { f["killed_by"] = scrub(by) }
    }
    // libsystem's parting words -- "abort() called", a Swift precondition
    // message, an assertion string. Free explanation when it is there.
    if let asi = body["asi"] as? [String: Any] {
      let all = asi.values.compactMap { ($0 as? [String])?.joined(separator: " ") }
      if !all.isEmpty { f["asi"] = String(scrub(all.joined(separator: " | ")).prefix(300)) }
    }

    // ── HOW LONG IT HAD BEEN RUNNING ─────────────────────────────────────────
    //
    // The difference between "it fell over on launch" and "it fell over an hour
    // into a call" is most of the diagnosis, and it decides whether a bad release
    // is an emergency. `uptime` in the document is the MACHINE's, not the
    // process's -- reading it as the process's would have said this app had been
    // running for eleven hours when it had been running for a tenth of a second.
    if let s = body["procStartAbsTime"] as? Double, let e = body["procExitAbsTime"] as? Double,
       e >= s {
      var tb = mach_timebase_info_data_t()
      mach_timebase_info(&tb)
      f["ran_ms"] = Int((e - s) * Double(tb.numer) / Double(tb.denom) / 1e6)
    } else if let a = parseStamp(body["procLaunch"] as? String),
              let b = parseStamp(body["captureTime"] as? String), b >= a {
      f["ran_ms"] = Int((b - a) * 1000)
    }

    // ── THE STACK, WITH OUR OWN FRAMES CALLED OUT ────────────────────────────
    let images = body["usedImages"] as? [[String: Any]] ?? []
    // The main binary is the image whose uuid matches the header's slice_uuid.
    // Name-independent, which is the point: this app has had five process names
    // and the uuid has never once been one of them.
    let sliceUUID = (head["slice_uuid"] as? String)?.lowercased()
    var mainIdx = 0
    if let s = sliceUUID,
       let i = images.firstIndex(where: { ($0["uuid"] as? String)?.lowercased() == s }) { mainIdx = i }
    let ftIdx = body["faultingThread"] as? Int ?? 0
    let threads = body["threads"] as? [[String: Any]] ?? []
    f["thread"] = ftIdx
    if ftIdx < threads.count {
      let t = threads[ftIdx]
      if let q = t["queue"] as? String { f["queue"] = q }
      let frames = t["frames"] as? [[String: Any]] ?? []
      f["frames"] = frames.prefix(24).map { render($0, images) }
      f["frames_total"] = frames.count
      let ours = frames.filter { ($0["imageIndex"] as? Int) == mainIdx }
      f["our_frames"] = ours.count
      // The topmost frame in OUR OWN binary. Everything above it is the runtime
      // carrying out an instruction we gave it, and this is the line to open.
      if let top = ours.first, let sym = top["symbol"] as? String { f["where"] = String(sym.prefix(140)) }
    }
    // An ObjC exception's backtrace is recorded separately and is the only place
    // the throw site appears -- the faulting thread by then is inside abort().
    if let nsb = body["lastExceptionBacktrace"] as? [[String: Any]], !nsb.isEmpty {
      f["nsframes"] = nsb.prefix(12).map { render($0, images) }
    }

    return Report(incident: incident, at: at, pid: body["pid"] as? Int ?? 0, fields: f)
  }

  private static func render(_ frame: [String: Any], _ images: [[String: Any]]) -> String {
    let idx = frame["imageIndex"] as? Int ?? -1
    var img = "?"
    if idx >= 0, idx < images.count {
      // NAME ONLY, never `path` -- the path is the field with somebody's account
      // name in it, and it says nothing a name does not.
      img = images[idx]["name"] as? String
        ?? URL(fileURLWithPath: images[idx]["path"] as? String ?? "?").lastPathComponent
    }
    if let sym = frame["symbol"] as? String, !sym.isEmpty {
      let off = frame["symbolLocation"] as? Int ?? 0
      return "\(img) \(String(sym.prefix(140))) +\(off)"
    }
    return "\(img) +\(frame["imageOffset"] as? Int ?? 0)"
  }

  // ── IS IT OURS? ────────────────────────────────────────────────────────────
  //
  // Never by name. This binary is `tk` from a build directory, `tkreal` and
  // `tk_new` from somebody's rig, `Tokkah` from an installed app up to 0.5x, and
  // `Kin` from the release that renamed it -- all five are in this machine's
  // crash folder today. Whichever of these tests fires, it is us; the point of
  // having several is that no single one survives the next rename.
  private static func isOurs(head: [String: Any], body: [String: Any]) -> Bool {
    // The bundle id has never changed and never will: it is invisible to people,
    // which is exactly why the rename left it alone.
    if (body["bundleInfo"] as? [String: Any])?["CFBundleIdentifier"] as? String == "com.tokkah.tk" {
      return true
    }
    if let csid = body["codeSigningID"] as? String {
      if csid == "com.tokkah.tk" { return true }
      // A bare binary signed ad hoc takes its file name as its identity, with the
      // cdhash appended: `tk-5555494499f22...`. Every rig copy of this app in the
      // folder carries it, including the ones whose PROCESS was renamed.
      if csid == "tk" || csid.hasPrefix("tk-") { return true }
    }
    let path = body["procPath"] as? String ?? ""
    for app in ["/Kin.app/", "/Tokkah.app/", "/KinRig.app/"] where path.contains(app) { return true }
    if let imgs = body["usedImages"] as? [[String: Any]],
       imgs.contains(where: { $0["CFBundleIdentifier"] as? String == "com.tokkah.tk" }) { return true }
    // Last, and only as a backstop: the names it has actually run under.
    let name = (body["procName"] as? String) ?? (head["app_name"] as? String) ?? ""
    return ["tk", "tk_new", "tkreal", "Tokkah", "Kin"].contains(name)
  }

  // ── SENDING ────────────────────────────────────────────────────────────────

  /// Blocks until the server has answered or given up, and says which. This runs
  /// on the crash thread at launch, never on the main thread and never on any
  /// path a call is waiting on, and the answer is load bearing: the "already
  /// sent" mark is only written when this returns true.
  private static func post(_ fields: [String: Any]) -> Bool {
    var f = fit(fields)
    f["reporter"] = "crash"
    let done = DispatchSemaphore(value: 0)
    // A box rather than a captured `var`: the answer is written on URLSession's
    // thread and read on this one, and the semaphore is what orders the two.
    final class Answer: @unchecked Sendable { var ok = false }
    let a = Answer()
    Telemetry.post(f, to: Telemetry.crashEndpoint) { good in a.ok = good; done.signal() }
    // Generous compared with a beat, because unlike a beat this is not describing
    // a live call: a crash from yesterday is still worth having.
    if done.wait(timeout: .now() + 10) != .success { return false }
    return a.ok
  }

  /// WHOLE FIELDS, NEVER A PREFIX.
  ///
  /// A truncated JSON body is not a small record, it is a corrupt one: the server
  /// parses what it can and stores a document that looks like a crash which
  /// explained nothing, and this project has already shipped exactly that bug
  /// once. So this drops named fields in increasing order of how much they
  /// explain, and writes down what it dropped -- an absence that is announced is
  /// information, an absence that is silent is a lie.
  private static func fit(_ fields: [String: Any], limit: Int = 6000) -> [String: Any] {
    var f = fields
    var dropped: [String] = []
    func size() -> Int { (try? JSONSerialization.data(withJSONObject: f))?.count ?? 0 }
    if size() <= limit { return f }
    for k in ["nsframes", "term_details", "asi", "path", "subtype"] {
      guard size() > limit else { break }
      if f.removeValue(forKey: k) != nil { dropped.append(k) }
    }
    for n in [12, 6, 3] {
      guard size() > limit else { break }
      if let fr = f["frames"] as? [String], fr.count > n {
        f["frames"] = Array(fr.prefix(n))
        dropped.append("frames>\(n)")
      }
    }
    // Still too big with three frames left means a single symbol is pathological.
    // Losing the stack entirely beats losing the exception and the version.
    if size() > limit, f.removeValue(forKey: "frames") != nil { dropped.append("frames") }
    f["dropped"] = dropped
    return f
  }

  // ── SMALL THINGS ───────────────────────────────────────────────────────────

  /// Somebody's name is in the paths. macOS redacts some of them (`/Users/USER/`)
  /// and not others (`/Applications/Kin.app` is fine, but a copy run from a home
  /// folder is not), so this does it again, unconditionally, on every string that
  /// leaves here.
  static func scrub(_ s: String) -> String {
    var t = s
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if home.count > 4 { t = t.replacingOccurrences(of: home, with: "/Users/USER") }
    // EVERY account, not just this one: `/Users/anybody/...` collapses to
    // `/Users/USER/...`, including the form macOS already redacted, which is
    // idempotent and therefore safe to run over a string twice.
    t = t.replacingOccurrences(of: "/Users/[^/\"\\s]+", with: "/Users/USER",
                               options: .regularExpression)
    // The short name can appear outside a path -- in a device name, a queue
    // label, an assertion string. Three characters is the floor at which
    // replacing it stops mangling ordinary words.
    let user = NSUserName()
    if user.count >= 3 { t = t.replacingOccurrences(of: user, with: "USER") }
    let full = NSFullUserName()
    if full.count >= 3 { t = t.replacingOccurrences(of: full, with: "USER") }
    return t
  }

  private static func osVersionString() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
  }

  /// "2026-08-25 23:14:25.00 +0530", which is what both the header and the body
  /// use. Two formats because the body's stamps carry four fractional digits.
  private static func parseStamp(_ s: String?) -> Double? {
    guard let s, !s.isEmpty else { return nil }
    for fmt in ["yyyy-MM-dd HH:mm:ss.SSSS Z", "yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
      let df = DateFormatter()
      df.locale = Locale(identifier: "en_US_POSIX")
      df.dateFormat = fmt
      if let d = df.date(from: s) { return d.timeIntervalSince1970 }
    }
    return nil
  }

  /// When this pid started, or nil if there is no such process. The second half
  /// of the liveness test: a pid is a name that gets handed on, and a run whose
  /// pid now belongs to somebody else's process is a run that died.
  private static func procStart(_ pid: pid_t) -> Double? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_starttime
    guard tv.tv_sec > 0 else { return nil }
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
  }

  /// When the machine came up. A run whose boot time is not this one did not
  /// survive a restart, which is a different finding from a process that died
  /// while the machine kept running -- and the only trace a power cut leaves.
  private static func bootTime() -> Double {
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    var tv = timeval()
    var size = MemoryLayout<timeval>.stride
    guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
  }

  // ── STATE FILES ────────────────────────────────────────────────────────────
  //
  // Two Kin processes can be running at once -- the rigs do it constantly, and so
  // does a ring answered while a call is up -- so the open-run list is read and
  // written under a real inter-process lock. Without it the second process's
  // write erases the first's record, and the first's eventual death goes
  // unreported because there is nothing left to say it ever started.

  @discardableResult
  private static func withLock<T>(_ body: () -> T) -> T {
    let fm = FileManager.default
    try? fm.createDirectory(at: Identity.dir, withIntermediateDirectories: true)
    let fd = open(lockFile.path, O_RDWR | O_CREAT, 0o644)
    guard fd >= 0 else { return body() }
    flock(fd, LOCK_EX)
    defer { flock(fd, LOCK_UN); close(fd) }
    return body()
  }

  private static func readRuns() -> [[String: Any]] {
    guard let d = try? Data(contentsOf: runsFile),
          let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
    return a
  }
  private static func writeRuns(_ runs: [[String: Any]]) { writeJSON(runs, to: runsFile) }
  private static func readSeen() -> [String: Any] {
    guard let d = try? Data(contentsOf: seenFile),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
  }
  private static func writeSeen(_ s: [String: Any]) { writeJSON(s, to: seenFile) }

  /// Written to a neighbour and renamed over the top. A half-written state file
  /// is the one failure mode that would either re-send every crash forever or
  /// send none of them again, and `rename(2)` is atomic.
  private static func writeJSON(_ o: Any, to url: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: Identity.dir, withIntermediateDirectories: true)
    guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
    let tmp = url.deletingLastPathComponent()
      .appendingPathComponent("." + url.lastPathComponent + ".\(getpid()).tmp")
    guard (try? d.write(to: tmp)) != nil else { return }
    if rename(tmp.path, url.path) != 0 { try? fm.removeItem(at: tmp) }
  }
}
