package com.tokkah.kin.net

import java.net.HttpURLConnection
import java.net.URL

// Port of Server.swift + the rendezvous/warm halves of Stun.swift.
object Server {
    @Volatile var base = "https://room.tokkah.com"
    val invite get() = "https://kin.tokkah.com"
    // A separate trust boundary on purpose; Android's feed lives beside macos/.
    val updates get() = "$base/android"
}

object Rendezvous {
    data class Peer(
        val id: String, val ip: String, val port: Int, val ageMs: Int,
        val localIP: String?, val localPort: Int?, val relayIP: String?, val relayPort: Int?,
    )

    /**
     * Publish our address, return whoever else is in the room.
     * null IS NOT AN EMPTY ROOM: null = the request never completed;
     * [] = the directory says nobody else is here. (Stun.swift:174-185)
     */
    fun exchange(room: String, me: String, addr: String?, local: String? = null,
                 relay: String? = null, base: String = Server.base): List<Peer>? {
        var u = "$base/api/room/$room/rv?me=$me"
        addr?.let { u += "&addr=$it" }
        local?.let { u += "&local=$it" }
        relay?.let { u += "&relay=$it" }
        val body = httpGet(u, timeoutMs = 8000) ?: return null
        return parsePeers(body)
    }

    /** Hand-rolled parser for the fixed {peers:[{id,addr,local,relay,ageMs}]} shape. */
    fun parsePeers(body: String): List<Peer>? {
        val arr = Regex("\"peers\"\\s*:\\s*\\[(.*)\\]", RegexOption.DOT_MATCHES_ALL)
            .find(body)?.groupValues?.get(1) ?: return null
        val out = mutableListOf<Peer>()
        for (m in Regex("\\{[^{}]*\\}").findAll(arr)) {
            val o = m.value
            fun str(k: String) = Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(o)?.groupValues?.get(1)
            fun int(k: String) = Regex("\"$k\"\\s*:\\s*(-?\\d+)").find(o)?.groupValues?.get(1)?.toIntOrNull()
            val id = str("id") ?: continue
            val a = str("addr") ?: continue
            val bits = a.split(":")
            if (bits.size != 2) continue
            val port = bits[1].toIntOrNull() ?: continue
            fun pair(k: String): Pair<String, Int>? {
                val v = str(k) ?: return null
                val vb = v.split(":")
                val p = if (vb.size == 2) vb[1].toIntOrNull() else null
                return if (p != null) vb[0] to p else null
            }
            val l = pair("local"); val r = pair("relay")
            out.add(Peer(id, bits[0], port, int("ageMs") ?: 0, l?.first, l?.second, r?.first, r?.second))
        }
        return out
    }

    private val warmed = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    /** Fire-and-forget durable-object warm; once per room per process. */
    fun warm(room: String) {
        if (room.isEmpty() || !warmed.add(room)) return
        Thread {
            httpGet("${Server.base}/api/room/$room/warm", timeoutMs = 5000)
        }.apply { isDaemon = true }.start()
    }
}

internal fun httpGet(url: String, timeoutMs: Int): String? = try {
    val c = URL(url).openConnection() as HttpURLConnection
    c.connectTimeout = timeoutMs
    c.readTimeout = timeoutMs
    c.useCaches = false
    if (c.responseCode in 200..299) c.inputStream.bufferedReader().readText() else null
} catch (e: Exception) { null }
