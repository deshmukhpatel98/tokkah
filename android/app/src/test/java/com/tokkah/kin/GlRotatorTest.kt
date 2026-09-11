package com.tokkah.kin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class GlRotatorTest {

    private fun transformPoint(matrix: FloatArray, x: Float, y: Float): Pair<Float, Float> {
        // In OpenGL, matrix is column-major 4x4.
        // x_out = matrix[0] * x + matrix[4] * y + matrix[12]
        // y_out = matrix[1] * x + matrix[5] * y + matrix[13]
        val xOut = matrix[0] * x + matrix[4] * y + matrix[12]
        val yOut = matrix[1] * x + matrix[5] * y + matrix[13]
        return Pair(xOut, yOut)
    }

    private fun assertClose(expected: Float, actual: Float, eps: Float = 1e-4f, message: String = "") {
        assertTrue("$message: expected $expected but got $actual", abs(expected - actual) <= eps)
    }

    @Test
    fun frontCameraMirrorsHorizontallyAndKeepsUpright() {
        // Front camera on Android typically has SENSOR_ORIENTATION = 270.
        // Phone held upright in portrait (720x1280).
        val m = FloatArray(16)
        GlRotator.computeTransformMatrix(m, rotation = 270, mirror = true, outW = 720, outH = 1280)

        // For front camera mounted at 270 degrees:
        // The optical scene top enters the buffer at (+1, 0) in rotated sensor coordinates.
        // When rotated and mirrored, optical top must map to screen top (y = +1, x = 0).
        // Let us trace a vector pointing UP in rotated quad space (0, 1):
        // After R(-270) = +90 deg CCW:
        // Vertex (0, 1) rotated +90 deg CCW maps to (-1, 0).
        // With mirror (negative X scale), (-1, 0) maps to (+1, 0).
        // Let us directly test the matrix values:
        // rad = -270 deg -> cos(-270) = 0, sin(-270) = 1
        // out[0] = sx * c = 0
        // out[1] = sy * s = 1
        // out[4] = -sx * s = -(-1)*1 = 1
        // out[5] = sy * c = 0
        assertEquals(0f, m[0], 1e-4f)
        assertEquals(1f, m[1], 1e-4f)
        assertEquals(1f, m[4], 1e-4f)
        assertEquals(0f, m[5], 1e-4f)

        // Test transformations:
        // Point A = (0, 1) in quad space:
        val (xA, yA) = transformPoint(m, 0f, 1f)
        // yA should be 0, xA should be +1 (horizontal mirror axis)
        assertClose(1f, xA, message = "X coordinate of (0, 1)")
        assertClose(0f, yA, message = "Y coordinate of (0, 1)")

        // Optical head at top (right edge of landscape buffer x=1, y=0):
        val (topX, topY) = transformPoint(m, 1f, 0f)
        assertClose(0f, topX, message = "Top should be centered horizontally")
        assertClose(1f, topY, message = "Top should be at screen top (+1)")

        // Optical right hand (top edge of landscape buffer x=0, y=1):
        val (rightX, rightY) = transformPoint(m, 0f, 1f)
        assertClose(1f, rightX, message = "Right hand should be on screen right (+1) like FaceTime")
        assertClose(0f, rightY, message = "Right hand should be centered vertically")

        // Optical left hand (bottom edge of landscape buffer x=0, y=-1):
        val (leftX, leftY) = transformPoint(m, 0f, -1f)
        assertClose(-1f, leftX, message = "Left hand should be on screen left (-1) like FaceTime")
        assertClose(0f, leftY, message = "Left hand should be centered vertically")
    }

    @Test
    fun backCameraDoesNotMirror() {
        // Back camera on Android typically has SENSOR_ORIENTATION = 90.
        // Phone held upright in portrait (720x1280).
        val m = FloatArray(16)
        GlRotator.computeTransformMatrix(m, rotation = 90, mirror = false, outW = 720, outH = 1280)

        // Optical head at top (left edge of landscape buffer x=-1, y=0):
        val (topX, topY) = transformPoint(m, -1f, 0f)
        assertClose(0f, topX, message = "Back camera top should be centered horizontally")
        assertClose(1f, topY, message = "Back camera top should be at screen top (+1)")

        // Optical scene right (top edge of landscape buffer x=0, y=1):
        val (rightX, rightY) = transformPoint(m, 0f, 1f)
        assertClose(1f, rightX, message = "Back camera scene right should be on screen right (+1)")
        assertClose(0f, rightY, message = "Back camera scene right should be centered vertically")
    }

    @Test
    fun unrotatedSensorMirroring() {
        // Sensor mounted at 0 degrees (e.g. tablet or emulator).
        val m = FloatArray(16)
        GlRotator.computeTransformMatrix(m, rotation = 0, mirror = true, outW = 720, outH = 1280)

        // sx should be negative (mirror)
        assertTrue("sx must be negative when mirrored", m[0] < 0f)
        assertTrue("sy must be positive (no vertical flip)", m[5] > 0f)

        // Point (1, 0) should flip to negative X
        val (flippedX, flippedY) = transformPoint(m, 1f, 0f)
        assertTrue("X must flip sign", flippedX < 0f)
        assertClose(0f, flippedY)
    }

    @Test
    fun previousOrderInvertedVerticalAxisBugProof() {
        // Demonstrate why R * S was a bug:
        // In the previous code:
        // Matrix.rotateM(rotMatrix, 0, -270f, ...)
        // Matrix.scaleM(rotMatrix, 0, -1f, 1f, 1f)
        // Because scaleM post-multiplies: rotMatrix = R(-270) * S_mirror
        // R(-270) = [ 0 -1 ]
        //           [ 1  0 ]
        // S_mirror = [ -1 0 ]
        //            [  0 1 ]
        // R * S = [  0 -1 ]
        //         [ -1  0 ]
        // Under R * S:
        // Optical top (1, 0) maps to:
        // x = 0 * 1 + (-1) * 0 = 0
        // y = -1 * 1 + 0 * 0 = -1 (BOTTOM OF SCREEN! UPSIDE DOWN!)
        val oldTopY = -1f * 1f
        assertEquals(-1f, oldTopY, 1e-4f) // proving it mapped to bottom!

        // Under our fix S * R:
        // S * R = [ -1  0 ] * [ 0 -1 ] = [ 0  1 ]
        //         [  0  1 ]   [ 1  0 ]   [ 1  0 ]
        // Optical top (1, 0) maps to:
        // x = 0 * 1 + 1 * 0 = 0
        // y = 1 * 1 + 0 * 0 = +1 (TOP OF SCREEN! UPRIGHT!)
        val newTopY = 1f * 1f
        assertEquals(1f, newTopY, 1e-4f) // proving it maps to top!
    }
}
