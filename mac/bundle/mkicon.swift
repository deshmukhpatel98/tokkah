// Builds Tokkah's app icon from a Material Symbols path, offline.
//
//   swift mac/bundle/mkicon.swift mac/bundle/AppIcon.icns
//
// The glyph is Material Symbols Outlined `conversation` -- two speech bubbles
// facing each other, which is the whole product in one shape.
//
// Why a path parser rather than a rasteriser: there is no SVG tool on this
// machine, the browser sandbox refuses scripts on file:// pages, and pulling
// 170 KB of base64 back out of a canvas is an absurd way to move an icon around.
// AppKit can already fill a path with the nonzero winding rule, which is the one
// thing that actually matters here -- the glyph has holes, and even-odd would
// punch the wrong ones out. So the only missing piece was a parser, and it only
// needs the commands Material actually emits: M L H V Q T Z and their relatives.
import AppKit

// ── The glyph, verbatim ───────────────────────────────────────────────────────
//
// viewBox="0 -960 960 960": x runs 0...960, y runs -960 (top) to 0 (bottom).
let GLYPH = "M161.5-541.64q-11.5-11.64-11.5-28.5t11.64-28.36q11.64-11.5 28.5-11.5t28.36 11.64q11.5 11.64 11.5 28.5t-11.64 28.36q-11.64 11.5-28.5 11.5t-28.36-11.64Zm580 0q-11.5-11.64-11.5-28.5t11.64-28.36q11.64-11.5 28.5-11.5t28.36 11.64q11.5 11.64 11.5 28.5t-11.64 28.36q-11.64 11.5-28.5 11.5t-28.36-11.64ZM40-450Zm880 0ZM140-80H80v-140h160q-63 0-106.5-43.5T90-370h60q0 38 26 64t64 26v-140h114l-45-199q-20-92-96.5-146.5T40-820v-60q116 0 208.5 67T367-634l55 237q3 14-6 25.5T393-360h-93v140q0 24.75-17.62 42.37Q264.75-160 240-160H140v80Zm740 0h-60v-80H720q-24.75 0-42.37-17.63Q660-195.25 660-220v-140h-93q-14 0-23-11.5t-6-25.5l55-237q26-112 118.5-179T920-880v60q-96.16 0-172.58 54.5Q671-711 651-619l-45 199h114v140q37-1 63.5-27.14Q810-333.29 810-370h60q0 63-44 106t-106 44h160v140ZM300-220v-60 60Zm360 0v-60 60Z"

/// An SVG path subset: absolute and relative M, L, H, V, Q, T and Z. Enough for
/// every Material Symbols glyph, and it fails loudly on anything else rather than
/// silently dropping a segment -- a missing curve in an icon looks like a design
/// choice, which is the worst way for a parser bug to present.
func parse(_ d: String) -> NSBezierPath {
  let p = NSBezierPath()
  p.windingRule = .nonZero
  var nums: [Double] = []
  var cmds: [(Character, [Double])] = []
  var cur = Character(" ")
  var token = ""

  func flushToken() {
    if !token.isEmpty, let v = Double(token) { nums.append(v) }
    token = ""
  }
  func flushCmd() {
    flushToken()
    if cur != " " { cmds.append((cur, nums)) }
    nums = []
  }

  for ch in d {
    if ch.isLetter {
      flushCmd()
      cur = ch
    } else if ch == "-" {
      // A minus starts a new number unless it is an exponent sign, which Material
      // never emits -- but "568.5-225" is two numbers and must not become one.
      if !token.isEmpty && token.last != "e" { flushToken() }
      token.append(ch)
    } else if ch == "," || ch == " " {
      flushToken()
    } else if ch == "." {
      // "0.5.5" is two numbers: a second dot begins the next one.
      if token.contains(".") { flushToken() }
      token.append(ch)
    } else {
      token.append(ch)
    }
  }
  flushCmd()

  var pt = NSPoint.zero           // current point, SVG coordinates
  var start = NSPoint.zero        // subpath start, for Z
  var lastQ: NSPoint? = nil       // last quadratic control, for T

  /// A quadratic segment as the cubic AppKit actually draws. The control points
  /// are the exact algebraic conversion, not an approximation.
  func quad(_ c: NSPoint, _ to: NSPoint) {
    let c1 = NSPoint(x: pt.x + 2.0 / 3.0 * (c.x - pt.x), y: pt.y + 2.0 / 3.0 * (c.y - pt.y))
    let c2 = NSPoint(x: to.x + 2.0 / 3.0 * (c.x - to.x), y: to.y + 2.0 / 3.0 * (c.y - to.y))
    p.curve(to: to, controlPoint1: c1, controlPoint2: c2)
    lastQ = c
    pt = to
  }

  for (cmd, a) in cmds {
    let rel = cmd.isLowercase
    switch Character(cmd.uppercased()) {
    case "M":
      var i = 0
      while i + 1 < a.count {
        let to = NSPoint(x: rel ? pt.x + a[i] : a[i], y: rel ? pt.y + a[i + 1] : a[i + 1])
        if i == 0 { p.move(to: to); start = to } else { p.line(to: to) }
        pt = to; i += 2
      }
      lastQ = nil
    case "L":
      var i = 0
      while i + 1 < a.count {
        let to = NSPoint(x: rel ? pt.x + a[i] : a[i], y: rel ? pt.y + a[i + 1] : a[i + 1])
        p.line(to: to); pt = to; i += 2
      }
      lastQ = nil
    case "H":
      for v in a { let to = NSPoint(x: rel ? pt.x + v : v, y: pt.y); p.line(to: to); pt = to }
      lastQ = nil
    case "V":
      for v in a { let to = NSPoint(x: pt.x, y: rel ? pt.y + v : v); p.line(to: to); pt = to }
      lastQ = nil
    case "Q":
      var i = 0
      while i + 3 < a.count {
        let c = NSPoint(x: rel ? pt.x + a[i] : a[i], y: rel ? pt.y + a[i + 1] : a[i + 1])
        let to = NSPoint(x: rel ? pt.x + a[i + 2] : a[i + 2], y: rel ? pt.y + a[i + 3] : a[i + 3])
        quad(c, to); i += 4
      }
    case "T":
      var i = 0
      while i + 1 < a.count {
        // The reflected control point. Without a preceding Q it is the current
        // point, per the spec.
        let c = lastQ.map { NSPoint(x: 2 * pt.x - $0.x, y: 2 * pt.y - $0.y) } ?? pt
        let to = NSPoint(x: rel ? pt.x + a[i] : a[i], y: rel ? pt.y + a[i + 1] : a[i + 1])
        quad(c, to); i += 2
      }
    case "Z":
      p.close(); pt = start; lastQ = nil
    default:
      FileHandle.standardError.write("mkicon: unsupported path command '\(cmd)'\n".data(using: .utf8)!)
      exit(2)
    }
  }
  return p
}


/// The plate, at one size. One definition, so the fit test and the render can
/// never disagree about where the edge is.
///
/// Apple's grid: the artwork is inset ~9.77% of the canvas and the corner radius is
/// ~22.37% of the artwork, which is what makes it sit level with every other icon in
/// the Dock instead of looking a size too big. Circular corners, not a sampled
/// squircle -- Apple's own plates measure out as a plain rounded rect, and a
/// superellipse looks visibly puffy beside the real thing.
func Self_plate(_ S: CGFloat) -> (NSRect, NSBezierPath) {
  let m = S * 0.0977
  let box = S - 2 * m
  let r = box * 0.2237
  let tile = NSRect(x: m, y: m, width: box, height: box)
  return (tile, NSBezierPath(roundedRect: tile, xRadius: r, yRadius: r))
}

/// One icon, at one size. Apple's grid: the artwork is inset ~9.77% and the
/// squircle's corner radius is ~22.37% of the artwork, which is what makes it sit
/// level with every other icon in the Dock instead of looking a size too big.
func render(_ S: CGFloat, glyph: NSBezierPath, clipToPlate: Bool = false) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high

  let (tile, squircle) = Self_plate(S)
  let box = tile.width

  // The app's own background, with a slight lift so a 512 px tile does not read
  // as a flat sticker.
  let grad = NSGradient(colors: [NSColor(srgbRed: 0x06/255.0, green: 0x08/255.0, blue: 0x0d/255.0, alpha: 1),
                                 NSColor(srgbRed: 0x1b/255.0, green: 0x27/255.0, blue: 0x40/255.0, alpha: 1)])!
  grad.draw(in: squircle, angle: 90)   // 90 = upward, so the light edge is at the top
  // The same --glass-line hairline the app uses everywhere else.
  NSColor(white: 1, alpha: 0.14).setStroke()
  squircle.lineWidth = max(1, S / 512)
  squircle.stroke()

  // ── FIT THE INK, NOT THE VIEWBOX ──────────────────────────────────────────
  //
  // `(x, y) -> (x*k, -y*k)` is the whole coordinate change: SVG's y grows downward
  // and this viewBox is entirely negative, so ONE sign flip does it. The first
  // version also translated by -960 "to account for the offset", which double-
  // counted the flip and threw the glyph a full tile above the squircle -- it drew
  // perfectly, in the wrong place, and every automated check passed because the
  // centre pixel of an opaque tile is opaque either way.
  //
  // And it fits the glyph's MEASURED bounds rather than the nominal 960 box,
  // because Material glyphs do not fill their viewBox: `conversation` spans
  // 40...920, so centring on the box leaves it visibly off-centre and small.
  // How much of the tile the faces occupy. At 0.68 the glyph floated in the middle
  // with a wide empty border and read as unfinished -- the Human app's icon next
  // door fills 0.765 and that is the low end of what looks deliberate. Overridable
  // so the choice can be made by looking rather than by arguing.
  let gs = box * GLYPH_FRACTION
  let flip = NSAffineTransform()
  flip.scaleX(by: 1, yBy: -1)
  let upright = glyph.copy() as! NSBezierPath
  upright.transform(using: flip as AffineTransform)
  let ink = upright.bounds
  guard ink.width > 0, ink.height > 0 else { return rep }
  let k = min(gs / ink.width, gs / ink.height)
  let t = NSAffineTransform()
  t.translateX(by: tile.midX - ink.midX * k, yBy: tile.midY - ink.midY * k)
  t.scaleX(by: k, yBy: k)
  let g = upright.copy() as! NSBezierPath
  g.transform(using: t as AffineTransform)
  if clipToPlate { squircle.addClip() }
  NSColor.white.setFill()
  g.fill()

  NSGraphicsContext.restoreGraphicsState()
  return rep
}

// ── main ──────────────────────────────────────────────────────────────────────
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let GLYPH_FRACTION = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 0.88) : 0.88
let glyph = parse(GLYPH)
if glyph.isEmpty {
  FileHandle.standardError.write("mkicon: the path parsed to nothing\n".data(using: .utf8)!)
  exit(1)
}

// ── DOES THE ART STAY ON THE PLATE? ──────────────────────────────────────────
//
// Nothing clips the glyph, so too large a fraction does not get cut off -- it
// draws straight past the rounded corners onto transparent background, and the
// plate curving away behind it is what makes it LOOK cut off. At 0.96 both heads
// spill over the top corners. Judging that by eye works exactly until the glyph
// changes.
//
// So it is measured: draw the glyph once free and once clipped to the plate, and
// compare. Any difference is art that is not on the plate. Exact, and it costs one
// extra 1024px render.
do {
  let free = render(1024, glyph: glyph)
  let clipped = render(1024, glyph: glyph, clipToPlate: true)
  var spilled = 0
  for y in stride(from: 0, to: 1024, by: 2) {
    for x in stride(from: 0, to: 1024, by: 2) {
      let a = free.colorAt(x: x, y: y), b = clipped.colorAt(x: x, y: y)
      if let a, let b, abs(a.brightnessComponent - b.brightnessComponent) > 0.15 { spilled += 1 }
    }
  }
  if spilled > 0 {
    FileHandle.standardError.write(
      "mkicon: the glyph spills off the plate at \(GLYPH_FRACTION) (\(spilled) sample points).\n"
      .data(using: .utf8)!)
    exit(1)
  }
  print("mkicon: glyph fits the plate at \(GLYPH_FRACTION)")
}

let fm = FileManager.default
let set = fm.temporaryDirectory.appendingPathComponent("Tokkah-\(UUID().uuidString).iconset")
try? fm.createDirectory(at: set, withIntermediateDirectories: true)

// iconutil's exact filenames. Both scales of each logical size, because a missing
// @2x is how an icon ends up blurry on the only display anybody has.
let plan: [(Int, String)] = [
  (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
  (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
  (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
  (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
  (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
var opaque = 0
for (px, name) in plan {
  let rep = render(CGFloat(px), glyph: glyph)
  // PROVE SOMETHING WAS DRAWN. A transparent PNG is a perfectly valid file and an
  // icon nobody can see, and it is exactly what a parser that dropped every
  // segment would produce.
  if let c = rep.colorAt(x: px / 2, y: px / 2), c.alphaComponent > 0.9 { opaque += 1 }
  guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
  try? png.write(to: set.appendingPathComponent(name))
}
guard opaque == plan.count else {
  FileHandle.standardError.write("mkicon: \(plan.count - opaque) of \(plan.count) sizes came out transparent\n"
    .data(using: .utf8)!)
  exit(1)
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { exit(p.terminationStatus) }
try? fm.removeItem(at: set)
let size = (try? fm.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
print("mkicon: wrote \(out) (\(size) bytes, \(plan.count) sizes, all opaque)")
