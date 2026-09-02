package android.graphics

import java.io.OutputStream

/**
 * The two Android classes `net/` touches that are not the network or the clock.
 *
 * These exist so the harness can compile the SHIPPED sources unchanged. They are
 * not implementations: nothing in the harness saves a face photo, and a shim
 * that quietly returned a blank bitmap would let a future harness "pass" a face
 * test it never actually ran. So they throw, loudly, if anything ever calls
 * them — a missing capability should look like a missing capability.
 */
class Bitmap private constructor() {
    val width: Int get() = unavailable()
    val height: Int get() = unavailable()

    fun compress(format: CompressFormat, quality: Int, out: OutputStream): Boolean = unavailable()

    enum class CompressFormat { JPEG, PNG, WEBP }

    companion object {
        @JvmStatic fun createBitmap(src: Bitmap, x: Int, y: Int, w: Int, h: Int): Bitmap =
            unavailable()

        @JvmStatic fun createScaledBitmap(src: Bitmap, w: Int, h: Int, filter: Boolean): Bitmap =
            unavailable()
    }
}

private fun unavailable(): Nothing =
    error("android.graphics.Bitmap is not available in the JVM harness")
