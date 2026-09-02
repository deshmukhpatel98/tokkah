package com.tokkah.kin.net

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * Port of mac/Sources/tk/Identity.swift — the handle registry, the Ed25519
 * device key, and the ring mailbox. Same endpoints, same signed domains, same
 * verification rule: the SERVER verifies nothing, the callee does.
 */
class Identity(private val dir: File, private val base: String = Server.base) {

    class Ring(val from: String, val room: String, val t: Int, val kind: String?, val verified: Boolean)

    sealed class PollOutcome {
        class Answer(val rings: List<Ring>, val serverHolds: Boolean?, val quiet: Boolean?) : PollOutcome()
        object Failed : PollOutcome()
        object Refused : PollOutcome()
        object RateLimited : PollOutcome()
    }

    /** The words this version knows. An unknown kind is dropped BEFORE the
     *  signature check: there is nothing sensible to do with a valid signature
     *  over a meaning we cannot read. */
    private val ringKinds = setOf("bye")

    var handle: String = ""; private set
    var claimed = false; private set
    private var tok = ""
    private var seed = ByteArray(0)
    private val keyFile get() = File(dir, "identity.json")
    private val contactsFile get() = File(dir, "contacts.json")
    private val calledFile get() = File(dir, "called.json")
    private val lastCallFile get() = File(dir, "lastcall.json")

    var lastPollStatus = 0; private set

    init { load() }

    private fun load() {
        if (keyFile.exists()) {
            val t = keyFile.readText()
            handle = field(t, "handle") ?: ""
            tok = field(t, "tok") ?: ""
            seed = b64d(field(t, "seed") ?: "")
            claimed = t.contains("\"claimed\":true") || t.contains("\"claimed\": true")
        }
        if (seed.size != 32) {
            seed = ByteArray(32).also { SecureRandom().nextBytes(it) }
            tok = ByteArray(32).also { SecureRandom().nextBytes(it) }
                .joinToString("") { "%02x".format(it) }
            claimed = false
            save()
        }
    }

    private fun save() {
        dir.mkdirs()
        keyFile.writeText(
            """{"handle":"$handle","tok":"$tok","seed":"${b64e(seed)}","claimed":$claimed}""")
        // 0o700: the device key never leaves this phone.
        keyFile.setReadable(false, false); keyFile.setReadable(true, true)
        keyFile.setWritable(false, false); keyFile.setWritable(true, true)
    }

    val publicKey: ByteArray get() = Ed25519.publicFromSeed(seed)
    val publicKeyB64: String get() = b64e(publicKey)

    /** `^[a-z][a-z0-9]{1,31}$` — the server's rule, applied here too. */
    fun handleOK(h: String) = Regex("^[a-z][a-z0-9]{1,31}$").matches(h)

    /**
     * Claim [want] (or the stored handle). Walks the collision ladder exactly
     * as the Mac does: devesh → deveshp → devesh2 …
     */
    fun claim(want: String): Boolean {
        val basis = want.lowercase().filter { it.isLetterOrDigit() }.take(24)
            .ifEmpty { "kin" }.let { if (it[0].isDigit()) "k$it" else it }
        val ladder = mutableListOf(basis)
        if (basis.length < 32) ladder.add(basis + basis[0])
        for (i in 2..9) ladder.add(basis + i)
        for (h in ladder) {
            if (!handleOK(h)) continue
            when (attempt(h)) {
                200 -> { handle = h; claimed = true; save(); return true }
                403 -> continue                      // taken by somebody else
                else -> return false                 // 401 or unreachable: stop
            }
        }
        return false
    }

    /** `Identity.renamed`: the name you asked for, or why not. */
    enum class Renamed { OK, NOT_A_NAME, TAKEN, NO_ANSWER }

    /**
     * Change this phone's name. The same register call as a claim, under the
     * same key: 200 is ours, 403 belongs to somebody else, and anything else is
     * about us (a 429, a timeout) and is not a reason to think the name is gone.
     */
    fun rename(raw: String): Renamed {
        val want = raw.trim().removePrefix("@").lowercase()
        if (!handleOK(want)) return Renamed.NOT_A_NAME
        if (want == handle && claimed) return Renamed.OK
        return when (attempt(want)) {
            200 -> { handle = want; claimed = true; save()
                     android.util.Log.i("kin", "identity: you are now @$want"); Renamed.OK }
            403 -> Renamed.TAKEN
            else -> Renamed.NO_ANSWER
        }
    }

    private fun attempt(h: String): Int {
        // INTEGER seconds: the timestamp is stringified into the signed message,
        // so its spelling is part of the contract.
        val t = (System.currentTimeMillis() / 1000).toInt()
        val sig = sign("kin-reg-v1|$h|$tok|$t") ?: return 0
        val body = """{"to":"$h","tok":"$tok","k":"$publicKeyB64","t":$t,"sig":"$sig"}"""
        return post("$base/api/kin/$h/register", body)?.first ?: 0
    }

    /** Ring [to] into [room]; `kind = "bye"` cancels or declines. */
    fun ring(to: String, room: String, kind: String? = null): Boolean {
        if (!claimed) return false
        val t = (System.currentTimeMillis() / 1000).toInt()
        val sig = sign(ringMessage(to, handle, room, t, kind)) ?: return false
        val k = if (kind != null) ""","kind":"$kind"""" else ""
        val body = """{"to":"$to","from":"$handle","room":"$room","t":$t,"sig":"$sig","k":"$publicKeyB64"$k}"""
        val r = post("$base/api/kin/$to/ring", body) ?: return false
        return r.first in 200..299
    }

    /** A hang-up signs a DIFFERENT domain — new meaning, new domain. */
    private fun ringMessage(to: String, from: String, room: String, t: Int, kind: String?): String =
        if (kind == null) "kin-ring-v1|$to|$from|$room|$t" else "kin-$kind-v1|$to|$from|$room|$t"

    /** One mailbox drain. [waitMs] > 0 asks the server to hold the request. */
    fun pollOnce(waitMs: Int): PollOutcome {
        if (!claimed) return PollOutcome.Failed
        val wait = if (waitMs > 0) "&wait=$waitMs" else ""
        val timeout = if (waitMs > 0) waitMs + 10_000 else 8_000
        val (code, body) = get("$base/api/kin/$handle/poll?tok=$tok$wait", timeout)
            ?: return PollOutcome.Failed
        lastPollStatus = code
        return when (code) {
            204 -> PollOutcome.Answer(emptyList(), null, null)
            401, 403 -> PollOutcome.Refused
            429 -> PollOutcome.RateLimited
            in 200..299 -> {
                val rings = mutableListOf<Ring>()
                for (m in Regex("\\{[^{}]*\"from\"[^{}]*\\}").findAll(body)) {
                    val o = m.value
                    fun s(k: String) = Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(o)?.groupValues?.get(1)
                    fun i(k: String) = Regex("\"$k\"\\s*:\\s*(\\d+)").find(o)?.groupValues?.get(1)?.toIntOrNull()
                    val from = s("from") ?: continue
                    val room = s("room") ?: continue
                    val t = i("t") ?: continue
                    val sig = s("sig") ?: continue
                    val kb64 = s("k") ?: continue
                    val kind = s("kind")
                    // Unknown word: dropped before the signature is checked.
                    if (kind != null && kind !in ringKinds) continue
                    val sigD = b64d(sig); val pk = b64d(kb64)
                    if (sigD.size != 64 || pk.size != 32) continue
                    val ok = Ed25519.verify(pk, ringMessage(handle, from, room, t, kind).toByteArray(), sigD)
                    rings.add(Ring(from, room, t, kind, ok))
                }
                // "waitedMs" present is the server SAYING it holds — an older
                // worker ignores the parameter in silence, which is otherwise
                // indistinguishable from a fast new one.
                val holds = if (waitMs > 0) body.contains("waitedMs") else null
                val quiet = when {
                    body.contains("\"quiet\":true") -> true
                    body.contains("\"quiet\":false") -> false
                    else -> null
                }
                PollOutcome.Answer(rings, holds, quiet)
            }
            else -> PollOutcome.Failed
        }
    }

    /**
     * Silent mode, as the SERVER holds it — the Mac's `quietOn`. Cached from the
     * last answer (a set, or a poll that carried `quiet`), so the switch on the
     * front door can draw a state before anybody presses it, and persisted so a
     * cold launch draws the right one too.
     */
    @Volatile var quietOn: Boolean =
        runCatching { File(dir, "quiet").readText().trim() == "1" }.getOrDefault(false)
        private set
    /** The HTTP status of the last `setQuiet`: a 429 is "not yet", not "no". */
    @Volatile var lastQuietStatus = 0
        private set

    /** A poll said what the server believes; believe it. */
    fun noteQuiet(on: Boolean) {
        if (on == quietOn) return
        quietOn = on
        quietFile.writeText(if (on) "1" else "0")
    }
    private val quietFile get() = File(dir, "quiet")

    fun setQuiet(on: Boolean, until: Int = 0): Boolean {
        if (!claimed) { lastQuietStatus = 0; return false }
        val t = (System.currentTimeMillis() / 1000).toInt()
        val sig = sign("kin-quiet-v1|$handle|$on|$until|$t") ?: return false
        val body = """{"to":"$handle","tok":"$tok","t":$t,"sig":"$sig","quiet":$on,"until":$until}"""
        val r = post("$base/api/kin/$handle/quiet", body)
        lastQuietStatus = r?.first ?: 0
        val ok = lastQuietStatus in 200..299
        if (ok) noteQuiet(on)
        else android.util.Log.i("kin", "identity: silent mode ${if (on) "on" else "off"} refused -- $lastQuietStatus")
        return ok
    }

    fun presence(who: String): Boolean? {
        val (_, body) = get("$base/api/kin/presence?who=$who", 5000) ?: return null
        return when {
            body.contains("\"online\":true") -> true
            body.contains("\"online\":false") -> false
            else -> null
        }
    }

    // ── contacts: every value is a key somebody PROVED they held ─────────────

    fun remember(handle: String, keyB64: String) {
        val existing = contacts().toMutableMap()
        existing[handle] = keyB64
        dir.mkdirs()
        contactsFile.writeText(existing.entries.joinToString(",", "{", "}") {
            "\"${it.key}\":\"${it.value}\""
        })
    }

    fun contacts(): Map<String, String> {
        if (!contactsFile.exists()) return emptyMap()
        val t = contactsFile.readText()
        return Regex("\"([^\"]+)\"\\s*:\\s*\"([^\"]+)\"").findAll(t)
            .associate { it.groupValues[1] to it.groupValues[2] }
    }

    // ── WHO YOU TALK TO, AND WHEN YOU LAST DID ──────────────────────────────

    /** Written at every placed and every answered call. */
    fun noteCallTime(handle: String, at: Double = System.currentTimeMillis() / 1000.0) {
        if (!handleOK(handle)) return
        val map = lastCallTimes().toMutableMap()
        map[handle] = at
        dir.mkdirs()
        val tmp = File(dir, "lastcall.json.tmp")
        tmp.writeText(map.entries.sortedBy { it.key }
            .joinToString(",", "{", "}") { "\"${it.key}\":${it.value}" })
        lastCallFile.delete()
        if (!tmp.renameTo(lastCallFile)) tmp.delete()
    }

    fun lastCallTimes(): Map<String, Double> {
        if (!lastCallFile.isFile) return emptyMap()
        return Regex("\"([a-z][a-z0-9]{1,31})\"\\s*:\\s*([0-9.eE+-]+)")
            .findAll(lastCallFile.readText())
            .mapNotNull { m -> m.groupValues[2].toDoubleOrNull()?.let { m.groupValues[1] to it } }
            .toMap()
    }

    /**
     * Write down somebody we called. Idempotent, and it NEVER touches
     * contacts.json — a dialled name must not be able to become a key.
     */
    fun rememberCalled(handle: String) {
        if (!handleOK(handle)) return
        val list = called().toMutableSet()
        if (!list.add(handle)) return
        dir.mkdirs()
        calledFile.writeText(list.sorted().joinToString(",", "[", "]") { "\"$it\"" })
    }

    fun called(): List<String> {
        if (!calledFile.isFile) return emptyList()
        return Regex("\"([a-z][a-z0-9]{1,31})\"").findAll(calledFile.readText())
            .map { it.groupValues[1] }.toList()
    }

    /** Everyone this phone knows: people who proved a key, plus people we dialled. */
    fun contactHandles(): List<String> = (contacts().keys + called()).distinct()

    /**
     * The list's order: the people you actually talk to, most recent first, then
     * everyone never-timestamped, by name. An EXPLICIT tiebreak, because an
     * order that changes between two launches over identical data reads as the
     * app forgetting you.
     */
    fun contactHandlesByRecency(): List<String> {
        val t = lastCallTimes()
        return contactHandles().sortedWith(Comparator { x, y ->
            val a = t[x] ?: 0.0
            val b = t[y] ?: 0.0
            if (a == b) x.compareTo(y) else b.compareTo(a)
        })
    }

    private fun sign(msg: String): String? = try {
        b64e(Ed25519.sign(seed, msg.toByteArray()))
    } catch (e: Exception) { null }

    // ── http ─────────────────────────────────────────────────────────────────

    private fun post(url: String, json: String): Pair<Int, String>? = try {
        val c = URL(url).openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.setRequestProperty("content-type", "application/json")
        c.doOutput = true
        c.connectTimeout = 8000; c.readTimeout = 8000; c.useCaches = false
        c.outputStream.use { it.write(json.toByteArray()) }
        val code = c.responseCode
        val body = (if (code in 200..299) c.inputStream else c.errorStream)
            ?.bufferedReader()?.readText() ?: ""
        code to body
    } catch (e: Exception) { null }

    private fun get(url: String, timeout: Int): Pair<Int, String>? = try {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 8000; c.readTimeout = timeout; c.useCaches = false
        val code = c.responseCode
        val body = (if (code in 200..299) c.inputStream else c.errorStream)
            ?.bufferedReader()?.readText() ?: ""
        code to body
    } catch (e: Exception) { null }

    companion object {
        /** `Identity.display`: "meera" → "Meera". The card's register, never the row's. */
        fun display(handle: String): String =
            if (handle.isEmpty()) handle else handle.substring(0, 1).uppercase() + handle.substring(1)

        fun b64e(b: ByteArray): String = java.util.Base64.getEncoder().encodeToString(b)
        fun b64d(s: String): ByteArray = try { java.util.Base64.getDecoder().decode(s) }
            catch (e: Exception) { ByteArray(0) }
        private fun field(json: String, k: String) =
            Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(json)?.groupValues?.get(1)
    }
}
