import Foundation

// ── WHAT THIS CALL COSTS THE BATTERY ─────────────────────────────────────────
//
// Asked for in these words: "without degrading any quality or adding any
// latency, the load on the CPU and the GPU should be minimal... so that this
// video call does not end up eating more battery."
//
// Nothing in this app measured that. Not one field, on any machine, ever -- so
// the honest answer to "is Kin heavy?" was a shrug, and the honest answer to
// "did that change help?" was a shrug with a profiler attached to one Mac in
// one room. `telemetry-must-self-diagnose`: a cost nobody reports is a cost
// nobody can reduce, and the machine that matters is somebody else's.
//
// ── A RATE, NOT A TOTAL ──────────────────────────────────────────────────────
//
// `getrusage` returns CPU consumed since the process began, which grows forever
// and says nothing about now. What a battery cares about is CPU seconds per
// wall second -- 0.15 means this process keeps about one seventh of one core
// busy -- so every sample is a DELTA against the previous one, and the first
// sample of a call is skipped rather than reported as a spike containing
// startup. `startup-poisons-estimators`.
//
// Both halves are kept apart on purpose. `sys` is time in the kernel, which for
// this app is overwhelmingly the audio device and the socket, and it moves for
// completely different reasons than `usr` -- a packet storm shows in one and a
// hot loop in the other. Rolled into one number they cannot be told apart.
enum Power {

  private static var lastUsr: Double = 0
  private static var lastSys: Double = 0
  private static var lastWall: Double = 0
  private static var primed = false

  struct Sample {
    /// CPU seconds per wall second. 1.0 is one core saturated.
    var cpu: Double = 0
    var usr: Double = 0
    var sys: Double = 0
    /// Peak resident bytes, which is a total and not a rate -- named so.
    var rssPeakMb: Double = 0
    var threads: Int = 0
    /// False until two samples exist. A single reading cannot be a rate, and
    /// reporting one as zero would be a real number for a thing not measured.
    var valid = false
  }

  private static func usage() -> (usr: Double, sys: Double, rssMb: Double) {
    var ru = rusage()
    guard getrusage(RUSAGE_SELF, &ru) == 0 else { return (0, 0, 0) }
    let u = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
    let s = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    // ru_maxrss is BYTES on Darwin and kilobytes on Linux. This app is Darwin
    // only, and writing the unit down is cheaper than someone re-deriving it.
    return (u, s, Double(ru.ru_maxrss) / 1_048_576.0)
  }

  /// Live thread count. Cheap, and it is the number that catches a leak of
  /// threads -- the failure mode where CPU looks fine and the machine does not.
  private static func threadCount() -> Int {
    var count = mach_msg_type_number_t(0)
    var list: thread_act_array_t?
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS,
          let l = list else { return 0 }
    // The array is vm_allocated for us; leaking it once a second would be an
    // instrument that costs more than the thing it measures.
    for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, l[i]) }
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: l)),
                  vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
    return Int(count)
  }

  /// Call once per beat. Returns the rate since the previous call.
  static func sample() -> Sample {
    let now = Date().timeIntervalSince1970
    let r = usage()
    var out = Sample()
    out.rssPeakMb = r.rssMb
    out.threads = threadCount()
    defer { lastUsr = r.usr; lastSys = r.sys; lastWall = now; primed = true }
    guard primed, now > lastWall else { return out }
    let dt = now - lastWall
    guard dt > 0.05 else { return out }
    out.usr = (r.usr - lastUsr) / dt
    out.sys = (r.sys - lastSys) / dt
    out.cpu = out.usr + out.sys
    out.valid = true
    return out
  }
}
