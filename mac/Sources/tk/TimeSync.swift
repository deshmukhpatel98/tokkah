import Foundation

// Two machines, two clocks, and a latency claim that spans both.
//
// Every mouth-to-ear and glass-to-glass number in this app is
// `my_receive_time - peer_capture_time`. On loopback that is one clock and the
// subtraction is exact. Between two machines it is two unrelated clocks --
// mach_absolute_time counts from boot -- so the difference is the real latency
// plus an arbitrary offset that can be hours. Which means the headline number
// for the call this app exists to make has, until now, been unmeasurable. Not
// inaccurate: unmeasurable.
//
// So: NTP's offset exchange, over the media socket that is already open.
//
//   t1  I send            (my clock)
//   t2  peer receives     (peer clock)
//   t3  peer replies      (peer clock)
//   t4  I receive         (my clock)
//
//   theta = ((t2 - t1) + (t3 - t4)) / 2      peer clock - my clock
//   delay =  (t4 - t1) - (t3 - t2)           round trip, minus peer's own turnaround
//
// theta is exact when the path is symmetric and wrong by half the asymmetry when
// it is not. Nothing in a two-machine setup can do better -- one-way delay is
// not observable without a third reference -- so the honest thing is to report
// the asymmetry assumption rather than hide it.
//
// THE SAMPLE WITH THE SMALLEST DELAY IS THE ONE TO TRUST. A queued packet adds
// delay in one direction only, which is exactly the asymmetry that corrupts
// theta, and queueing only ever ADDS. So the minimum-delay sample in the window
// is the least corrupted one available. Standard, and for a good reason.
//
// A WINDOW, and not a lifetime minimum. A lifetime min-RTT estimate is a
// peak-hold: it learns whatever the first quiet moment said and then defends it
// against every later truth, including a real route change. This project has
// been bitten by exactly that (startup poisons estimators). Sixteen samples at
// 1 Hz is about twenty seconds of memory -- long enough to find a quiet moment,
// short enough to forget a stale one.
let TMAGIC: UInt32 = 0x544B_0005
let TPKT = 4 + 4 + 8 + 8 + 8      // magic, kind, t1, t2, t3
// ── and eight bytes of "here is what YOUR packets did on arrival" ────────────
//
// Loss is a property of a DIRECTION, and only the far end can see it. Until now
// the redundancy controller read this machine's own receive counters and then
// turned on redundancy in this machine's TRANSMIT path -- so a machine whose
// downlink was lossy protected its uplink, which was fine. On a symmetric path
// that is accidentally correct, and the loopback rig is perfectly symmetric, so
// no test here could ever have shown it. It is the same shape as every other
// control-loop bug in this project: the loop was steering on the wrong signal
// and the instrument could not tell.
//
// So the probe that already runs both ways carries the report. Appended past
// TPKT rather than inserted, so a build that predates this reads its 32 bytes
// exactly as before and simply never reports.
let TPKTX = TPKT + 8              // + rxLost, rxRecovered (cumulative, UInt32)
// ── THE FAR END'S OWN STATE ─────────────────────────────────────────────────
//
// rxLost and rxRecovered say what the peer FAILED to get. They cannot say
// whether it played anything at all, and "I can hear nothing" is the single most
// common thing a person reports. A peer that is playing 1500 packets a second is
// having a different problem to one playing zero, and until this arm existed
// both looked identical from here.
//
// Appended, never re-ordered: a receiver checks `n >= TPKT`, then `n >= TPKTX`,
// then `n >= TPKTY`, so an older build's shorter packet still parses exactly as
// far as it understands. Same idiom as HPKTX.
//   +0  played   UInt32   packets rendered, cumulative
//   +4  muted    UInt8    1 if their microphone is muted
//   +5  qLevel   UInt8    their video quality rung
//   +6  status   UInt8    vocal bits (claim / backchannel / cam / pause / ringing)
//   +7  endProb  UInt8    turn-end prior, 0-255. 0 is what 0.92.0 writes.
let TPKTY = TPKTX + 8
// ── AND THE FAR END'S VIDEO LOSS, WHICH WAS NEVER ON THE WIRE AT ALL ────────
//
// `rxLost` above is AUDIO concealment, and for the whole life of this protocol it
// was the only receive-side number that crossed. The video quality controller ran
// on it -- so it was steering the picture by how the VOICE was arriving, and it
// was wrong in both directions at once. Measured, on a 2 Mbps ceiling with 3.4
// Mbps of video offered:
//
//     the far end's audio         lost 1 packet in thirty seconds (FEC repaired it)
//     the far end's video         a quarter of every second's fragments gone
//     what the controller saw     no harm at all, so the picture never retreated
//
// And in the other direction, from a real call's telemetry: a path losing voice
// packets for its own reasons made the controller stop the video and never bring
// it back, on a link that had no trouble carrying it.
//
// So the video's own loss travels now. Appended, never re-ordered, same rule as
// every block above: a build that predates this reads to TPKTY and simply never
// reports it, and `peerReportsVideoLoss` is how this end knows the difference
// between "no video loss" and "not told".
//   +0  vMissing  UInt32   video frames given up on, cumulative
//   +4  vFrags    UInt32   video fragments received, cumulative -- the denominator
let TPKTZ = TPKTY + 8

final class TimeSync {
  private struct S { let delayNs: Int64; let thetaNs: Int64 }
  private var win: [S] = []
  private let cap = 16
  private let lock = NSLock()

  private(set) var samples = 0

  /// Probes refused for carrying a timestamp no clock could have produced.

  private(set) var refused = 0
  private(set) var lastDelayNs: Int64 = 0

  /// peer clock - my clock, from the least-queued sample in the window.
  /// nil until there is enough evidence to say anything.
  var thetaNs: Int64? {
    lock.lock(); defer { lock.unlock() }
    guard win.count >= 3 else { return nil }
    return win.min(by: { $0.delayNs < $1.delayNs })!.thetaNs
  }

  /// Best round trip in the window, in ms. This is the network, measured on the
  /// media path itself rather than inferred from a control channel that may be
  /// queued differently (control plane rides its own resource).
  var bestRttMs: Double? {
    lock.lock(); defer { lock.unlock() }
    guard let m = win.min(by: { $0.delayNs < $1.delayNs }) else { return nil }
    return Double(m.delayNs) / 1e6
  }

  /// Spread of the delay samples: how much the path is moving. A large spread
  /// with a small minimum means a jittery path, and it is the reason theta is
  /// taken from the minimum rather than the mean.
  var rttSpreadMs: Double? {
    lock.lock(); defer { lock.unlock() }
    guard win.count >= 2 else { return nil }
    let lo = win.min(by: { $0.delayNs < $1.delayNs })!.delayNs
    let hi = win.max(by: { $0.delayNs < $1.delayNs })!.delayNs
    return Double(hi - lo) / 1e6
  }

  func note(t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64) {
    // ── FOUR NUMBERS, TWO OF WHICH THE OTHER END CHOSE ────────────────────────
    //
    // t1 and t3 (or t2, on a reply) arrive on the wire from a peer that holds a
    // valid key -- and a valid key is not a promise of a sane clock. A tick count
    // near 2^64 overflows `Clock.ns` (ticks * 125 / 3) and, once signed, the sums
    // below. Under -Ounchecked that wrapped silently into the estimator; under -O
    // it is a trap, and the hostile-peer fuzzer (tools/fuzz-check.sh) crashed the
    // app with one probe on its first run. A real mach_absolute_time is under
    // 2^50 for decades of uptime; anything at or past 2^56 is not a clock reading.
    // 2^56, not 2^62: in nanoseconds a tick count is x 125/3, and the SIGNED
    // sums below need every operand under 2^62 -- seeds 2 and 3 of the same
    // fuzzer found 2^62 ticks still overflowing at the addition.
    let sane: UInt64 = 1 << 56
    guard t1 < sane, t2 < sane, t3 < sane, t4 < sane else { refused += 1; return }
    // Signed throughout. These are four numbers from two unrelated epochs, and
    // an unsigned subtraction that wraps to 18 quintillion is how an estimator
    // learns a value it will never recover from.
    let a = Int64(bitPattern: Clock.ns(t2)) - Int64(bitPattern: Clock.ns(t1))
    let b = Int64(bitPattern: Clock.ns(t3)) - Int64(bitPattern: Clock.ns(t4))
    let theta = a / 2 + b / 2     // never a + b: each is under 2^62, their sum is not
    let delay = (Int64(bitPattern: Clock.ns(t4)) - Int64(bitPattern: Clock.ns(t1)))
              - (Int64(bitPattern: Clock.ns(t3)) - Int64(bitPattern: Clock.ns(t2)))
    // A negative round trip is not a slow path, it is a corrupt sample: the
    // peer's turnaround cannot exceed the round trip. Refuse it rather than let
    // it win the minimum and poison theta for the whole window.
    guard delay >= 0 else { return }
    // And an impossibly LONG one: nothing on this planet takes ten seconds to
    // come back, so a sample that says so is a peer's clock reading no clock
    // produced, and letting it win the window's maximum put the spread at
    // 7,835,771,615,854 ms on the hostile-peer rig.
    guard delay <= 10_000_000_000 else { refused += 1; return }
    lock.lock()
    win.append(S(delayNs: delay, thetaNs: theta))
    if win.count > cap { win.removeFirst() }
    samples += 1
    lastDelayNs = delay
    lock.unlock()
  }
}
