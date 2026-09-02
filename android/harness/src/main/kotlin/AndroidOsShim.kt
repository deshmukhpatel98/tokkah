package android.os

/**
 * The device's own name, which the harness is not. It reports the JVM host
 * honestly rather than impersonating a phone: a beat from this rig should be
 * identifiable as coming from the rig.
 */
object Build {
    @JvmField val MANUFACTURER: String = "jvm-harness"
    @JvmField val MODEL: String = System.getProperty("os.name") ?: "jvm"
    object VERSION { @JvmField val RELEASE: String = System.getProperty("java.version") ?: "jvm" }
}

/** Thread priorities are a phone's concern; on the JVM they are a no-op. */
object Process {
    const val THREAD_PRIORITY_DISPLAY = -4
    const val THREAD_PRIORITY_URGENT_AUDIO = -19
    @JvmStatic fun setThreadPriority(p: Int) {}
}
