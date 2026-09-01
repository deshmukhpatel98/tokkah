package com.tokkah.kin

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import androidx.core.content.ContextCompat
import kotlin.math.round

/**
 * Port of mac/Sources/tk/Geo.swift — ONE coarse fix, and the rules around it
 * are the feature.
 *
 * Taken only AFTER the transport locks on a real call: never at launch (a
 * permission dialog in front of a doorbell), never for a ring preview (nobody
 * has agreed to anything yet), and never as a subscription — there is nothing
 * to stop, because updating never starts.
 *
 * Two decimal places is ~1.1 km. The beat gets a city block's worth of truth,
 * enough to draw the line between two ends and read the RTT against it, and no
 * more. A denial is RECORDED, because an absent number that cannot be told from
 * "never asked" is a blind instrument reporting a negative.
 */
class Geo(private val ctx: Context) {
    var lat: Double? = null; private set
    var lon: Double? = null; private set
    var err: String? = null; private set
    private var taken = false

    val granted: Boolean
        get() = ContextCompat.checkSelfPermission(
            ctx, android.Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED

    /** Call when the transport locks. Safe to call again; only the first does work. */
    @SuppressLint("MissingPermission")
    fun onTransportLock() {
        if (taken) return
        taken = true
        if (!granted) { err = "not granted"; return }
        try {
            val lm = ctx.getSystemService(LocationManager::class.java)
                ?: run { err = "no location service"; return }
            // The LAST known fix, not a new one: this is a call, not a map, and
            // asking the radio for a fresh fix costs power and a wait for a
            // number that only needs to be right to a kilometre.
            val p = lm.getProviders(true)
                .mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
                .maxByOrNull { it.time }
            if (p == null) { err = "no fix"; return }
            lat = round(p.latitude * 100) / 100
            lon = round(p.longitude * 100) / 100
        } catch (e: SecurityException) {
            err = "denied"
        } catch (e: Exception) {
            err = e.message ?: "failed"
        }
    }
}
