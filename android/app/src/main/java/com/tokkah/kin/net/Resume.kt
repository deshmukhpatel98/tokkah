package com.tokkah.kin.net

import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * Port of mac/Sources/tk/Resume.swift — a call is a FACT ON DISK, not process
 * state.
 *
 * This fits Android better than it fits macOS: a phone kills a backgrounded
 * process as a matter of routine, and every one of those deaths used to end a
 * call nobody hung up on. The record is written at the transport lock (not at
 * launch: a process that never found anybody was never in a call), refreshed
 * once a second, and deleted by exactly ONE thing — a human hanging up.
 *
 * Not by the process ending. Not by a crash, which could not delete anything
 * anyway, which is the point.
 */
class Resume(private val root: File) {
    class Live(
        val room: String,
        val at: Double,
        val startedAt: Double,
        val call: String,
        val port: Int,
        val peer: String,
        val who: String,
        val path: String?,
    )

    private val file get() = File(root, "resume.json")
    private val seedFile get() = File(root, "machine.txt")
    private var current: Live? = null
    private val lock = Object()

    fun now() = System.currentTimeMillis().toDouble()

    /** The call is real. Called at the transport lock. */
    fun begin(room: String, port: Int, peer: String, who: String, call: String, path: String? = null) {
        synchronized(lock) {
            val started = current?.startedAt ?: now()
            current = Live(room, now(), started, call, port, peer, who, path)
            store(current!!)
        }
    }

    /** "This call was alive as of now." Once a second, nowhere near the media path. */
    fun touch(path: String? = null) {
        synchronized(lock) {
            val l = current ?: return
            current = Live(l.room, now(), l.startedAt, l.call, l.port, l.peer, l.who, path ?: l.path)
            store(current!!)
        }
    }

    /**
     * A person hung up — here or at the far end. NOTHING ELSE may call this.
     */
    fun end() {
        synchronized(lock) {
            current = null
            file.delete()
        }
    }

    /** A call this phone was in and never hung up on, or null. */
    fun pending(maxAgeMs: Double = 6 * 60 * 60 * 1000.0): Live? {
        val l = read() ?: return null
        // Old enough that resuming would be surprising rather than helpful.
        if (now() - l.at > maxAgeMs) { file.delete(); return null }
        return l
    }

    /**
     * The remembered address, read WITHOUT the side effects of [pending]. Only
     * ever used to aim a few datagrams at where we were.
     */
    fun rememberedPath(): Pair<String, Int>? {
        val raw = read()?.path?.split(" ")?.lastOrNull() ?: return null
        val bits = raw.split(":")
        if (bits.size != 2) return null
        val p = bits[1].toIntOrNull() ?: return null
        if (bits[0].isEmpty()) return null
        return bits[0] to p
    }

    private fun read(): Live? {
        if (!file.isFile) return null
        val t = runCatching { file.readText() }.getOrNull() ?: return null
        fun s(k: String) = Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(t)?.groupValues?.get(1)
        fun d(k: String) = Regex("\"$k\"\\s*:\\s*([0-9.eE+-]+)").find(t)?.groupValues?.get(1)?.toDoubleOrNull()
        val room = s("room") ?: return null
        return Live(
            room, d("at") ?: 0.0, d("startedAt") ?: 0.0, s("call") ?: "",
            (d("port") ?: 0.0).toInt(), s("peer") ?: "", s("who") ?: "", s("path"),
        )
    }

    private fun store(l: Live) {
        runCatching {
            root.mkdirs()
            val tmp = File(root, "resume.json.tmp")
            tmp.writeText(
                """{"room":"${l.room}","at":${l.at},"startedAt":${l.startedAt},""" +
                """"call":"${l.call}","port":${l.port},"peer":"${l.peer}",""" +
                """"who":"${l.who}"${l.path?.let { ",\"path\":\"$it\"" } ?: ""}}""",
            )
            file.delete()
            if (!tmp.renameTo(file)) tmp.delete()
        }
    }

    /**
     * Who this phone is in the room directory. Stable across a restart, so a
     * resumed call is the SAME participant rather than a second one holding a
     * slot the first still owns.
     */
    fun rendezvousId(room: String, port: Int): String {
        val h = MessageDigest.getInstance("SHA-256")
        h.update("kin-rv-v1".toByteArray())
        h.update(machineSeed().toByteArray())
        h.update(room.toByteArray())
        h.update(port.toString().toByteArray())
        val hex = h.digest().take(8).joinToString("") { "%02x".format(it) }
        return "kin-$hex"
    }

    private fun machineSeed(): String {
        if (seedFile.isFile) {
            val v = runCatching { seedFile.readText().trim() }.getOrNull()
            if (!v.isNullOrEmpty()) return v
        }
        val v = ByteArray(16).also { SecureRandom().nextBytes(it) }
            .joinToString("") { "%02x".format(it) }
        runCatching { root.mkdirs(); seedFile.writeText(v) }
        return v
    }
}
