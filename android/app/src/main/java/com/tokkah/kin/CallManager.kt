package com.tokkah.kin

import android.content.Context
import com.tokkah.kin.net.CallSession

/**
 * Lifecycle-independent call state holder.
 *
 * Moving session, audio, and video ownership out of the Compose composition
 * into CallManager ensures that configuration changes (rotation, theme, font scale)
 * do not destroy active calls or leave orphaned sessions running.
 */
object CallManager {
    @Volatile var session: CallSession? = null; private set
    @Volatile var audio: AudioDevice? = null; private set
    @Volatile var video: VideoDevice? = null; private set
    @Volatile var room: String = ""; private set
    @Volatile var who: String = ""; private set
    @Volatile var inCall: Boolean = false; private set

    var onStateChanged: (() -> Unit)? = null
    var onLeaveRequested: (() -> Unit)? = null

    fun startCall(
        ctx: Context,
        s: CallSession,
        a: AudioDevice,
        v: VideoDevice,
        callRoom: String,
        callWho: String,
    ) {
        session = s
        audio = a
        video = v
        room = callRoom
        who = callWho
        inCall = true
        CallService.start(ctx, callWho)
        onStateChanged?.invoke()
    }

    private var leaving = false

    fun leave(ctx: Context? = null) {
        if (!inCall && session == null) return
        if (leaving) return
        leaving = true
        try {
            inCall = false
            val s = session
            val a = audio
            val v = video

            video = null
            audio = null
            session = null
            room = ""
            who = ""

            v?.stop()
            a?.stop()
            s?.stop(hungUp = true)

            ctx?.let { CallService.stop(it) }
            onLeaveRequested?.invoke()
            onStateChanged?.invoke()
        } finally {
            leaving = false
        }
    }

    fun onNetworkChanged() {
        session?.recheckNetwork()
    }
}
