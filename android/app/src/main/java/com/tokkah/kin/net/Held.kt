package com.tokkah.kin.net

/**
 * Port of the honesty states in HELD.md — an honest state instead of a frozen
 * face.
 *
 *   paused → "connection paused — reconnecting"
 *   held   → "holding · audio live"
 *
 * `paused` OUTRANKS `held`. If audio is not arriving, never put the word
 * "audio" beside the word "live".
 *
 * The inputs are DIMENSIONLESS: a concealment fraction over an 8-beat window,
 * entered above 0.25 and exited below 0.05, and video frozen means no decoded
 * frames for 3 beats WHILE fragments are still arriving. A fraction rather than
 * a rate is what makes one threshold work at every distance and every device
 * cadence.
 *
 * ARMED ONLY once the far end's audio has actually played: before that there is
 * nothing to be paused FROM, and a call that has not started yet is not a call
 * that broke.
 */
class Held {
    enum class State { NONE, HELD, PAUSED }

    private val window = 8
    private val conceal = ArrayDeque<Double>()
    private var frozenBeats = 0
    private var armed = false
    private var state = State.NONE

    var lastFrac = 0.0; private set

    /**
     * One beat. [concealed] and [played] are this beat's deltas; [decodedFrames]
     * is video frames decoded and [fragments] video fragments received.
     */
    fun beat(concealed: Int, played: Int, decodedFrames: Int, fragments: Int): State {
        val total = concealed + played
        if (played > 0) armed = true
        val frac = if (total > 0) concealed.toDouble() / total else 0.0
        conceal.addLast(frac)
        if (conceal.size > window) conceal.removeFirst()
        val mean = if (conceal.isEmpty()) 0.0 else conceal.average()
        lastFrac = mean

        // Video frozen is only frozen if fragments are STILL ARRIVING: a peer
        // who turned their camera off is not a peer whose picture broke.
        frozenBeats = if (decodedFrames == 0 && fragments > 0) frozenBeats + 1 else 0

        if (!armed) { state = State.NONE; return state }
        state = when {
            conceal.size >= 3 && mean > 0.25 -> State.PAUSED
            state == State.PAUSED && mean >= 0.05 -> State.PAUSED
            frozenBeats >= 3 -> State.HELD
            else -> State.NONE
        }
        return state
    }

    /** The sentence, in plain words. No numbers on the consumer surface. */
    val sentence: String?
        get() = when (state) {
            State.PAUSED -> "connection paused — reconnecting"
            State.HELD -> "holding · audio live"
            State.NONE -> null
        }

    fun reset() {
        conceal.clear(); frozenBeats = 0; armed = false; state = State.NONE
    }
}
