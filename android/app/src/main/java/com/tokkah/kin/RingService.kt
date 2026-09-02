package com.tokkah.kin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.tokkah.kin.net.Identity
import com.tokkah.kin.net.RingWatcher

/**
 * The other half of "somebody can call this phone".
 *
 * The Mac keeps a LaunchAgent alive from login, holding one HTTPS poll on its
 * own mailbox — no camera, no microphone, no socket. Android will not keep a
 * bare thread alive at all, so the equivalent is a foreground service, which
 * costs a visible notification and is the honest price of the feature: a phone
 * that can be rung is a phone that is listening, and Android insists you be
 * told.
 *
 * A ring arrives as a FULL-SCREEN INTENT, which is the same promise the Mac's
 * window-above-everything makes: a call is not a thing you find later in a
 * list. Declining is a signed `bye` sent from here, so the caller's phone stops
 * ringing rather than timing out.
 *
 * This is not push. A push would cost nothing while idle and is the right end
 * state; it needs a server route that does not exist yet, and shipping the
 * polling half first means the feature works today rather than being a plan.
 */
class RingService : Service() {
    var watcher: RingWatcher? = null; private set
    private lateinit var identity: Identity

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        identity = Identity(filesDir.resolve("kin"))
        channels(this)
        startForeground(ONGOING_ID, listeningNotification())
        val w = RingWatcher(identity)
        w.onRing = { r -> ring(r) }
        w.onBye = { _ -> cancelRing() }
        w.standDown = appInFront
        w.start()
        watcher = w
        live = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DECLINE -> {
                val who = intent.getStringExtra(EXTRA_FROM) ?: ""
                val room = intent.getStringExtra(EXTRA_ROOM) ?: ""
                cancelRing()
                Thread { identity.ring(who, room, kind = "bye") }
                    .apply { isDaemon = true }.start()
            }
            ACTION_STOP -> stopSelf()
        }
        // STICKY: being killed for memory is not the person saying stop.
        return START_STICKY
    }

    override fun onDestroy() {
        live = null
        watcher?.stop()
        watcher = null
        super.onDestroy()
    }

    private fun listeningNotification(): Notification =
        NotificationCompat.Builder(this, CH_ONGOING)
            .setContentTitle("Kin is listening")
            .setContentText("So somebody can call this phone.")
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(open(null, null))
            .addAction(0, "Stop", service(ACTION_STOP, null, null))
            .build()

    private fun ring(r: Identity.Ring) {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        val full = open(r.from, r.room, r.k)
        val n = NotificationCompat.Builder(this, CH_RING)
            .setContentTitle("@${r.from} is calling")
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setAutoCancel(true)
            .setOngoing(true)
            // The card, not a line in a list: the same promise as the Mac's
            // window coming up above every other app.
            .setFullScreenIntent(full, true)
            .setContentIntent(full)
            .addAction(0, "Decline", service(ACTION_DECLINE, r.from, r.room))
            .addAction(0, "Answer", open(r.from, r.room, r.k))
            .build()
        nm.notify(RING_ID, n)
        // The sound and the buzz. The notification alone was the SEEING half of
        // a ring; a phone face-down on a table is the case the watcher exists
        // for, and it never made a noise.
        Ringer.start(this)
        Ringer.checkReachedFront(this)
    }

    private fun cancelRing() {
        Ringer.stop()
        getSystemService(NotificationManager::class.java)?.cancel(RING_ID)
    }

    private fun open(from: String?, room: String?, key: String? = null): PendingIntent {
        val i = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (from != null) putExtra(EXTRA_FROM, from)
            if (room != null) putExtra(EXTRA_ROOM, room)
            // The key that signed the ring: the answered call requires the
            // media handshake to come from it.
            if (!key.isNullOrEmpty()) putExtra(EXTRA_KEY, key)
        }
        return PendingIntent.getActivity(
            this, if (room == null) 0 else 1, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun service(action: String, from: String?, room: String?): PendingIntent {
        val i = Intent(this, RingService::class.java).apply {
            this.action = action
            if (from != null) putExtra(EXTRA_FROM, from)
            if (room != null) putExtra(EXTRA_ROOM, room)
        }
        return PendingIntent.getService(
            this, action.hashCode(), i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    companion object {
        /**
         * Set by the activity while it is in front. A flag rather than a
         * stop/start, because Android REFUSES startForegroundService() from a
         * backgrounded app — the first version tried to hand the mailbox back
         * in ON_STOP and took a ForegroundServiceStartNotAllowedException with
         * the app on its way out, which is a crash on the way to the home
         * screen. The service simply keeps running and stops READING.
         */
        @Volatile var appInFront = false
            set(v) { field = v; live?.watcher?.standDown = v }

        @Volatile private var live: RingService? = null

        const val CH_ONGOING = "kin.listening"
        const val CH_RING = "kin.ring"
        const val ONGOING_ID = 1
        const val RING_ID = 2
        const val ACTION_DECLINE = "com.tokkah.kin.DECLINE"
        const val ACTION_STOP = "com.tokkah.kin.STOP"
        const val EXTRA_FROM = "from"
        const val EXTRA_ROOM = "room"
        const val EXTRA_KEY = "key"

        fun channels(ctx: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
            nm.createNotificationChannel(
                NotificationChannel(CH_ONGOING, "Listening for calls",
                    NotificationManager.IMPORTANCE_LOW).apply {
                    description = "The quiet notification that lets somebody call this phone."
                },
            )
            nm.createNotificationChannel(
                NotificationChannel(CH_RING, "Incoming calls",
                    NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Someone calling you."
                    setBypassDnd(false)
                    // SILENT ON PURPOSE. The ringtone is played and looped by
                    // Ringer, on the ringer stream. Leaving the channel's own
                    // sound on would put a one-shot notification chime over the
                    // top of it — two sounds for one call, and the wrong one
                    // arriving first.
                    setSound(null, null)
                    enableVibration(false)
                },
            )
        }

        fun start(ctx: Context) {
            val i = Intent(ctx, RingService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i)
            else ctx.startService(i)
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, RingService::class.java))
        }
    }
}
