package com.tokkah.kin.net

// Port of mac/Sources/tk/Floor.swift — the turn-taking state machine. Pure
// scalars in and out, no samples. Transcribed 1:1 from Kin 0.111.0 (the strict
// floor, 0.95.0 rules); the numbered comments live in the Swift original.
class Floor {
    enum class State(val v: Int) { IDLE(0), MINE(1), THEIRS(2) }
    enum class Voice(val v: Int) { QUIET(0), BACKCHANNEL(1), CLAIM(2) }

    class Cfg {
        var staleMs = 1000.0
        var playoutTailMs = 150.0
        var releaseMs = 450.0
        var contendedReleaseMs = 120.0
        var playoutQuietMs = 60.0
        var deadlockMs = 450.0
        var maxHeldDownMs = 1500.0
        var predictP = 0.7
        var playoutLagMs = 60.0
        var on = true
        var strict = true
        var strictDeadlockMs = 180.0
        var onsetGraceMs = 400.0
        var visualDeadlockMs = 80.0
        var predictCooldownMs = 250.0
        var idleTakesAnyVoice = true
        var headphoneDuplex = true
        var speakerDuplex = false
        var speakerDuplexPath = 0.05f
    }

    var cfg = Cfg()

    var state = State.IDLE; private set
    var farAgeMs = 1e9; private set
    var playoutTail = 0.0; private set
    private var playoutSilentMs = 0.0
    private var playoutHeard = false
    private var playoutLiveNow = false
    var predictedReleases = 0; private set
    var predictedSavedMs = 0.0; private set
    var farPredictedReleases = 0; private set
    var farPredictedSavedMs = 0.0; private set
    var farEndProbPeak = 0.0; private set
    var echoGuardBlocks = 0; private set
    var guardableBlocks = 0; private set
    var duplexBlocks = 0; private set
    var aecDuplexBlocks = 0; private set
    var askedBlocks = 0; private set

    private var farVoice = Voice.QUIET
    private var farQuietMs = 0.0
    private var farTransitMs = 0.0
    private var farClaimMs = 0.0
    private var nearClaimMs = 0.0
    private var holderQuietMs = 0.0
    private var heldDownMs = 0.0
    private var endProb = 0.0
    private var farEndProb = 0.0
    private var farPredArmed = false
    private var sincePredictMs = 1e9
    private var nearVoiceMs = 0.0
    private var farVoiceMs = 0.0
    var graceBlocks = 0; private set
    var graceOnsets = 0; private set
    var fastTakes = 0; private set
    private var inGrace = false
    private var farVoicing = false
    private var farVoicingKnown = false
    private var farSilentMs = 0.0
    private var farWrapping = false
    private var playoutHold = 0.0
    private var wasState = State.IDLE

    var yieldsOnTie = false
    var speakers = true
    var aecErleDb = 0.0
    var aecEchoPath = 1f
    var nearVisualVoice = false
    var visualTakes = 0; private set
    var farSeenTalking: Boolean? = null
    var seenReleases = 0; private set

    class Decision(
        val mayTransmit: Boolean,
        val duckOnly: Boolean,
        val playoutOpen: Boolean,
        val fallback: Boolean,
        val state: State,
    )

    /** One step. [dt] in seconds, [near] from this end's own classifier. */
    fun step(dt: Double, near: Voice): Decision {
        val ms = dt * 1000
        askedBlocks++
        farAgeMs += ms
        playoutHold = maxOf(0.0, playoutHold - ms)
        playoutTail = maxOf(0.0, playoutTail - ms)

        nearClaimMs = if (near == Voice.CLAIM) nearClaimMs + ms else 0.0
        farClaimMs = if (farVoice == Voice.CLAIM) farClaimMs + ms else 0.0
        sincePredictMs += ms
        nearVoiceMs = if (near != Voice.QUIET) nearVoiceMs + ms else 0.0
        farVoiceMs = if (farVoice != Voice.QUIET) farVoiceMs + ms else 0.0
        if (farVoice == Voice.QUIET) farQuietMs += ms
        if (farVoicingKnown && !farVoicing) farSilentMs += ms
        if (playoutHeard && !playoutLiveNow) playoutSilentMs += ms

        // The fallback outranks everything: stale + non-strict reverts to open.
        val stale = farAgeMs > cfg.staleMs
        if (!cfg.on || (stale && !cfg.strict)) {
            state = State.IDLE
            wasState = State.IDLE
            nearClaimMs = 0.0; farClaimMs = 0.0; holderQuietMs = 0.0
            return Decision(true, false, true, true, State.IDLE)
        }
        // Headphones (no path) or a cancelled speaker path stand the floor down.
        val noPath = !speakers && cfg.headphoneDuplex
        val pathCancelled = speakers && cfg.speakerDuplex && aecEchoPath <= cfg.speakerDuplexPath
        if (noPath || pathCancelled) {
            state = State.IDLE
            wasState = State.IDLE
            nearClaimMs = 0.0; farClaimMs = 0.0; holderQuietMs = 0.0; heldDownMs = 0.0
            nearVoiceMs = 0.0; farVoiceMs = 0.0; playoutHold = 0.0
            inGrace = false; farWrapping = false
            duplexBlocks++
            if (pathCancelled) aecDuplexBlocks++
            return Decision(true, false, true, false, State.IDLE)
        }

        val farBlind = stale && cfg.strict
        if (farBlind) farVoice = Voice.QUIET

        // The holder going quiet releases it — on the holder's clock.
        val holderVoice = when (state) {
            State.MINE -> near
            State.THEIRS -> farVoice
            else -> Voice.QUIET
        }
        if (state == State.THEIRS) {
            val byCue = if (farVoicingKnown) (if (farVoicing) 0.0 else farSilentMs)
                        else (if (farVoice == Voice.QUIET) farQuietMs else 0.0)
            holderQuietMs = maxOf(byCue, playoutSilentMs)
        } else {
            holderQuietMs = if (holderVoice == Voice.QUIET) holderQuietMs + ms else 0.0
        }
        if (state == State.THEIRS && farEndProb < cfg.predictP) farPredArmed = true

        if (state != State.IDLE) {
            val localPred = state == State.MINE && endProb >= cfg.predictP && holderQuietMs > 0
            val farPause = state == State.THEIRS && farEndProb >= cfg.predictP && holderQuietMs > 0
            val farEarly = state == State.THEIRS && farPredArmed && farEndProb >= cfg.predictP
            val predictedEnd = (localPred || farPause || farEarly) && sincePredictMs >= cfg.predictCooldownMs
            val seenContending = state == State.MINE && farSeenTalking == true
            val contended = if (state == State.THEIRS) near != Voice.QUIET
                            else ((if (farVoicingKnown) farVoicing else farVoice != Voice.QUIET) || seenContending)
            val proven = (farVoicingKnown && !farVoicing) || playoutSilentMs >= cfg.playoutQuietMs
            val contendedWait = if (proven && state == State.THEIRS) 0.0 else cfg.contendedReleaseMs
            val waitMs = if (contended) minOf(contendedWait, cfg.releaseMs) else cfg.releaseMs
            val seenRelease = state == State.MINE && farSeenTalking == true && holderQuietMs > 0
            if (holderQuietMs >= waitMs || predictedEnd || seenRelease) {
                if (seenRelease && holderQuietMs < waitMs) seenReleases++
                if (predictedEnd) {
                    sincePredictMs = 0.0
                    predictedReleases++
                    predictedSavedMs += maxOf(0.0, cfg.releaseMs - holderQuietMs)
                    if (state == State.THEIRS) {
                        farPredictedReleases++
                        farPredictedSavedMs += maxOf(0.0, cfg.releaseMs - holderQuietMs)
                        farWrapping = true
                        farPredArmed = false
                    }
                }
                state = State.IDLE; holderQuietMs = 0.0
            }
        }

        if (state != State.THEIRS) farPredArmed = false
        if (farVoice == Voice.QUIET || farEndProb < cfg.predictP) farWrapping = false

        // Taking an empty floor.
        if (state == State.IDLE && near != Voice.QUIET &&
            ((cfg.strict && cfg.idleTakesAnyVoice) || near != Voice.BACKCHANNEL)) {
            state = State.MINE
        } else if (state == State.IDLE && farVoice != Voice.QUIET &&
            (farVoice == Voice.CLAIM || (cfg.strict && cfg.idleTakesAnyVoice)) && !farWrapping) {
            state = State.THEIRS
        }

        // Taking it from somebody: the contest.
        val visualNow = cfg.strict && nearVisualVoice
        val contestMs = if (cfg.strict)
            (if (visualNow) minOf(cfg.visualDeadlockMs, cfg.strictDeadlockMs) else cfg.strictDeadlockMs)
        else cfg.deadlockMs
        val nearInsists = if (cfg.strict) nearVoiceMs >= contestMs else nearClaimMs >= contestMs
        val farInsists = if (cfg.strict) farVoiceMs >= contestMs else farClaimMs >= contestMs
        val wasTheirs = state == State.THEIRS
        if (state == State.THEIRS && nearInsists) {
            if (!(farInsists && yieldsOnTie)) state = State.MINE
        } else if (state == State.MINE && farInsists) {
            if (!nearInsists || yieldsOnTie) state = State.THEIRS
        }
        if (cfg.strict && wasTheirs && state == State.MINE) {
            fastTakes++
            if (visualNow) visualTakes++
        }

        // The ceiling, which no belief survives.
        if (state == State.THEIRS && heldDownMs >= cfg.maxHeldDownMs) state = State.IDLE
        heldDownMs = if (state == State.THEIRS && near == Voice.CLAIM) heldDownMs + ms else 0.0

        // The ear: lag on the closing edge only.
        if (state == State.MINE && wasState != State.MINE) playoutHold = cfg.playoutLagMs
        wasState = state
        val earClosed = state == State.MINE && speakers && playoutHold <= 0

        // Idle next to a live loudspeaker does not transmit (the echo state).
        val echoRisk = state == State.IDLE && speakers && playoutTail > 0 && near == Voice.QUIET
        if (echoRisk) echoGuardBlocks++
        if (state == State.IDLE && speakers) guardableBlocks++

        if (cfg.strict) {
            // The onset grace: an interjection is delayed, never deleted.
            val grace = state == State.THEIRS && near != Voice.QUIET && nearVoiceMs <= cfg.onsetGraceMs
            if (grace) {
                graceBlocks++
                if (!inGrace) { inGrace = true; graceOnsets++ }
            } else if (state != State.THEIRS || near == Voice.QUIET) {
                inGrace = false
            }
            return Decision(
                mayTransmit = state == State.MINE || grace,
                duckOnly = false,
                playoutOpen = !(state == State.MINE && playoutHold <= 0),
                fallback = farBlind, state = state,
            )
        }
        return Decision(
            mayTransmit = state != State.THEIRS && !echoRisk,
            duckOnly = state == State.THEIRS && near != Voice.QUIET,
            playoutOpen = !earClosed,
            fallback = false, state = state,
        )
    }

    /** The far end's cue arrived; [transitMs] is the measured one-way delay. */
    fun noteFar(v: Voice, transitMs: Double = 0.0, voicing: Boolean? = null) {
        if (v == Voice.QUIET && farVoice != Voice.QUIET) farQuietMs = transitMs
        if (v != Voice.QUIET) farQuietMs = 0.0
        farVoice = v
        farAgeMs = 0.0
        farTransitMs = transitMs
        if (voicing != null) {
            farVoicingKnown = true
            if (voicing) farSilentMs = 0.0
            else if (farVoicing) farSilentMs = transitMs
            farVoicing = voicing
        }
    }

    fun noteEndProb(p: Double) { endProb = p }

    fun noteFarEndProb(p: Double) {
        farEndProb = p
        if (p > farEndProbPeak) farEndProbPeak = p
    }

    /** Sound is coming out of this machine's loudspeaker right now. */
    fun notePlayout(live: Boolean) {
        playoutLiveNow = live
        if (live) { playoutTail = cfg.playoutTailMs; playoutSilentMs = 0.0; playoutHeard = true }
    }
}
