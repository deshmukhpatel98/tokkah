import AppKit

// ── The part that makes it an application ────────────────────────────────────
//
// Everything else in this program is about the twelve milliseconds above the
// speed of light. None of it mattered, because the window had no controls, no way
// to invite anyone, and closing it left the camera running with nothing on screen.
// A call you cannot mute, cannot leave and cannot invite anyone to is a
// measurement rig with a picture on it.
//
// Deliberately small: mic, camera, invite, leave, and the room you are in. Every
// one of those is something a person needs within the first ten seconds of a call
// and had no way to do at all.
final class CallControls: NSView {
  private let roomLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let micButton = NSButton()
  private let camButton = NSButton()
  /// How tall the bar is, published so the self-view can sit above it instead of
  /// a second file guessing 72 and drifting.
  static let barHeight: CGFloat = 72

  private let inviteButton = NSButton()
  private let leaveButton = NSButton()

  // ── HOW THE CALL IS GOING, WHERE THE PERSON CAN SEE IT ────────────────────
  //
  // This program measures mouth-to-ear latency, packet loss, concealment and
  // repair to a precision most video apps never reach -- and showed the person on
  // the call exactly none of it. When a call goes bad the first thing they need is
  // to know whether it is them, and the second is proof it is not, and the app had
  // every number and no way to say either.
  //
  // Said in words, not milliseconds, and short: nobody on a call wants a
  // dashboard. The number is there for the curious and the word is there for
  // everyone. A separate label from `statusLabel` because mute state and line
  // quality are different facts and one of them must not overwrite the other.
  private let qualityLabel = NSTextField(labelWithString: "")
  /// Seconds since the call connected. Every call app on earth shows this; it is
  /// how a person knows the app has not silently died.
  private var startedAt: Date?

  /// Set once, when the far end's media first arrives.
  func markConnected() {
    if startedAt == nil { startedAt = Date() }
  }

  /// Latency in ms and the fraction of audio that had to be invented, once a
  /// second. Turns the numbers into a sentence, and a colour.
  func setQuality(m2eMs: Double?, concealPct: Double, lossPct: Double) {
    var parts: [String] = []
    if let t = startedAt {
      let s = Int(Date().timeIntervalSince(t))
      parts.append(String(format: "%d:%02d", s / 60, s % 60))
    }
    var word = "", colour = NSColor.white.withAlphaComponent(0.55)
    if let ms = m2eMs, ms > 0 {
      parts.append("\(Int(ms.rounded())) ms")
      // Thresholds in the units a listener actually notices. Concealment is the
      // honest one -- it is audio the far end never heard, so it outranks latency:
      // a 40 ms call that drops nothing sounds better than a 15 ms one that does.
      if concealPct > 1.0 { word = "breaking up"; colour = NSColor.systemRed }
      else if concealPct > 0.1 { word = "patchy"; colour = NSColor.systemOrange }
      else if ms < 60 { word = "clear" }
      else if ms < 150 { word = "good" }
      else { word = "far away"; colour = NSColor.systemOrange }
    }
    if lossPct >= 0.5, word == "clear" || word == "good" {
      // The line is losing packets and we are repairing them. The person should
      // know their network is struggling even while it still sounds fine.
      word += " (repairing)"
    }
    if !word.isEmpty { parts.append(word) }
    let text = parts.joined(separator: " · ")
    DispatchQueue.main.async { [weak self] in
      self?.qualityLabel.stringValue = text
      self?.qualityLabel.textColor = colour
    }
  }

  /// True means muted / camera off, matching what the button then offers to undo.
  private(set) var micMuted = false
  private(set) var camOff = false

  var onMic: ((Bool) -> Void)?
  var onCam: ((Bool) -> Void)?
  var onLeave: (() -> Void)?
  /// What lands on the clipboard. Set by the caller, because only it knows the
  /// room and the install URL.
  var inviteText = ""

  private let room: String

  init(room: String, width: CGFloat) {
    self.room = room
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: CallControls.barHeight))
    autoresizingMask = [.width]

    roomLabel.stringValue = room
    roomLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    roomLabel.textColor = .white
    addSubview(roomLabel)

    statusLabel.stringValue = "waiting for the other side"
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = NSColor.white.withAlphaComponent(0.6)
    addSubview(statusLabel)

    qualityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    qualityLabel.textColor = NSColor.white.withAlphaComponent(0.55)
    qualityLabel.alignment = .right
    addSubview(qualityLabel)

    styleRound(micButton, symbol: "mic.fill", action: #selector(toggleMic))
    styleRound(camButton, symbol: "video.fill", action: #selector(toggleCam))
    stylePill(inviteButton, title: "Copy invite", action: #selector(invite))
    stylePill(leaveButton, title: "Leave", action: #selector(leave))
    leaveButton.contentTintColor = .white

    layoutBar()
  }

  required init?(coder: NSCoder) { nil }

  /// DRAWN, not layer-coloured. The first version set background colours on
  /// CALayers, which looks right on screen and is invisible to every way of
  /// photographing it -- `cacheDisplay` drives `draw(_:)` and a layer colour has no
  /// draw, and `CALayer.render(in:)` produced an empty bitmap too. A control that
  /// cannot be photographed cannot be reviewed, so the bar and the button discs are
  /// drawn in `draw(_:)` and the buttons carry only their symbol.
  private func styleRound(_ b: NSButton, symbol: String, action: Selector) {
    b.bezelStyle = .circular
    b.isBordered = false
    b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    b.imageScaling = .scaleProportionallyDown
    b.contentTintColor = .white
    // NO KEYBOARD FOCUS. The camera button rendered as a filled accent-coloured
    // disc at startup -- not a bug in the drawing, macOS filling the focused
    // control with the user's accent colour. It read as "camera off" when the
    // camera was on, which is the worst possible thing for this particular button
    // to be wrong about. Call controls are pointed at, not tabbed through.
    b.refusesFirstResponder = true
    b.focusRingType = .none
    b.target = self
    b.action = action
    addSubview(b)
  }

  private func stylePill(_ b: NSButton, title: String, action: Selector) {
    b.title = title
    b.bezelStyle = .rounded
    b.isBordered = false
    b.font = .systemFont(ofSize: 12, weight: .medium)
    b.contentTintColor = .white
    b.refusesFirstResponder = true
    b.focusRingType = .none
    b.attributedTitle = NSAttributedString(string: title, attributes: [
      .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    ])
    b.target = self
    b.action = action
    addSubview(b)
  }

  /// Laid out by hand rather than with constraints. Five controls in a row is not
  /// worth an auto-layout graph, and `layout()` re-running this on every resize is
  /// the whole requirement.
  private func layoutBar() {
    let w = bounds.width, h = bounds.height
    roomLabel.frame = NSRect(x: 20, y: h / 2 + 1, width: 240, height: 18)
    statusLabel.frame = NSRect(x: 20, y: h / 2 - 17, width: 300, height: 16)
    // Right of centre, left of the invite/leave buttons: the middle belongs to the
    // mic and camera, which are the two things reached for in a hurry.
    qualityLabel.frame = NSRect(x: w / 2 + 70, y: h / 2 - 8, width: max(80, w / 2 - 300), height: 16)
    let mid = w / 2
    micButton.frame = NSRect(x: mid - 50, y: h / 2 - 22, width: 44, height: 44)
    camButton.frame = NSRect(x: mid + 6, y: h / 2 - 22, width: 44, height: 44)
    leaveButton.frame = NSRect(x: w - 20 - 84, y: h / 2 - 16, width: 84, height: 32)
    inviteButton.frame = NSRect(x: w - 20 - 84 - 8 - 110, y: h / 2 - 16, width: 110, height: 32)
  }

  override func layout() {
    super.layout()
    layoutBar()
  }

  override func draw(_ dirtyRect: NSRect) {
    // Translucent, so the picture continues behind the bar and it reads as part of
    // the call rather than a strip cut out of it.
    NSColor.black.withAlphaComponent(0.62).setFill()
    bounds.fill()
    // A hairline along the top edge, which is what stops the bar looking like a
    // rendering artefact when the picture behind it is dark.
    NSColor.white.withAlphaComponent(0.12).setFill()
    NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

    disc(micButton.frame, on: micMuted)
    disc(camButton.frame, on: camOff)
    pill(inviteButton.frame, colour: NSColor.white.withAlphaComponent(0.18))
    pill(leaveButton.frame, colour: NSColor.systemRed)
  }

  private func disc(_ r: NSRect, on: Bool) {
    (on ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.18)).setFill()
    NSBezierPath(ovalIn: r).fill()
  }

  private func pill(_ r: NSRect, colour: NSColor) {
    colour.setFill()
    NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
  }

  func setStatus(_ s: String) {
    // Applied immediately when already on main. The unconditional hop meant a
    // status set from a main-thread handler did not land until after the current
    // block finished -- harmless on screen, and it made every photograph of a
    // freshly-toggled control show the previous state.
    if Thread.isMainThread { statusLabel.stringValue = s; return }
    DispatchQueue.main.async { self.statusLabel.stringValue = s }
  }

  @objc private func toggleMic() {
    micMuted.toggle()
    micButton.image = NSImage(systemSymbolName: micMuted ? "mic.slash.fill" : "mic.fill",
                              accessibilityDescription: nil)
    // Red when it is doing something the person needs to notice. A muted mic that
    // looks the same as a live one is how people talk to nobody for a minute.
    needsDisplay = true
    onMic?(micMuted)
  }

  @objc private func toggleCam() {
    camOff.toggle()
    camButton.image = NSImage(systemSymbolName: camOff ? "video.slash.fill" : "video.fill",
                              accessibilityDescription: nil)
    needsDisplay = true
    onCam?(camOff)
  }

  @objc private func invite() {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(inviteText, forType: .string)
    // Say it worked. A button that copies silently is a button people press four
    // times because they cannot tell whether it did anything.
    inviteButton.attributedTitle = NSAttributedString(string: "Copied", attributes: [
      .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    ])
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
      self?.inviteButton.attributedTitle = NSAttributedString(string: "Copy invite", attributes: [
        .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .medium),
      ])
    }
  }

  @objc private func leave() { onLeave?() }

  /// Press a control from the rig. A button that is drawn but wired to nothing
  /// looks identical in a photograph, and clicking one for real needs accessibility
  /// permission the test harness does not have.
  func simulate(_ what: String) {
    switch what {
    case "mic": toggleMic()
    case "cam": toggleCam()
    case "invite": invite()
    case "leave": leave()
    default: fputs("press: no control called \(what)\n", stderr)
    }
  }
}

// ── Closing the window has to end the call ───────────────────────────────────
//
// It did not. `NSWindow` was created with `.closable` and no delegate, so closing
// it left the process running with no window at all: the camera light stays on,
// the microphone stays open, and the only way out is Activity Monitor. That is a
// privacy bug, not a tidiness one, and it is the first thing anybody does when
// they want a call to stop.
final class WindowCloser: NSObject, NSWindowDelegate {
  private let onClose: () -> Void
  init(onClose: @escaping () -> Void) { self.onClose = onClose }
  func windowWillClose(_ notification: Notification) { onClose() }
}
