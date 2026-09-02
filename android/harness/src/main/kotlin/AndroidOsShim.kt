package android.os

/**
 * The device's own name, which the harness is not. It reports the JVM host
 * honestly rather than impersonating a phone: a beat from this rig should be
 * identifiable as coming from the rig.
 */
object Build {
    @JvmField val MANUFACTURER: String = "jvm-harness"
    @JvmField val MODEL: String = System.getProperty("os.name") ?: "jvm"
}
