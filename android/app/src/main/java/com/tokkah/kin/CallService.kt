package com.tokkah.kin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Foreground service scoped to an active call.
 *
 * Keeps the call alive when the app moves to the background (P0.6).
 * Holds PARTIAL_WAKE_LOCK and low-latency Wi-Fi lock so audio and network
 * threads are not frozen by Android 12+ cached app freezes.
 * Monitors network changes via ConnectivityManager.NetworkCallback to re-run STUN
 * and rendezvous on Wi-Fi <-> Cellular switches.
 */
class CallService : Service() {
    companion object {
        const val CHANNEL_ID = "kin_call"
        const val NOTIFICATION_ID = 2001
        const val ACTION_START = "com.tokkah.kin.CALL_START"
        const val ACTION_STOP = "com.tokkah.kin.CALL_STOP"
        const val ACTION_LEAVE = "com.tokkah.kin.CALL_LEAVE"
        const val EXTRA_WHO = "who"

        fun start(ctx: Context, who: String = "") {
            val intent = Intent(ctx, CallService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_WHO, who)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }

        fun stop(ctx: Context) {
            val intent = Intent(ctx, CallService::class.java).apply {
                action = ACTION_STOP
            }
            ctx.startService(intent)
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseLocks()
                stopForeground(true)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_LEAVE -> {
                CallManager.leave(this)
                releaseLocks()
                stopForeground(true)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val who = intent?.getStringExtra(EXTRA_WHO) ?: ""
                acquireLocks()
                registerNetworkCallback()
                val notification = buildNotification(who)
                val foregroundType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    var t = 0
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                        t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                        t = t or ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                    }
                    t
                } else 0

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && foregroundType != 0) {
                    startForeground(NOTIFICATION_ID, notification, foregroundType)
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
            wakeLock = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "kin:call_wake")?.apply {
                setReferenceCounted(false)
                acquire(12 * 60 * 60 * 1000L)
            }
        }
        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            wifiLock = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                wm?.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "kin:call_wifi")
            } else {
                @Suppress("DEPRECATION")
                wm?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "kin:call_wifi")
            }?.apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        unregisterNetworkCallback()
    }

    private fun registerNetworkCallback() {
        if (networkCallback != null) return
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                CallManager.onNetworkChanged()
            }
            override fun onLost(network: Network) {
                CallManager.onNetworkChanged()
            }
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                CallManager.onNetworkChanged()
            }
        }
        val req = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        runCatching { cm.registerNetworkCallback(req, cb) }
        networkCallback = cb
    }

    private fun unregisterNetworkCallback() {
        networkCallback?.let { cb ->
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            runCatching { cm?.unregisterNetworkCallback(cb) }
        }
        networkCallback = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java) ?: return
            val chan = NotificationChannel(
                CHANNEL_ID,
                "Active call",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Ongoing call audio and connection"
                setShowBadge(false)
            }
            nm.createNotificationChannel(chan)
        }
    }

    private fun buildNotification(who: String): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openPending = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val leaveIntent = Intent(this, CallService::class.java).apply {
            action = ACTION_LEAVE
        }
        val leavePending = PendingIntent.getService(
            this, 1, leaveIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val text = if (who.isNotBlank()) "Call with @$who" else "Call in progress"
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Kin")
            .setContentText(text)
            .setContentIntent(openPending)
            .addAction(0, "Leave", leavePending)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .build()
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }
}
