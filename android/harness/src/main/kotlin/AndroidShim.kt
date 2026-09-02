package android.util

/**
 * The harness compiles the APK's OWN `net/` sources — that is the whole point of
 * it, and it is why a bug found here is a bug in the shipped code rather than in
 * a copy of it. Those sources log, so the harness has to supply the logger.
 *
 * Deliberately not silent: the diagnostics the app writes on a live call are
 * exactly the ones worth having when the harness reproduces a failure, and a
 * shim that swallows them would make the JVM arm blinder than the phone.
 */
object Log {
    private fun out(level: String, tag: String, msg: String) =
        println("[$level/$tag] $msg")

    @JvmStatic fun v(tag: String, msg: String): Int { out("V", tag, msg); return 0 }
    @JvmStatic fun d(tag: String, msg: String): Int { out("D", tag, msg); return 0 }
    @JvmStatic fun i(tag: String, msg: String): Int { out("I", tag, msg); return 0 }
    @JvmStatic fun w(tag: String, msg: String): Int { out("W", tag, msg); return 0 }
    @JvmStatic fun e(tag: String, msg: String): Int { out("E", tag, msg); return 0 }
    @JvmStatic fun e(tag: String, msg: String, t: Throwable): Int {
        out("E", tag, "$msg — $t"); return 0
    }
}
