package com.tokkah.kin

import com.tokkah.kin.net.Predict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Differential test against the SHIPPED Predict.syntax and Predict.combine,
 * extracted from Predict.swift at generation time. 2,413 rows, including the
 * model term the Mac has and Android does not — so if a model ever arrives
 * here, the combiner it plugs into is already the Mac's.
 */
class PredictTest {
    private fun rows() =
        javaClass.getResourceAsStream("/vectors/predict.txt")!!.reader().readLines()
            .filter { it.isNotBlank() }

    @Test
    fun syntaxMatchesTheSwiftOriginal() {
        var n = 0
        for (r in rows()) {
            val p = r.split("|")
            if (p[0] != "syntax") continue
            val text = p[1]
            val want = p[2].toDouble()
            assertEquals("syntax(\"$text\")", want, Predict.syntax(text), 1e-9)
            n++
        }
        assertTrue("checked $n syntax rows", n >= 12)
    }

    @Test
    fun combineMatchesTheSwiftOriginal() {
        var n = 0
        for (r in rows()) {
            val p = r.split("|")
            if (p[0] != "combine") continue
            val got = Predict.combine(
                syntax = p[1].toDouble(), fall = p[2].toDouble(),
                vocalMs = p[3].toDouble(), quietMs = p[4].toDouble(),
                model = p[5].toDouble(),
            )
            assertEquals(r, p[6].toDouble(), got, 1e-9)
            n++
        }
        assertTrue("checked $n combine rows", n >= 2000)
    }

    @Test
    fun aPriorIsNeverATrigger() {
        // Whatever the features say, the number stays in range: the floor
        // multiplies by it and a value outside 0..1 would be a grant.
        val p = Predict()
        for (i in 0 until 400) p.noteLoud(if (i % 5 == 0) 0.3f else 0.001f)
        val v = p.probability(1000.0)
        assertTrue("prior $v", v in 0.0..1.0)
    }

    @Test
    fun barelyStartedIsNotFinishing() {
        // The rule that stops a prior firing on somebody's first syllable.
        val short = Predict.combine(0.9, 8.0, vocalMs = 100.0, quietMs = 0.0, model = -1.0)
        val long = Predict.combine(0.9, 8.0, vocalMs = 1500.0, quietMs = 0.0, model = -1.0)
        assertTrue("$short should be well under $long", short < long * 0.5)
    }

    @Test
    fun noWordsIsNeutralRatherThanEnding() {
        val p = Predict()
        for (i in 0 until 200) p.noteLoud(0.2f)
        // No text at all: the syntax term must be the neutral 0.4, not 0 and
        // not 0.9 — an absent signal is not evidence in either direction.
        p.probability(1000.0)
        assertEquals(0.4, p.lastSyntax, 1e-9)
    }
}
