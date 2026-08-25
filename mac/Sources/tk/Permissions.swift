import AVFoundation
import AppKit
import Foundation

// ── "OPEN SYSTEM SETTINGS" IS NOT AN INSTRUCTION, IT IS A DEAD END ──────────
//
// The report this file exists for, in the user's words:
//
//     "All permissions that are required -- you should navigate the user to
//      there. So it's just single clicks for the user, not that they have to find
//      the setting in the setting in the setting."
//
// What Kin did before this file: the camera-denied path in `Launcher.swift` had
// one "Open Settings" pill with a URL typed inline, and that was the whole of it.
// The MICROPHONE -- the permission whose failure is least visible, because a
// denied mic and a muted mic and a wrong input device all produce the identical
// symptom of the other person hearing nothing -- had no button anywhere. Its only
// surface was a line on stderr that nobody who double-clicks an app will ever
// read, and one of those lines (`main.swift`, the second status check) still
// tells the person to enable "the app you launched this from (Terminal, iTerm, VS
// Code...)", which is correct advice for the command-line binary this used to be
// and actively wrong advice inside Kin.app, where the thing to switch on is Kin.
//
// So: one place that knows what Kin needs, what the answer is right now, what to
// say about it in a sentence a person would say out loud, and which URL lands ON
// the pane with Kin already in the list.
//
// ── THE PART THAT HAD TO BE MEASURED RATHER THAN LOOKED UP ─────────────────
//
// A `x-apple.systempreferences:` URL with a stale pane identifier does not fail.
// It opens System Settings at the TOP, which is precisely the "setting in the
// setting in the setting" the complaint is about, now wearing the clothes of a
// fix -- and `NSWorkspace.open` returns true for it, and `open(1)` exits 0 for
// it, so nothing in the process can tell that it did not work. The identifiers
// changed once with the Ventura System Settings rewrite and have moved again
// since, so every URL below was opened on this machine (macOS 27.0, build
// 26A5421a) and checked against where the window ACTUALLY landed, with System
// Settings first forced onto a different pane so that "did not move" could be
// told apart from "moved to the right place":
//
//     ?Privacy_Camera              -> "Camera"                            EXACT
//     ?Privacy_Microphone          -> "Microphone"                        EXACT
//     LoginItems-Settings          -> "Login Items"                       EXACT
//     ?Privacy_LocalNetwork        -> "Privacy & Security"          THE TOP LEVEL
//
// The Camera one was also screenshotted, and Kin is in the list with its own
// switch -- which is the actual thing being promised, not merely a pane title.
//
// The fourth line is why `Landing` below has more than one case. There is no
// anchor for Local Network on this macOS: `Privacy_LocalNetwork`,
// `privacy-localnetwork`, `Privacy_LocalNetworkService`, `LocalNetwork` and
// `Privacy_Network` were all tried and all four land on the Privacy & Security
// list, and the extension's own binary contains no `Privacy_LocalNetwork` string
// at all while it does contain `Privacy_Camera` and `Privacy_Microphone` -- so
// this is an absence, not a spelling. Rather than ship a button that claims to
// take somebody somewhere it does not, that case is named `.nearby` and the API
// says so out loud, so a caller can word its button honestly.
enum Permissions {

  // ── WHAT KIN ACTUALLY NEEDS ────────────────────────────────────────────────
  //
  // Audited against the source rather than assumed, because a permissions screen
  // that lists things the app does not use trains people to ignore it:
  //
  //   camera        AVCaptureDevice .video, asked for in Video.swift and used
  //                 from three call sites.
  //   microphone    AVCaptureDevice .audio, asked for on EVERY launch in
  //                 main.swift. Also covers the CoreAudio HAL input path in
  //                 Audio.swift -- one grant, not two.
  //   localNetwork  never requested in code, and triggered anyway: `Net.swift`
  //                 sends a UDP probe to the peer's private LAN address, and on
  //                 macOS 15 and later that alone raises the prompt.
  //   ringWhenClosed  not a TCC permission at all -- the LaunchAgent in
  //                 Watch.swift, which macOS lets a person switch off under Login
  //                 Items. It is in this list because from the outside it is the
  //                 same shape of problem ("macOS is refusing, and the fix is a
  //                 switch in Settings"), and because leaving it out would mean
  //                 two different mechanisms for two rows of one panel.
  //
  // Deliberately NOT here, each verified absent in the source: screen recording,
  // accessibility, notifications (the ringtone is played directly, there is no
  // notification API anywhere), automation/AppleEvents (Kin receives them for
  // `kin://` links, which needs no grant, and never sends one), input monitoring,
  // full disk access, and speech recognition -- `AppleSpeech.swift` uses the
  // on-device `SpeechAnalyzer`, and it was checked that this leaves
  // `SFSpeechRecognizer.authorizationStatus()` untouched.
  enum Need: String, CaseIterable {
    case camera, microphone, localNetwork, ringWhenClosed
  }

  /// What macOS says right now.
  ///
  /// `cannotTell` is a real answer and not a failure. macOS publishes no API for
  /// reading Local Network authorisation, and the honest thing to do with that is
  /// say so rather than default to `granted` -- a reader that reports "fine" for
  /// something it cannot see is indistinguishable from a working one right up to
  /// the moment somebody relies on it.
  enum State { case granted, notAsked, denied, restricted, cannotTell }

  /// Where a button can actually take somebody.
  ///
  /// `.exact` means the URL was measured landing on that pane with Kin in it.
  /// `.nearby` means the closest page macOS will open, with the row still to be
  /// found by hand -- one scroll, not four levels, but not a single click either,
  /// and a caller is entitled to know the difference so it can say "Show me
  /// where" instead of "Turn it on".
  enum Landing {
    case exact(String)
    case nearby(String)
    case nowhere

    var paneName: String? {
      switch self {
      case .exact(let n), .nearby(let n): return n
      case .nowhere: return nil
      }
    }
    var isExact: Bool { if case .exact = self { return true }; return false }
  }

  struct Status {
    let need: Need
    let state: State
    /// The name a person would use. Not the TCC service name.
    let title: String
    /// One sentence, plain, in the app's voice: what is true and what it costs
    /// them. Empty when there is nothing to say, which is the common case and the
    /// one a panel should render as silence rather than as "OK".
    let says: String
    /// The button's words, or nil when there is no button to draw.
    let action: String?
    /// True when this is standing between the person and a working call RIGHT
    /// NOW. `notAsked` is deliberately false: macOS will ask at the natural
    /// moment, and pre-emptively nagging about a dialog that has not happened yet
    /// is how a settings panel becomes something people close.
    let blocking: Bool
    /// Where `reveal` would take them.
    let landing: Landing
  }

  // ── THE URLS ───────────────────────────────────────────────────────────────
  //
  // `com.apple.settings.PrivacySecurity.extension` is the pane's real bundle
  // identifier on macOS 13 and later; its Info.plist carries
  // `legacyBundleIdentifier = com.apple.preference.security` and
  // `allowsXAppleSystemPreferencesURLScheme = 1`, and BOTH forms were measured
  // landing on the right pane here. The modern one is used because it is the
  // extension's own identity and cannot be dropped without the extension itself
  // moving; the legacy one is kept as a fallback for the single case that can be
  // detected at runtime -- the URL not being handled at all.
  //
  // What CANNOT be detected at runtime is the case this comment exists for: a
  // handled URL with an anchor macOS no longer knows, which opens the top of
  // Privacy & Security and reports success. There is no return value for that.
  // The only instrument that sees it is a person opening the window and reading
  // the title, which is what was done, and `mac/tools/permissions-check.sh` locks
  // the strings down afterwards so a silent edit cannot rot them.
  private static let privacyPane = "com.apple.settings.PrivacySecurity.extension"
  private static let privacyPaneLegacy = "com.apple.preference.security"

  /// The anchor within Privacy & Security, or nil where macOS has none.
  private static func anchor(_ n: Need) -> String? {
    switch n {
    case .camera: return "Privacy_Camera"
    case .microphone: return "Privacy_Microphone"
    // Measured absent. Sending `Privacy_LocalNetwork` anyway is not a mistake:
    // macOS ignores the unknown anchor and opens Privacy & Security, which is the
    // page the Local Network row is on, and that is the best landing that exists.
    case .localNetwork: return "Privacy_LocalNetwork"
    case .ringWhenClosed: return nil
    }
  }

  /// The URL a button opens, and the legacy spelling to try if that one is not
  /// handled at all. Public because the rig asserts on it without opening
  /// anything: a Settings window thrown at whoever is using this Mac is not an
  /// acceptable price for a test, so the automated check reads status and builds
  /// URLs, and the landings were confirmed by hand once.
  static func settingsURLs(_ n: Need) -> [URL] {
    let specs: [String]
    switch n {
    case .ringWhenClosed:
      // Not a privacy pane -- its own settings extension. Measured landing on
      // "Login Items". This is the one URL that was already in the app, in
      // Controls.swift, and it was already right.
      specs = ["com.apple.LoginItems-Settings.extension"]
    default:
      let a = anchor(n).map { "?" + $0 } ?? ""
      specs = [privacyPane + a, privacyPaneLegacy + a]
    }
    return specs.compactMap { URL(string: "x-apple.systempreferences:" + $0) }
  }

  static func landing(_ n: Need) -> Landing {
    switch n {
    case .camera: return .exact("Camera")
    case .microphone: return .exact("Microphone")
    case .localNetwork: return .nearby("Privacy & Security")
    case .ringWhenClosed: return .exact("Login Items")
    }
  }

  // ── OPENING IT ─────────────────────────────────────────────────────────────
  //
  // The whole point of the file, and the half that a `dead-controls-declared-
  // never-wired` reading of this codebase says will be the half that quietly does
  // nothing. So: it returns whether it opened, it is counted, and it is called
  // from `Launcher.swift` and from `tk --permissions-open` as well as from the
  // settings sheet, so no single caller going missing makes it dead.
  @discardableResult
  static func reveal(_ n: Need) -> Bool {
    for u in settingsURLs(n) {
      if NSWorkspace.shared.open(u) {
        Metrics.tap("perm_reveal_" + n.rawValue, ok: true)
        fputs("permissions: opened \(landing(n).paneName ?? "System Settings") for \(n.rawValue)\n", stderr)
        return true
      }
    }
    // Every spelling refused. Nothing left to do automatically, and saying so
    // beats a button that shrugs.
    Metrics.tap("perm_reveal_" + n.rawValue, ok: false)
    fputs("permissions: could not open Settings for \(n.rawValue)\n", stderr)
    return false
  }

  // ── READING THE ANSWER ─────────────────────────────────────────────────────

  /// The raw OS answer for the two TCC services Kin asks for.
  ///
  /// ── THE ONE SEAM, AND WHY IT IS HERE ──────────────────────────────────────
  ///
  /// `TK_PERM_FAKE=camera=denied,microphone=notAsked` substitutes the answer at
  /// this exact line and nowhere else. Everything downstream -- the state
  /// mapping, the sentence, the button words, the blocking verdict, the URL --
  /// is the shipping code running on a different input.
  ///
  /// It exists because of a specific way this rig could have been worthless. On
  /// the machine this was built on, Kin has the camera and the microphone, so a
  /// status check runs, prints "granted, granted", and passes. A reader that
  /// returned `.granted` unconditionally -- a `switch` with a wrong default, a
  /// mapping that collapsed all four cases -- would print exactly the same thing
  /// and pass exactly as well. Green metrics can hide defects, and a rig with no
  /// arm that ranks the other way is not measuring the reader, it is measuring
  /// the host's TCC database.
  ///
  /// What it does NOT prove is that the syscall itself is real, since that is the
  /// line being replaced. That half is covered by the live arm, which reads the
  /// true state of two different services and is allowed to print anything.
  /// Production never sets this; it is the same shape as `TK_KIN_DIR` and
  /// `TK_NO_IDENTITY`.
  private static func rawStatus(_ n: Need) -> AVAuthorizationStatus? {
    let media: AVMediaType
    switch n {
    case .camera: media = .video
    case .microphone: media = .audio
    default: return nil
    }
    if let fake = fakes[n] { return fake }
    return AVCaptureDevice.authorizationStatus(for: media)
  }

  private static let fakes: [Need: AVAuthorizationStatus] = {
    guard let raw = ProcessInfo.processInfo.environment["TK_PERM_FAKE"], !raw.isEmpty else { return [:] }
    var out: [Need: AVAuthorizationStatus] = [:]
    for pair in raw.split(separator: ",") {
      let bits = pair.split(separator: "=", maxSplits: 1)
      guard bits.count == 2, let need = Need(rawValue: String(bits[0])) else { continue }
      switch bits[1] {
      case "granted": out[need] = .authorized
      case "denied": out[need] = .denied
      case "restricted": out[need] = .restricted
      case "notAsked": out[need] = .notDetermined
      default: continue
      }
    }
    if !out.isEmpty {
      fputs("permissions: TK_PERM_FAKE is substituting \(out.count) answer(s) -- this is a test arm\n", stderr)
    }
    return out
  }()

  static func state(_ n: Need) -> State {
    switch n {
    case .camera, .microphone:
      switch rawStatus(n) {
      case .authorized: return .granted
      case .denied: return .denied
      case .restricted: return .restricted
      case .notDetermined: return .notAsked
      default: return .denied
      }
    case .localNetwork:
      // No public API, and no honest way to infer one. What could be inferred --
      // "a LAN candidate answered" -- is only available mid-call and is false for
      // every legitimate reason a direct path loses the race, so it would report a
      // denial that is not there. `blind-instruments-report-negatives`: an
      // instrument that cannot see the event returns the same value as a real
      // negative, so this one says it cannot see.
      return .cannotTell
    case .ringWhenClosed:
      return Watch.reach().on ? .granted : .denied
    }
  }

  static func status(_ n: Need) -> Status {
    let s = state(n)
    let land = landing(n)
    switch n {
    case .camera:
      switch s {
      case .granted: return Status(need: n, state: s, title: "Camera", says: "", action: nil, blocking: false, landing: land)
      case .notAsked: return Status(need: n, state: s, title: "Camera",
                                    says: "Kin will ask for the camera on your first call.",
                                    action: nil, blocking: false, landing: land)
      case .restricted: return Status(need: n, state: s, title: "Camera",
                                      says: "Camera use is blocked on this Mac, so they won\u{2019}t see you.",
                                      // No button: the switch exists and this
                                      // person cannot move it. A button that
                                      // opens a pane to show somebody a control
                                      // they are not allowed to touch is worse
                                      // than no button.
                                      action: nil, blocking: true, landing: land)
      default: return Status(need: n, state: s, title: "Camera",
                             says: "Camera is off, so they won\u{2019}t see you.",
                             action: "Turn on Camera", blocking: true, landing: land)
      }
    case .microphone:
      switch s {
      case .granted: return Status(need: n, state: s, title: "Microphone", says: "", action: nil, blocking: false, landing: land)
      case .notAsked: return Status(need: n, state: s, title: "Microphone",
                                    says: "Kin will ask for the microphone on your first call.",
                                    action: nil, blocking: false, landing: land)
      case .restricted: return Status(need: n, state: s, title: "Microphone",
                                      says: "Microphone use is blocked on this Mac, so they\u{2019}ll hear silence.",
                                      action: nil, blocking: true, landing: land)
      default: return Status(need: n, state: s, title: "Microphone",
                             // Says what it costs, not what it is. "Microphone
                             // access denied" is a fact about the Mac; "they will
                             // hear silence" is a fact about the call, and only
                             // one of those makes somebody press the button.
                             says: "Microphone is off, so they\u{2019}ll hear silence from you.",
                             action: "Turn on Microphone", blocking: true, landing: land)
      }
    case .localNetwork:
      return Status(need: n, state: s, title: "Local Network",
                    // Not phrased as a problem, because it usually is not one and
                    // cannot be read either way. It is here so that the person who
                    // DID say no once has somewhere to go, which is the case that
                    // otherwise ends as "calls are slow and I don't know why".
                    says: "On the same Wi\u{2011}Fi, Kin connects straight to them. macOS asks once.",
                    action: "Show me where", blocking: false, landing: land)
    case .ringWhenClosed:
      let r = Watch.reach()
      if r.on { return Status(need: n, state: s, title: "Calls when Kin is closed", says: "", action: nil, blocking: false, landing: land) }
      // Watch.reach already answers this in the person's words, and it knows
      // things this file does not -- whether Kin is even in Applications. Reused
      // rather than restated, so the two panels cannot drift apart.
      return Status(need: n, state: s, title: "Calls when Kin is closed", says: r.says,
                    action: r.fix == .openLoginItems ? "Open Login Items" : nil,
                    blocking: false, landing: land)
    }
  }

  static func all() -> [Status] { Need.allCases.map(status) }

  /// Only the things actually standing in the way, for a caller that wants to say
  /// something at the moment it matters rather than draw a whole panel.
  static func blocking() -> [Status] { all().filter(\.blocking) }

  // ── FOR A TERMINAL, NOT FOR A PERSON ───────────────────────────────────────
  //
  // `tk --permissions`. Everything above is consumer-surface wording with no
  // diagnostics in it; this is the other audience, and it prints the machine
  // facts -- the state name, whether the landing is exact, and the URL that will
  // be opened -- so that a rig can assert on them and a bug report can carry
  // them.
  static func report() -> String {
    var lines: [String] = []
    for st in all() {
      let land: String
      switch st.landing {
      case .exact(let p): land = "exact:\(p)"
      case .nearby(let p): land = "nearby:\(p)"
      case .nowhere: land = "nowhere"
      }
      lines.append("permission \(st.need.rawValue) state=\(st.state) blocking=\(st.blocking)"
                 + " landing=\(land) url=\(settingsURLs(st.need).first?.absoluteString ?? "-")"
                 + " action=\(st.action ?? "-") says=\(st.says.isEmpty ? "-" : st.says)")
    }
    return lines.joined(separator: "\n")
  }
}
