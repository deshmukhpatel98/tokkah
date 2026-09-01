package com.tokkah.kin.harness

import com.tokkah.kin.net.CallSession
import com.tokkah.kin.net.Floor
import com.tokkah.kin.net.Wire
import java.io.File
import kotlin.math.abs
import kotlin.math.sqrt

// The Phase-2 gate: the APK's own CallSession, audio and all, driven by real
// recorded speech at real-time pace against the shipped Mac app on the live
// server. Everything here except the device driver is the code that ships.
object CallMain {
    /** 48 kHz mono float from a 16-bit PCM WAV, which is what the rig media is. */
    private fun readWav(path: String): FloatArray {
        val b = File(path).readBytes()
        var pos = 12
        var dataOff = -1
        var dataLen = 0
        var channels = 1
        var rate = 48000
        var bits = 16
        while (pos + 8 <= b.size) {
            val id = String(b, pos, 4, Charsets.US_ASCII)
            val len = Wire.u32(b, pos + 4)
            if (id == "fmt ") {
                channels = Wire.u16(b, pos + 10)
                rate = Wire.u32(b, pos + 12)
                bits = Wire.u16(b, pos + 22)
            } else if (id == "data") { dataOff = pos + 8; dataLen = len; break }
            pos += 8 + len + (len and 1)
        }
        require(dataOff > 0 && bits == 16) { "need 16-bit PCM wav, got bits=$bits" }
        require(rate == 48000) { "need 48 kHz, got $rate" }
        val frames = dataLen / 2 / channels
        val out = FloatArray(frames)
        for (i in 0 until frames) {
            val o = dataOff + i * 2 * channels
            val v = ((b[o].toInt() and 0xff) or (b[o + 1].toInt() shl 8)).toShort()
            out[i] = v / 32767.0f
        }
        return out
    }

    @JvmStatic
    fun main(args: Array<String>) {
        val room = args.getOrNull(0) ?: error("usage: callharness <room> [seconds] [wav]")
        val seconds = args.getOrNull(1)?.toIntOrNull() ?: 25
        val wavPath = args.getOrNull(2)

        val speech = wavPath?.let { readWav(it) }
        val s = CallSession(room)
        s.onState = { println("harness: state -> $it") }
        s.start()

        // A device that behaves like Android's fast path: 192-frame bursts
        // (4 ms) both ways, paced by the wall clock.
        val burst = 192
        s.playout.devBuf = burst
        s.speakers = true
        val cap = FloatArray(burst)
        val ren = FloatArray(burst)

        var farEnergy = 0.0
        var farFrames = 0
        var farPeak = 0f
        var speechPos = 0
        var minePkts = 0
        var theirsBlocks = 0
        var mineBlocks = 0
        var idleBlocks = 0

        val t0 = System.nanoTime()
        var block = 0L
        while (System.nanoTime() - t0 < seconds * 1_000_000_000L) {
            // Capture: real speech, looped.
            if (speech != null) {
                for (i in 0 until burst) {
                    cap[i] = speech[(speechPos + i) % speech.size]
                }
                speechPos = (speechPos + burst) % speech.size
            } else java.util.Arrays.fill(cap, 0f)
            val before = s.ring.playedS
            s.captureBlock(cap, burst)
            if (s.crypto.established && !s.selfMuted) minePkts += burst / Wire.FPP

            // Render.
            s.renderBlock(ren, burst)
            for (v in ren) { farEnergy += v.toDouble() * v; if (abs(v) > farPeak) farPeak = abs(v) }
            farFrames += burst
            if (s.ring.playedS > before) { /* real audio played */ }

            when (s.floor.state) {
                Floor.State.MINE -> mineBlocks++
                Floor.State.THEIRS -> theirsBlocks++
                else -> idleBlocks++
            }
            block++
            // Pace to real time.
            val due = t0 + block * burst * 1_000_000_000L / Wire.SR
            val sleep = due - System.nanoTime()
            if (sleep > 0) Thread.sleep(sleep / 1_000_000, (sleep % 1_000_000).toInt())
        }
        s.stop()

        val r = s.ring
        val farRms = if (farFrames > 0) sqrt(farEnergy / farFrames) else 0.0
        println("=== P2 GATE RESULT ===")
        println("established: ${s.crypto.established}  safety: ${s.safetyCode}")
        println("rtt: ${s.tsync.bestRttMs?.let { "%.2f ms".format(it) }}  samples=${s.tsync.samples}")
        println("audio in:  accepted=${r.accepted} played=${r.played} conceal=${r.concealed} " +
                "(lost=${r.concealLost} starved=${r.concealStarved}) dup=${r.dup} late=${r.lateArrivals}")
        println("cursor:    jumps=${r.jumps} snapsBehind=${r.snapsBehind} snapsPast=${r.snapsPast} " +
                "err=%.2f ms rate=%.5f".format(r.errMs, if (r.rateN > 0) r.rateSum / r.rateN else 1.0))
        println("audio out: packets=$minePkts  peerPlayed=${s.peerPlayed}")
        println("far audio: rms=%.5f peak=%.5f".format(farRms, farPeak))
        println("floor:     mine=$mineBlocks theirs=$theirsBlocks idle=$idleBlocks")
        println("gate:      claims=${s.gate.claims} backchannels=${s.gate.backchannels} " +
                "vocal=${s.gate.vocal}")
        println("crypto:    sealed=${s.crypto.sealed} opened=${s.crypto.opened} " +
                "fails=${s.crypto.openFails} plaintextRx=${s.crypto.plaintextRx}")

        val concealRatio = if (r.played > 0) r.concealed.toDouble() / (r.played + r.concealed) else 1.0
        val pass = s.crypto.established &&
            r.accepted > 100 && r.played > 1000 &&
            concealRatio < 0.05 &&
            s.tsync.samples >= 3 &&
            s.peerPlayed > 100 &&              // they played OUR audio: the send half works
            r.jumps == 0
        println("concealRatio=%.4f".format(concealRatio))
        println(if (pass) "PASS" else "FAIL")
        kotlin.system.exitProcess(if (pass) 0 else 1)
    }
}
