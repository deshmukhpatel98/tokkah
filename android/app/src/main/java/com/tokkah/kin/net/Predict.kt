package com.tokkah.kin.net

import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Port of mac/Sources/tk/Predict.swift — a PRIOR, never a trigger.
 *
 * The floor is reactive by construction: it waits for silence to prove a turn
 * ended. This produces a number saying how likely the current turn is to be
 * ending, so the release can begin before the proof arrives. It can only ever
 * let a holder who is already finishing LET GO SOONER; it cannot grant a floor,
 * cannot mute anybody, and cannot cut a sentence short.
 *
 * The Mac adds an on-device language model on top of these features. Android
 * has no FoundationModels, so the model term is simply absent — which the Mac's
 * own combiner already handles, because the model arrives late, fails, or is
 * ineligible there too. That path is the one this runs on, not a new one.
 */
class Predict {
    companion object {
        /** Words a clause hangs on: after one of these, more is coming. */
        val HANGING = setOf(
            "and", "or", "but", "because", "cause", "cos", "although", "whilst",
            "if", "unless", "until", "till", "whether", "than",
            "the", "a", "an", "my", "your", "his", "her", "its", "our", "their",
            "another", "such",
            "of", "to", "in", "on", "at", "for", "with", "from", "by", "about", "into",
            "onto", "under", "between", "through", "during", "against",
            "without", "within", "upon", "toward", "towards",
            "is", "are", "was", "were", "am", "be", "been", "being", "has", "have",
            "had", "does", "did", "will", "would", "shall", "should", "may", "must",
            "gonna", "wanna", "gotta",
            "i", "we", "they", "he", "she",
            "very", "really", "quite",
        )
        val FILLER = setOf(
            "um", "uh", "erm", "er", "ah", "hmm", "mm", "eh", "like", "well", "okay",
            "ok", "y'know", "yknow",
        )

        /**
         * What the words say. Punctuation is the strong signal and the word
         * list is the weak one, and that ordering is deliberate: the transcript
         * runs most of a second behind the sound, so the "last word" at the
         * moment somebody stops is a word from the MIDDLE of the clause, and
         * the list is being asked about the wrong token.
         */
        fun syntax(raw: String): Double {
            val t = raw.trim()
            if (t.isEmpty()) return 0.0
            val words = t.split(' ', '\n', '\t').filter { it.isNotEmpty() }
            val lastRaw = words.lastOrNull() ?: return 0.0
            val bulk = min(1.0, words.size / 5.0)
            when (lastRaw.last()) {
                '.', '?', '!' -> return 0.90
                ',', ';', ':' -> return 0.15
            }
            val last = lastRaw.lowercase().trim { !it.isLetterOrDigit() && it != '\'' }
            if (last in FILLER) return 0.25
            if (last in HANGING) return 0.30
            return 0.32 + 0.06 * bulk
        }

        /**
         * The features, combined. A geometric mean of syntax and the falling
         * loudness, weighted toward the words, then bent by how long this
         * vocalisation has run and how long it has been quiet.
         */
        fun combine(syntax: Double, fall: Double, vocalMs: Double, quietMs: Double, model: Double): Double {
            val f = 0.45 + 0.55 * min(1.0, max(0.0, fall / 8.0))
            var p = max(syntax, 1e-6).pow(0.72) * f.pow(0.28)
            // Somebody who has barely started is not finishing.
            if (vocalMs < 500) p *= max(0.2, vocalMs / 500)
            p += 0.10 * min(1.0, quietMs / 450)
            if (model >= 0) {
                if (model < 0.5) p *= (0.25 + 1.5 * model)          // veto
                else p *= (1.0 + 0.2 * (model - 0.5) * 2)           // agree
            }
            return min(1.0, max(0.0, p))
        }
    }

    /** 25 ms of loudness per slot — the same cadence the Mac samples at. */
    private val ring = FloatArray(160)
    private var ringW = 0
    private var ringN = 0

    var lastSyntax = 0.0; private set
    var lastFall = 0.0; private set
    var lastQuietMs = 0.0; private set
    var lastVocalMs = 0.0; private set

    private var text = ""
    private var textMs = 0.0

    fun noteLoud(rms: Float) {
        ring[ringW % ring.size] = rms
        ringW++
        if (ringN < ring.size) ringN++
    }

    fun noteText(t: String, atMs: Double) { text = t; textMs = atMs }

    private fun at(back: Int) = ring[((ringW - 1 - back) % ring.size + ring.size) % ring.size]

    /** The bar: a fiftieth of the loudest thing in memory, or nothing at all. */
    private fun bar(): Float {
        var loudest = 0f
        for (k in 0 until ringN) loudest = max(loudest, at(k))
        return if (loudest > 1e-4f) loudest / 50 else Float.MAX_VALUE
    }

    /**
     * How far the voice has fallen: the body's loudness minus the last of it.
     * The trailing QUIET is skipped and the comparison is speech against
     * speech — otherwise the ratio saturates and every pause reads as 40 dB of
     * "falling", which is answering a different question than the one asked.
     */
    fun fallDb(recent: Int = 10, body: Int = 10): Double {
        if (ringN < 8) return 0.0
        val b = bar()
        var tail = 0.0; var peak = 0.0; var seen = 0
        for (k in 0 until ringN) {
            val v = at(k)
            if (v < b) continue
            val db = 20 * ln(max(v, 1e-7f).toDouble()) / ln(10.0)
            seen++
            if (seen <= recent) tail += db else if (seen <= recent + body) peak += db
            if (seen >= recent + body) break
        }
        if (seen < recent + body) return 0.0
        return peak / body - tail / recent
    }

    fun quietMs(): Double {
        val b = bar()
        var k = 0
        while (k < ringN && at(k) < b) k++
        return k * 25.0
    }

    fun vocalMs(): Double {
        val b = bar()
        var n = 0
        for (k in 0 until ringN) if (at(k) >= b) n++
        return n * 25.0
    }

    /** The prior, 0..1. Stale text is ignored rather than trusted. */
    fun probability(nowMs: Double, staleMs: Double = 2500.0): Double {
        val q = quietMs()
        val v = vocalMs()
        val age = nowMs - textMs
        // 0.4 when there are no words: neutral, not "ending" and not "running".
        val syn = if (age <= staleMs && text.isNotEmpty()) syntax(text) else 0.4
        val fall = fallDb()
        val p = combine(syn, fall, v, q, model = -1.0)
        lastSyntax = syn; lastFall = fall; lastQuietMs = q; lastVocalMs = v
        return p
    }
}
