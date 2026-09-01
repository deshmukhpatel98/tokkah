package com.tokkah.kin.net

import java.io.File
import java.util.Calendar

/**
 * Port of mac/Sources/tk/Faces.swift — what your people look like.
 *
 * The picture is taken FROM A CALL YOU WERE IN: your own record of a
 * conversation you attended, like a photo in your own camera roll. It never
 * crosses the wire (the wire already carried it, inward), it is never uploaded,
 * and it lives in the same 0700 directory as the identity key.
 *
 * One face per handle, overwritten on later calls, newest wins. Saved only when
 * the call knows WHO it is with — a word-room call with no handle saves
 * nothing, because a face filed under a room name would surface under whoever
 * uses that word next.
 */
class Faces(private val root: File) {
    private val dir get() = File(root, "faces")
    private fun file(handle: String) = File(dir, "$handle.jpg")

    /**
     * Cache with NEGATIVE entries: the list redraws on every recomposition, and
     * a row whose person has no picture must not cost a disk stat per frame.
     * [MISSING] is "looked, nothing there".
     */
    private val cache = HashMap<String, Any>()
    private val lock = Object()
    private object MISSING

    fun path(handle: String): File? = synchronized(lock) {
        cache[handle]?.let { return if (it === MISSING) null else it as File }
        val f = file(handle)
        val hit = if (f.isFile && f.length() > 0) f else null
        cache[handle] = hit ?: MISSING
        return hit
    }

    fun has(handle: String) = path(handle) != null

    /**
     * Save the centre square of a decoded frame as this person's face, 256 px —
     * big enough for the big calling card at any density, small enough (~10 KB)
     * that a lifetime of contacts costs less than one photo.
     *
     * Called off the media path: the crop and JPEG encode are milliseconds,
     * which is nothing at 1 Hz and an eternity in an audio block.
     */
    fun save(handle: String, bitmap: android.graphics.Bitmap) {
        if (!Regex("^[a-z][a-z0-9]{1,31}$").matches(handle)) return
        val w = bitmap.width
        val h = bitmap.height
        if (w < 64 || h < 64) return
        // The centre square: a talking head sits in the middle of a call frame.
        val side = minOf(w, h)
        val square = android.graphics.Bitmap.createBitmap(
            bitmap, (w - side) / 2, (h - side) / 2, side, side,
        )
        val small = android.graphics.Bitmap.createScaledBitmap(square, 256, 256, true)
        dir.mkdirs()
        dir.setReadable(false, false); dir.setReadable(true, true)
        dir.setWritable(false, false); dir.setWritable(true, true)
        dir.setExecutable(false, false); dir.setExecutable(true, true)
        val tmp = File(dir, "$handle.jpg.tmp")
        try {
            tmp.outputStream().use {
                small.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, it)
            }
            // Written whole, then moved: a half-written face is a broken row.
            if (tmp.renameTo(file(handle))) synchronized(lock) { cache.remove(handle) }
            else tmp.delete()
        } catch (e: Exception) {
            tmp.delete()
        }
    }
}

/**
 * Who can be reached, right now. The answer paints a dot and REORDERS NOTHING:
 * rows that shuffle under a finger are how a stray tap calls the wrong person,
 * so the order is fixed and presence only ever changes a colour.
 */
object Presence {
    fun fetch(handles: List<String>, base: String = Server.base): Map<String, Boolean> {
        val who = handles.filter { Regex("^[a-z][a-z0-9]{1,31}$").matches(it) }.take(12)
        if (who.isEmpty()) return emptyMap()
        val body = httpGet("$base/api/kin/presence?who=" + who.joinToString(","), 6000)
            ?: return emptyMap()
        val out = HashMap<String, Boolean>()
        for (m in Regex("\"([a-z][a-z0-9]{1,31})\"\\s*:\\s*\\{([^}]*)\\}").findAll(body)) {
            out[m.groupValues[1]] = m.groupValues[2].contains("\"here\":true") ||
                m.groupValues[2].contains("\"here\": true")
        }
        return out
    }
}

/**
 * "yesterday", not a timestamp. Buckets, not arithmetic precision: "3w" and
 * "25d" are the same fact to a person, and the coarser spelling never needs
 * updating while the screen sits open.
 */
object Relative {
    fun time(then: Double, now: Double = System.currentTimeMillis() / 1000.0): String {
        val s = now - then
        if (s < 0) return ""
        if (s < 90) return "just now"
        if (s < 3600) return "${(s / 60).toInt()}m ago"
        if (s < 86400 * 2) {
            val today = Calendar.getInstance()
            val that = Calendar.getInstance().apply { timeInMillis = (then * 1000).toLong() }
            val sameDay = today.get(Calendar.YEAR) == that.get(Calendar.YEAR) &&
                today.get(Calendar.DAY_OF_YEAR) == that.get(Calendar.DAY_OF_YEAR)
            return if (s < 86400 && sameDay) "today" else "yesterday"
        }
        if (s < 86400 * 7) return "${(s / 86400).toInt()}d ago"
        if (s < 86400 * 30) return "${(s / 86400 / 7).toInt()}w ago"
        return "${(s / 86400 / 30).toInt()}mo ago"
    }
}
