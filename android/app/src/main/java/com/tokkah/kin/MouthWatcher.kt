package com.tokkah.kin

import android.graphics.Bitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceContour
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.tokkah.kin.net.Mouth
import com.tokkah.kin.net.MouthConfig

/**
 * The camera half of turn-taking, from mac/Sources/tk/Mouth.swift.
 *
 * A microphone carrying both a person and a loud echo of the far end
 * CORRELATES with the far end, and no threshold separates them. A camera does:
 * if a face is visible and its mouth is doing what speech does, the sound
 * reaching this microphone is not only the loudspeaker, whatever the
 * correlation says.
 *
 * It can only ever WITHDRAW the echo veto. It cannot mute anybody, cannot grant
 * a floor, and when it is blind — no face, no camera, a dark room — it says
 * nothing at all and the veto stands exactly as it did without it.
 *
 * Runs at 12 Hz off the media path, and DROPS rather than queues: a detector
 * that falls behind and then reports about a face from a second ago is worse
 * than one that skipped the frame.
 */
class MouthWatcher {
    val mouth = Mouth()

    private val detector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            // Contours, because the aperture is measured on the lip cloud's own
            // axes — a bounding box cannot give that.
            .setContourMode(FaceDetectorOptions.CONTOUR_MODE_ALL)
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_NONE)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_NONE)
            .build(),
    )

    @Volatile private var inFlight = false
    private var lastLookMs = 0.0
    var dropped = 0; private set
    var looks = 0; private set
    var lastError: String? = null; private set

    var onVisualState: ((known: Boolean, voice: Boolean) -> Unit)? = null

    /** One camera frame. Cheap to call at any rate: it decides when to look. */
    fun note(bitmap: Bitmap, rotationDeg: Int = 0) {
        if (!mouth.on) return
        val now = System.nanoTime() / 1e6
        if (now - lastLookMs < 1000.0 / MouthConfig.HZ) return
        if (inFlight) { dropped++; return }
        lastLookMs = now
        inFlight = true
        looks++
        val image = InputImage.fromBitmap(bitmap, rotationDeg)
        detector.process(image)
            .addOnSuccessListener { faces ->
                val f = faces.maxByOrNull { it.boundingBox.width() * it.boundingBox.height() }
                val lips = f?.getContour(FaceContour.UPPER_LIP_BOTTOM)?.points.orEmpty() +
                    f?.getContour(FaceContour.LOWER_LIP_TOP)?.points.orEmpty()
                if (lips.size >= 4) {
                    mouth.note(lips.map { it.x to it.y }, now)
                } else {
                    // Blind, and it says so: a face it cannot resolve is not a
                    // face at rest.
                    mouth.noFace()
                }
                onVisualState?.invoke(mouth.visualKnown, mouth.visualVoice)
                inFlight = false
            }
            .addOnFailureListener { e ->
                lastError = e.message
                mouth.noFace()
                onVisualState?.invoke(mouth.visualKnown, mouth.visualVoice)
                inFlight = false
            }
    }

    /** One camera frame directly from an ImageReader, without bitmap allocations. */
    fun note(image: android.media.Image, rotationDeg: Int = 0) {
        if (!mouth.on) {
            image.close()
            return
        }
        val now = System.nanoTime() / 1e6
        if (now - lastLookMs < 1000.0 / MouthConfig.HZ) {
            image.close()
            return
        }
        if (inFlight) {
            dropped++
            image.close()
            return
        }
        lastLookMs = now
        inFlight = true
        looks++
        val inputImage = try {
            InputImage.fromMediaImage(image, rotationDeg)
        } catch (e: Exception) {
            inFlight = false
            image.close()
            return
        }
        detector.process(inputImage)
            .addOnSuccessListener { faces ->
                val f = faces.maxByOrNull { it.boundingBox.width() * it.boundingBox.height() }
                val lips = f?.getContour(FaceContour.UPPER_LIP_BOTTOM)?.points.orEmpty() +
                    f?.getContour(FaceContour.LOWER_LIP_TOP)?.points.orEmpty()
                if (lips.size >= 4) {
                    mouth.note(lips.map { it.x to it.y }, now)
                } else {
                    mouth.noFace()
                }
                onVisualState?.invoke(mouth.visualKnown, mouth.visualVoice)
                inFlight = false
            }
            .addOnFailureListener { e ->
                lastError = e.message
                mouth.noFace()
                onVisualState?.invoke(mouth.visualKnown, mouth.visualVoice)
                inFlight = false
            }
            .addOnCompleteListener {
                try { image.close() } catch (_: Exception) {}
            }
    }

    fun close() {
        runCatching { detector.close() }
    }
}
