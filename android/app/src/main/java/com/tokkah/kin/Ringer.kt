package com.tokkah.kin

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.CombinedVibration
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import com.tokkah.kin.net.Metrics

/**
 * Port of mac/Sources/tk/Ringer.swift — a ring you can HEAR as well as see.
 *
 * The phone had the seeing half and not the hearing half: a full-screen intent
 * put the card up, and the only sound was whatever one-shot chime the
 * notification channel happened to pick. A call that arrives with a
 * notification's blip is a message, not a call, and a phone face-down on a table
 * is exactly the case the whole watcher exists for.
 *
 * The Mac reads Apple's own ringtone out of the tone library and loops it.
 * Android's equivalent is better defined and needs no file-poking:
 * [RingtoneManager.TYPE_RINGTONE] is the tone this person chose for calls, so
 * Kin sounds like their phone ringing rather than like an app they cannot name.
 *
 * The ladder is the same shape as the Mac's, and reported the same way — a ring
 * that fell back silently would be indistinguishable from one that chose to
 * sound like an alert:
 *
 *   1. the person's own ringtone
 *   2. the system default ringtone, if they have set theirs to Silent
 *   3. the notification tone, which at least makes a noise
 *
 * ── WHAT IS DIFFERENT FROM THE MAC, AND WHY ─────────────────────────────────
 *
 * `USAGE_NOTIFICATION_RINGTONE` on the stream means the phone's ringer volume,
 * its silent switch, and Do Not Disturb all govern this — which is not a
 * limitation to work around but the correct behaviour: a phone set to silent
 * must stay silent, and an app that rings anyway is a bug report.
 *
 * The vibration is not decoration either. It is the half that works when the
 * ringer is off, and on a phone it is often the only half a person gets.
 */
object Ringer {
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private val lock = Any()

    /** True while a ring is in progress — the flag the stop paths test. */
    @Volatile var ringing = false
        private set

    private var stopAt = 0L

    /**
     * Start ringing. [quiet] is the phone's copy of the Mac's `--mute`: one
     * switch over EVERY sound this app makes. A switch called mute that leaves
     * one sound playing is a switch nobody can rely on, and on the Mac the
     * ringtone was exactly the sound it missed.
     */
    fun start(ctx: Context, quiet: Boolean = false) {
        synchronized(lock) {
            if (ringing) return
            ringing = true
        }
        Metrics.count("ring_ui_shown")

        if (quiet) {
            android.util.Log.i("kin", "ring: silent — this copy is muted")
            Metrics.count("ring_tone_muted")
        } else {
            startTone(ctx)
            startBuzz(ctx)
        }

        // Stops itself after 40 s, the same as the Mac, so a missed call does
        // not ring the room all day.
        stopAt = System.currentTimeMillis() + 40_000
        Thread({
            while (ringing && System.currentTimeMillis() < stopAt) Thread.sleep(200)
            if (ringing) stop()
        }, "kin-ring-timeout").apply { isDaemon = true }.start()
    }

    fun stop() {
        val p: MediaPlayer?
        val v: Vibrator?
        synchronized(lock) {
            if (!ringing) return
            ringing = false
            p = player; player = null
            v = vibrator; vibrator = null
        }
        runCatching { p?.stop() }
        runCatching { p?.release() }
        runCatching { v?.cancel() }
    }

    // ── THE SOUND A CALL MAKES ON A PHONE ───────────────────────────────────

    private fun startTone(ctx: Context) {
        val ladder = listOf(
            "chosen" to runCatching {
                RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_RINGTONE)
            }.getOrNull(),
            "default" to runCatching {
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            }.getOrNull(),
            "notification" to runCatching {
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            }.getOrNull(),
        )
        for ((rung, uri) in ladder) {
            if (uri == null) continue
            if (play(ctx, uri)) {
                android.util.Log.i("kin", "ring: sounding the $rung ringtone")
                Metrics.count(if (rung == "chosen") "ring_tone_apple" else "ring_tone_fallback")
                Metrics.fact("ring_tone", rung)
                return
            }
        }
        android.util.Log.i("kin", "ring: no ringtone would play — buzzing only")
        Metrics.count("ring_tone_fallback")
        Metrics.fact("ring_tone", "none")
    }

    private fun play(ctx: Context, uri: Uri): Boolean = try {
        val p = MediaPlayer()
        p.setAudioAttributes(
            AudioAttributes.Builder()
                // The ringer stream: governed by the ringer volume, the silent
                // switch and Do Not Disturb, which is what a call should be.
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build(),
        )
        p.setDataSource(ctx, uri)
        // A ringtone is a LOOP, not a sample.
        p.isLooping = true
        p.prepare()
        p.start()
        synchronized(lock) { player = p }
        true
    } catch (e: Exception) {
        android.util.Log.i("kin", "ring: $uri would not play (${e.message})")
        false
    }

    /**
     * The half that survives a silent phone. Deliberately the classic two-pulse
     * telephone cadence rather than a single buzz — a pattern is recognisable
     * as a call from a pocket, and one long buzz is a text message.
     */
    private fun startBuzz(ctx: Context) {
        val v = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                ctx.getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                ctx.getSystemService(Vibrator::class.java)
            }
        } catch (e: Exception) { null } ?: return
        if (!v.hasVibrator()) return

        // Ringing must not buzz when the phone is only set to vibrate-off; the
        // audio manager's own ringer mode is the authority.
        val am = ctx.getSystemService(AudioManager::class.java)
        if (am?.ringerMode == AudioManager.RINGER_MODE_SILENT) return

        val pattern = longArrayOf(0, 700, 400, 700, 1400)
        runCatching {
            val effect = VibrationEffect.createWaveform(pattern, 0)
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // VibrationAttributes, not AudioAttributes: the same intent
                // ("this is a ringtone") expressed in the vibrator's own terms,
                // which is what makes Do Not Disturb govern the buzz too.
                val vm = ctx.getSystemService(VibratorManager::class.java)
                vm?.vibrate(
                    CombinedVibration.createParallel(effect),
                    android.os.VibrationAttributes.createForUsage(
                        android.os.VibrationAttributes.USAGE_RINGTONE,
                    ),
                )
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(effect, attrs)
            }
            synchronized(lock) { vibrator = v }
        }
    }

    /**
     * ── AND THEN CHECK, because asking is not getting ───────────────────────
     *
     * The Mac sets four window properties and then reads the window server's
     * own answer to "can a human see this", because on the Mac all four were
     * set and the card still came up behind the user's editor.
     *
     * Android's version of that failure is real and more common: from API 34 a
     * full-screen intent needs a permission the system can refuse, and when it
     * refuses, the card silently becomes a notification in the shade. Same
     * shape — asked for the front, did not get it — so it is checked and
     * counted rather than assumed.
     */
    fun checkReachedFront(ctx: Context) {
        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            runCatching {
                ctx.getSystemService(android.app.NotificationManager::class.java)
                    ?.canUseFullScreenIntent() == true
            }.getOrDefault(false)
        } else true
        Metrics.count(if (ok) "ring_front_ok" else "ring_front_fail")
        Metrics.mark("ring_front_ms", Metrics.sinceLaunch())
        if (!ok) {
            android.util.Log.i(
                "kin",
                "ring: the card did NOT reach the front — the call is ringing " +
                    "where nobody can see it",
            )
        }
    }
}
