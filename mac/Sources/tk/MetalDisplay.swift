import AppKit
import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import QuartzCore

// ── The display path, and the instrument for it ──────────────────────────────
//
// AVSampleBufferDisplayLayer is a good layer and it is not the problem. The
// problem is that everything handed to CoreAnimation waits for the compositor's
// next synchronised pass and then a scanout, and `CVDisplayLink` measured that on
// this machine as 22.98 ms -- one and a bit refresh periods at 60 Hz. That is
// larger than the entire audio mouth-to-ear, and four times what the codec and
// the network cost put together. It was also the one number in this project I had
// never measured: every video figure said "+ ~8 ms mean compositor", which is
// half a refresh period, an assumption, and wrong.
//
// Two reasons to draw it by hand instead.
//
// FIRST, IT CAN BE MEASURED. `MTLDrawable.addPresentedHandler` reports
// `presentedTime` -- when the frame actually reached the display, from the
// system, with no camera pointed at the panel and no screen-recording
// permission. AVSampleBufferDisplayLayer offers nothing equivalent, which is
// exactly why the display term stayed a guess for so long.
//
// SECOND, `displaySyncEnabled = false` presents as soon as the GPU is done
// instead of waiting for the synchronised pass. That trades tearing for most of a
// refresh period. On a talking head tearing is close to invisible; 16 ms is a
// tenth of the entire 150 ms budget. But it is a trade, so it is a flag, and the
// numbers below decide it rather than my opinion.
final class MetalDisplay {
  private var win: NSWindow?
  private let layer = CAMetalLayer()
  private let dev: MTLDevice
  private let queue: MTLCommandQueue
  private var pipe: MTLRenderPipelineState?
  private var texCache: CVMetalTextureCache?

  private(set) var shown = 0, skipped = 0, presentFails = 0
  // COVERAGE, because a percentile over a filtered subset is a claim about the
  // subset. The first A/B read p50 22.13 ms from 832 samples with vsync on and
  // p50 14.96 ms from only 206 with it off -- and a p50 computed over a quarter
  // as many samples may be reporting a different population, not a faster one.
  // These make the gap between "frames drawn" and "frames actually timed" visible
  // instead of leaving it to be inferred.
  private(set) var presentNoTime = 0, presentOutOfRange = 0
  /// enqueue -> actually on the display, straight from Metal.
  var present = Quantiles()
  private(set) var lastPresentMs: Double = 0
  private(set) var refreshMs: Double = 0
  let vsyncOff: Bool

  init?(vsyncOff: Bool) {
    self.vsyncOff = vsyncOff
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
    dev = d
    queue = q
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &texCache)
    guard buildPipeline() else { return nil }
  }

  private func buildPipeline() -> Bool {
    // Compiled at runtime so the package stays a plain SwiftPM executable with no
    // resource bundle to go missing on someone else's machine.
    //
    // BT.709, VIDEO RANGE, because that is what VideoToolbox is configured to
    // hand us (420YpCbCr8BiPlanarVideoRange). Getting the range wrong does not
    // fail, it just washes the picture out slightly -- the sort of defect that
    // survives every counter and only a pair of eyes catches.
    let src = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vmain(uint vid [[vertex_id]]) {
      // One full-screen triangle strip, no vertex buffer.
      float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
      VOut o;
      o.pos = float4(p[vid], 0, 1);
      o.uv = float2((p[vid].x + 1) * 0.5, 1.0 - (p[vid].y + 1) * 0.5);
      return o;
    }
    fragment float4 fmain(VOut in [[stage_in]],
                          texture2d<float> yTex [[texture(0)]],
                          texture2d<float> cTex [[texture(1)]]) {
      constexpr sampler s(filter::linear, address::clamp_to_edge);
      float y = yTex.sample(s, in.uv).r;
      float2 c = cTex.sample(s, in.uv).rg;
      y = (y - 16.0/255.0) * (255.0/219.0);
      float u = c.r - 0.5, v = c.g - 0.5;
      float3 rgb = float3(y + 1.5748 * v,
                          y - 0.1873 * u - 0.4681 * v,
                          y + 1.8556 * u);
      return float4(clamp(rgb, 0.0, 1.0), 1.0);
    }
    """
    do {
      let lib = try dev.makeLibrary(source: src, options: nil)
      let d = MTLRenderPipelineDescriptor()
      d.vertexFunction = lib.makeFunction(name: "vmain")
      d.fragmentFunction = lib.makeFunction(name: "fmain")
      d.colorAttachments[0].pixelFormat = .bgra8Unorm
      pipe = try dev.makeRenderPipelineState(descriptor: d)
      return true
    } catch {
      fputs("metal: pipeline failed: \(error)\n", stderr)
      return false
    }
  }

  func open(title: String, w: Int, h: Int) {
    let rect = NSRect(x: 0, y: 0, width: w, height: h)
    let window = NSWindow(contentRect: rect,
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = title
    let view = NSView(frame: rect)
    view.wantsLayer = true
    layer.device = dev
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = true
    layer.isOpaque = true
    // The whole point of this file.
    layer.displaySyncEnabled = !vsyncOff
    // A drawable count of 2 rather than the default 3: a third drawable is a
    // third frame of queue, and a queue is latency that cannot be recovered later.
    layer.maximumDrawableCount = 2
    layer.frame = view.bounds
    layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    view.layer = layer
    window.contentView = view
    window.center()
    window.makeKeyAndOrderFront(nil)
    win = window
    if let scr = window.screen ?? NSScreen.main {
      let hz = scr.maximumFramesPerSecond
      refreshMs = hz > 0 ? 1000.0 / Double(hz) : 0
    }
  }

  /// Draw one decoded frame. Returns immediately; the presented-time callback
  /// closes the measurement later.
  func show(_ pb: CVPixelBuffer, at enqueueHost: UInt64) {
    guard let pipe, let cache = texCache else { return }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    if layer.drawableSize.width != CGFloat(w) || layer.drawableSize.height != CGFloat(h) {
      layer.drawableSize = CGSize(width: w, height: h)
    }
    var yTexRef: CVMetalTexture?
    var cTexRef: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil,
      .r8Unorm, CVPixelBufferGetWidthOfPlane(pb, 0), CVPixelBufferGetHeightOfPlane(pb, 0), 0, &yTexRef)
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil,
      .rg8Unorm, CVPixelBufferGetWidthOfPlane(pb, 1), CVPixelBufferGetHeightOfPlane(pb, 1), 1, &cTexRef)
    guard let yr = yTexRef, let cr = cTexRef,
          let yTex = CVMetalTextureGetTexture(yr), let cTex = CVMetalTextureGetTexture(cr) else { return }

    // nextDrawable BLOCKS when every drawable is in flight, and blocking here
    // would stall the decode thread behind the display. A frame we cannot draw
    // now is a frame better dropped: the next one is already more current.
    guard let drawable = layer.nextDrawable() else { skipped += 1; return }
    guard let cmd = queue.makeCommandBuffer() else { presentFails += 1; return }
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = drawable.texture
    rp.colorAttachments[0].loadAction = .dontCare
    rp.colorAttachments[0].storeAction = .store
    guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { presentFails += 1; return }
    enc.setRenderPipelineState(pipe)
    enc.setFragmentTexture(yTex, index: 0)
    enc.setFragmentTexture(cTex, index: 1)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    enc.endEncoding()

    // THE MEASUREMENT. presentedTime is in seconds on the same mach timebase as
    // everything else here, so this is a real enqueue-to-glass number rather than
    // an inference from refresh rates.
    drawable.addPresentedHandler { [weak self] d in
      guard let self else { return }
      let t = d.presentedTime
      guard t > 0 else { self.presentNoTime += 1; return }
      let nowS = Double(Clock.ns(Clock.now())) / 1e9
      let ms = (t - (Double(Clock.ns(enqueueHost)) / 1e9)) * 1000.0
      // A presented time before the enqueue, or absurdly after it, is a bad
      // sample and not a fast display. Refuse it rather than let it set a record.
      if ms >= 0, ms < 500, nowS > 0 {
        self.lastPresentMs = ms
        self.present.add(ms)
      } else {
        self.presentOutOfRange += 1
      }
    }
    cmd.present(drawable)
    cmd.commit()
    shown += 1
  }

  // LOOK AT THE PICTURE. A YUV->RGB shader has at least four ways to be wrong
  // that no counter can see: the two chroma planes swapped, video range treated
  // as full, the V axis flipped, or the wrong colour matrix. Mean luma is blind
  // to every one of them -- an upside-down frame has exactly the same mean as an
  // upright one, which is the specific mistake this project has already shipped
  // once. So the rendered result is read back off the GPU and written as a PNG,
  // and then a person looks at it.
  func dumpRendered(_ pb: CVPixelBuffer, to path: String) -> String {
    guard let pipe, let cache = texCache else { return "no pipeline" }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                     width: w, height: h, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]
    guard let dst = dev.makeTexture(descriptor: td) else { return "no texture" }
    var yr: CVMetalTexture?, cr: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .r8Unorm,
      CVPixelBufferGetWidthOfPlane(pb, 0), CVPixelBufferGetHeightOfPlane(pb, 0), 0, &yr)
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .rg8Unorm,
      CVPixelBufferGetWidthOfPlane(pb, 1), CVPixelBufferGetHeightOfPlane(pb, 1), 1, &cr)
    guard let y = yr.flatMap(CVMetalTextureGetTexture), let c = cr.flatMap(CVMetalTextureGetTexture),
          let cmd = queue.makeCommandBuffer() else { return "no textures" }
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = dst
    rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    rp.colorAttachments[0].storeAction = .store
    guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return "no encoder" }
    enc.setRenderPipelineState(pipe)
    enc.setFragmentTexture(y, index: 0)
    enc.setFragmentTexture(c, index: 1)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    let bpr = w * 4
    var bytes = [UInt8](repeating: 0, count: bpr * h)
    bytes.withUnsafeMutableBytes { raw in
      dst.getBytes(raw.baseAddress!, bytesPerRow: bpr,
                   from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                    | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false,
                           intent: .defaultIntent) else { return "no cgimage" }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     "public.png" as CFString, 1, nil) else { return "no dest" }
    CGImageDestinationAddImage(dest, cg, nil)
    return CGImageDestinationFinalize(dest) ? "wrote \(w)x\(h) to \(path)" : "write failed"
  }

  var state: String {
    guard let w = win else { return "no window" }
    return w.occlusionState.contains(.visible) ? "visible" : "occluded"
  }
}
