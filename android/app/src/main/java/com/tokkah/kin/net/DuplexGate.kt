package com.tokkah.kin.net

import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

// Port of Audio.DuplexGate from mac/Sources/tk/Audio.swift (2861-3405).
// Purely local: it turns this microphone down for one reason — it can hear the
// far end coming out of this machine's own speaker. Publishes a CUE, never a
// command. Every constant here is a TIME, never a per-block number.
class Gate {
    var on = true
    /// A full mute, by decision: -120 dB is one part in a million, and a number
    /// rather than a hard zero so the smoothing has something to converge to.
    /// The old -22 dB duck is a control arm on the Mac (`--gate-floor -22`).
    var floorDb = -120.0
    var closeMs = 4.0
    var margin = 2.8f
    var claimMs = 700.0
    var yieldDb = -9.0
    var yieldAfterMs = 450.0
    var yieldOn = true
    var floorDuckDb = -20.0
}

class DuplexGate {
    var cfg = Gate()

    enum class Vocal(val v: Int) { QUIET(0), BACKCHANNEL(1), CLAIM(2) }

    var vocal = Vocal.QUIET; private set

    private var nearEnv = 0f
    private var rawEnv = 0f
    private var floorLevel = 0.004f
    private var run = 0
    private var farEnv = 0f
    private var coupling = 0.5f
    private var farRun = 0
    private var vocalSamples = 0
    private var quietSamples = 0
    var gain = 1f; private set

    /**
     * How audible this end is right now, 0..1: dB above twice the noise floor,
     * 24 dB to full — `Audio.loud(_:over:)`, the number the speaking edge's
     * thickness breathes with.
     */
    val nearLoudNow: Float get() = loud(nearEnv, floorLevel)
    val farLoudNow: Float get() = loud(farEnv, floorLevel)
    private fun loud(env: Float, noise: Float): Float {
        val ref = maxOf(noise * 2, 0.0015f)
        if (env <= ref) return 0f
        val db = 20 * (ln(env / ref) / ln(10f))
        return minOf(1f, maxOf(0f, db / 24))
    }
    private var floorGain = 1f
    private var yieldGain = 1f

    var yielding = false
    var floorMuted = false
    var floorDucked = false
    var floorGranted = false
    /// What survived the canceller, 0..1. Measured, never a constant.
    var echoResidual = 1f
    /// The correlation estimator's veto and the camera's override of it.
    var corrVeto = false
    var mouthSays = false

    var closedFrames = 0; private set
    var openFrames = 0; private set
    var yieldSamples = 0; private set
    var vetoFrames = 0; private set
    var unvetoFrames = 0; private set
    var vetoArmedFrames = 0; private set
    var levelVoiceFrames = 0; private set
    var backchannels = 0; private set
    var claims = 0; private set
    var vocalWasBackchannel = false; private set
    var everClaimed = false; private set

    val quietMsNow: Double get() = quietSamples.toDouble() / Wire.SR * 1000
    val voicingNow: Boolean get() = vocalSamples > 0 && quietMsNow < 120
    val vocalMsNow: Double get() = vocalSamples.toDouble() / Wire.SR * 1000

    private var lastN = 0

    /** One rendered sample, for the far-end envelope (~35 ms release at 48 kHz). */
    fun noteFar(v: Float) {
        val a = abs(v)
        farEnv = if (a > farEnv) a else farEnv * 0.9994f
    }

    /** In-place on the capture block. [rawPeakIn] is the untouched mic peak, or -1. */
    fun process(x: FloatArray, n: Int, rawPeakIn: Float = -1f) {
        val dt = n.toDouble() / Wire.SR
        lastN = n
        var peak = 0f
        for (k in 0 until n) { val a = abs(x[k]); if (a > peak) peak = a }
        val envA = exp(-dt / 0.035).toFloat()
        nearEnv = if (peak > nearEnv) peak else nearEnv * envA
        val rawPk = if (rawPeakIn >= 0) rawPeakIn else peak
        rawEnv = if (rawPk > rawEnv) rawPk else rawEnv * envA

        val fallK = (1 - exp(-dt / 0.15)).toFloat()
        if (nearEnv < floorLevel) floorLevel += (nearEnv - floorLevel) * fallK
        val far = farEnv
        val farTalking = far > 0.004f
        farRun = if (farTalking) farRun + n else 0
        // Not at the onset: the echo is a room away and a buffer behind, and a
        // minimum tracker fed that moment latches "there is no echo here".
        if (farTalking && farRun > (Wire.SR * 0.08).toInt() && rawEnv > 0.0008f) {
            val r = min(max(rawEnv / max(far, 1e-6f), 0.002f), 4f)
            coupling = if (r < coupling) r else min(coupling * exp(0.03 * dt).toFloat(), 4f)
        }

        // The bar moves with what the speaker is emitting, on the EFFECTIVE
        // coupling — what the room returns times what survived the canceller.
        val effCoupling = coupling * max(0.02f, min(1f, echoResidual))
        val expected = effCoupling * far
        val effMargin = max(1.35f, cfg.margin - 1.5f * effCoupling)
        val aboveEcho = if (cfg.on) nearEnv > expected * effMargin else true
        val aboveRoom = nearEnv > max(floorLevel * 4.0f, 0.006f)
        // 4 ms of continuous voice, at any block size.
        val needed = max(2, Math.ceil(0.004 / dt).toInt())
        val veto = corrVeto && !mouthSays && aboveEcho && aboveRoom
        if (veto) vetoFrames += n
        if (corrVeto && mouthSays && aboveEcho && aboveRoom) unvetoFrames += n
        if (corrVeto) vetoArmedFrames += n
        if (aboveEcho && aboveRoom) levelVoiceFrames += n
        val voiced = aboveEcho && aboveRoom && !veto
        run = if (voiced) run + 1 else 0
        val confirmed = run >= needed
        if (nearEnv > floorLevel) {
            floorLevel += (nearEnv - floorLevel) * (1 - exp(-dt / (if (confirmed) 60.0 else 2.0))).toFloat()
        }

        // Wall clock, and silence must be CONSECUTIVE.
        if (confirmed && vocalSamples == 0) vocalSamples = 1
        if (vocalSamples > 0) vocalSamples += n
        if (confirmed) quietSamples = 0 else if (vocalSamples > 0) quietSamples += n
        val vocalMs = vocalSamples.toDouble() / Wire.SR * 1000
        val quietMs = quietSamples.toDouble() / Wire.SR * 1000
        if (vocalSamples > 0) promote(if (vocalMs >= cfg.claimMs) Vocal.CLAIM else Vocal.BACKCHANNEL)
        if (quietMs > 450) { vocalSamples = 0; quietSamples = 0; promote(Vocal.QUIET) }

        // The gate opens on VOICE, not on the verdict.
        val nearTalking = !farTalking || aboveEcho
        val want: Float = if (cfg.on && farTalking && !nearTalking && !floorGranted)
            10.0.pow(cfg.floorDb / 20).toFloat() else 1f

        val openStep = 0.02f
        val closeStep = (1.0 / (Wire.SR * max(0.5, cfg.closeMs) / 1000.0)).toFloat()
        val yWant: Float = if (cfg.yieldOn && yielding) 10.0.pow(cfg.yieldDb / 20).toFloat() else 1f
        val yStep = if (yWant > yieldGain) 0.00042f else 0.00026f
        val fWant: Float = if (floorMuted) 0f
            else if (floorDucked) 10.0.pow(cfg.floorDuckDb / 20).toFloat() else 1f
        for (k in 0 until n) {
            if (want < gain) gain = max(want, gain - closeStep) else gain += (want - gain) * openStep
            if (fWant < floorGain) floorGain = max(fWant, floorGain - closeStep)
            else floorGain += (fWant - floorGain) * openStep
            yieldGain += (yWant - yieldGain) * yStep
            x[k] *= gain * yieldGain * floorGain
        }
        if (yWant < 1) yieldSamples += n
        if (want < 1) closedFrames += n else openFrames += n
    }

    private fun promote(v: Vocal) {
        if (v == vocal) return
        // Only ever forward within one vocalisation.
        if (v.v < vocal.v && v != Vocal.QUIET) return
        if (v == Vocal.QUIET) {
            // Counted on the way OUT: a listening noise is one that stayed one.
            if (vocalWasBackchannel && !everClaimed) backchannels++
            vocalWasBackchannel = false; everClaimed = false
        }
        if (v == Vocal.BACKCHANNEL) vocalWasBackchannel = true
        if (v == Vocal.CLAIM) { claims++; everClaimed = true }
        vocal = v
    }

    /** The turn layer's tri-state, for Floor.noteFar / the status byte. */
    fun toFloorVoice(): Floor.Voice = when (vocal) {
        Vocal.QUIET -> Floor.Voice.QUIET
        Vocal.BACKCHANNEL -> Floor.Voice.BACKCHANNEL
        Vocal.CLAIM -> Floor.Voice.CLAIM
    }

    val innards: String
        get() = "n=%d going=%.0fms quiet=%.0fms near=%.4f floor=%.4f far=%.4f coup=%.2f run=%d vocal=%d"
            .format(lastN, vocalMsNow, quietMsNow, nearEnv, floorLevel, farEnv, coupling, run, vocal.v)
}
