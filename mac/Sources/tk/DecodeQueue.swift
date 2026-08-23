import Foundation

// ── Get the video decoder off the thread that receives audio ─────────────────
//
// `vasm.onFrame = { data, host in vdec.decode(data, hostTime: host) }` ran the
// H.264 decode inline, on the same loop that pulls audio packets off the socket.
// So every completed video frame stopped audio from being received for as long as
// the decode took. Head-of-line blocking, and it cost real latency on every video
// call. Measured, rotated arms, 120 s each:
//
//   video on   m2e p50 12.00 / 11.55   jit 6   arrival p99 1.64 max 7.99  late 14
//   video off  m2e p50  9.89 /  9.98   jit 3   arrival p99 0.85 max 1.43  late 0
//
// And the cadence instrument attributed it exactly: the SENDER's emission gaps
// were identical in both arms (p99 0.67, max 1.50), so nothing was delaying
// capture -- audio was arriving late, and the jitter buffer was right to grow.
// The buffer was treating a symptom; this is the cause.
//
// PREALLOCATED SLOTS, no allocation on the receive thread. And when a frame does
// not fit or the queue is full it decodes INLINE rather than dropping: the worst
// case becomes exactly today's behaviour, never worse, so turning this on cannot
// lose a frame.
final class DecodeQueue {
  /// 128 KiB per slot. A 720p keyframe is tens of KiB; the theoretical maximum a
  /// fragmented frame could reach is far larger, which is what the inline
  /// fallback is for.
  private static let SLOT = 128 * 1024
  private let slots: Int
  private var bufs: [UnsafeMutablePointer<UInt8>] = []
  private var lens: [Int]
  private var hosts: [UInt64]
  private var head = 0, tail = 0, count = 0
  private let lock = NSLock()
  private let items = DispatchSemaphore(value: 0)
  private let decode: (UnsafePointer<UInt8>, Int, UInt64) -> Void

  /// Frames that took the inline path anyway, and why. Reported, because a queue
  /// that quietly falls back to the thing it was built to avoid is a queue that
  /// looks like it is working.
  nonisolated(unsafe) var inlineTooBig = 0
  nonisolated(unsafe) var inlineFull = 0
  nonisolated(unsafe) var queued = 0
  nonisolated(unsafe) var maxDepth = 0

  init(slots: Int = 6, decode: @escaping (UnsafePointer<UInt8>, Int, UInt64) -> Void) {
    self.slots = slots
    self.lens = [Int](repeating: 0, count: slots)
    self.hosts = [UInt64](repeating: 0, count: slots)
    self.decode = decode
    for _ in 0..<slots { bufs.append(.allocate(capacity: DecodeQueue.SLOT)) }
    Thread { [self] in
      // Above normal, below the audio threads. The picture should not wait behind
      // ordinary work, and it must never compete with the sound.
      Thread.current.threadPriority = 0.7
      while true {
        items.wait()
        lock.lock()
        let i = head
        let n = lens[i], h = hosts[i]
        head = (head + 1) % slots
        count -= 1
        lock.unlock()
        decode(bufs[i], n, h)
      }
    }.start()
  }

  /// Called from the receive thread. Copies and returns; the decode happens
  /// elsewhere. A copy of tens of kilobytes is nothing against a decode, and the
  /// assembler reuses its slot the moment this returns, so borrowing the pointer
  /// was never an option.
  func submit(_ p: UnsafePointer<UInt8>, _ n: Int, _ host: UInt64) {
    guard n <= DecodeQueue.SLOT else {
      inlineTooBig += 1
      decode(p, n, host)
      return
    }
    lock.lock()
    guard count < slots else {
      lock.unlock()
      // Full means the decoder is behind. Decoding here applies the backpressure
      // to the right place instead of throwing the frame away.
      inlineFull += 1
      decode(p, n, host)
      return
    }
    let i = tail
    lock.unlock()
    // Fill the slot BEFORE publishing it. Single producer, so `tail` cannot move
    // underneath this; publishing first would let the consumer read a slot that is
    // still being written.
    memcpy(bufs[i], p, n)
    lens[i] = n
    hosts[i] = host
    lock.lock()
    tail = (tail + 1) % slots
    count += 1
    if count > maxDepth { maxDepth = count }
    lock.unlock()
    queued += 1
    items.signal()
  }
}
