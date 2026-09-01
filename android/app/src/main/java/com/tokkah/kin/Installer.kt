package com.tokkah.kin

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.os.Build
import java.io.File

/**
 * Installing an update without asking, the way the Mac does.
 *
 * The Mac stages a sibling bundle and RENAME_SWAPs it; a person downloads Kin
 * once and never thinks about it again. Android's equivalent exists and is
 * narrow: from API 31, an app that is its OWN installer of record may update
 * ITSELF through PackageInstaller with `USER_ACTION_NOT_REQUIRED`, provided the
 * new APK carries the same package name and the same signing certificate. No
 * prompt, no Play, no device-owner privileges.
 *
 * It is narrow in ways worth stating rather than discovering:
 *
 *   · the FIRST install is always a tap. Nothing can make a phone install an
 *     app it has never seen without the person agreeing, and nothing should.
 *   · if this copy was installed by something else — a browser, a file manager,
 *     adb — that thing is the installer of record and the silent path is not
 *     ours to take. Then it falls back to the one-tap confirm, which is what
 *     shipped before this.
 *   · the system may still demand user action; it says so with
 *     STATUS_PENDING_USER_ACTION and hands back an Intent, and that Intent is
 *     honoured rather than swallowed. A silent updater that silently does
 *     nothing is worse than one that asks.
 *
 * The bytes are already checked before anything here runs: the manifest carried
 * an Ed25519 signature over a compiled-in key and the download matched its
 * sha256. This file only decides HOW to install them.
 */
object Installer {
    const val ACTION_STATUS = "com.tokkah.kin.INSTALL_STATUS"

    /** What happened, for the log and for the row on the front door. */
    @Volatile var lastStatus: String? = null
    @Volatile var silentWorked = false

    /** True when this copy may replace itself with no prompt at all. */
    fun canInstallSilently(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return try {
            val pm = ctx.packageManager
            val self = ctx.packageName
            val installer = pm.getInstallSourceInfo(self).installingPackageName
            // Ours, or nobody's — a sideloaded copy has no installer of record
            // and is allowed to adopt itself on its first self-update, which is
            // how a phone that got Kin from the download page ever reaches the
            // silent path at all.
            installer == self || installer == null
        } catch (e: Exception) { false }
    }

    /**
     * Install [apk] over this app. Returns true when the session was committed;
     * the actual result arrives as a broadcast, because an install that
     * replaces the running process cannot return to it.
     */
    fun install(ctx: Context, apk: File): Boolean {
        return try {
            val pi = ctx.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL,
            ).apply {
                setAppPackageName(ctx.packageName)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    // Ask for no prompt. The system decides; if it refuses it
                    // tells us, and we ask the person instead of giving up.
                    setRequireUserAction(
                        PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED,
                    )
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    setPackageSource(PackageInstaller.PACKAGE_SOURCE_STORE)
                }
            }
            val id = pi.createSession(params)
            pi.openSession(id).use { session ->
                apk.inputStream().use { input ->
                    session.openWrite("kin", 0, apk.length()).use { output ->
                        input.copyTo(output, 128 * 1024)
                        session.fsync(output)
                    }
                }
                val intent = Intent(ACTION_STATUS).setPackage(ctx.packageName)
                val sender = PendingIntent.getBroadcast(
                    ctx, id, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
                session.commit(sender.intentSender)
            }
            android.util.Log.i("kin", "install: session $id committed")
            true
        } catch (e: Exception) {
            lastStatus = "install failed: ${e.message}"
            android.util.Log.e("kin", "install: ${e.message}")
            false
        }
    }

    /** Fall back to the confirm dialog, which is what shipped before silence. */
    fun installWithPrompt(ctx: Context, apk: File) {
        val uri = androidx.core.content.FileProvider.getUriForFile(
            ctx, ctx.packageName + ".files", apk,
        )
        ctx.startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
    }

    /**
     * Hears how the install went. Registered by the app; a
     * STATUS_PENDING_USER_ACTION is honoured rather than swallowed.
     */
    class Status : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    android.util.Log.i("kin", "install: the system wants a tap")
                    lastStatus = "the system wants a tap"
                    @Suppress("DEPRECATION")
                    val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    confirm?.let { runCatching { ctx.startActivity(it) } }
                }
                PackageInstaller.STATUS_SUCCESS -> {
                    android.util.Log.i("kin", "install: updated")
                    lastStatus = "updated"
                    silentWorked = true
                }
                else -> {
                    lastStatus = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                        ?: "install did not complete"
                    android.util.Log.i("kin", "install: $lastStatus")
                }
            }
        }
    }

    fun register(ctx: Context): BroadcastReceiver {
        val r = Status()
        val f = IntentFilter(ACTION_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(r, f, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            ctx.registerReceiver(r, f)
        }
        return r
    }
}
