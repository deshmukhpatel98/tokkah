package com.tokkah.kin

import com.tokkah.kin.net.Faces
import com.tokkah.kin.net.Identity
import com.tokkah.kin.net.Presence
import com.tokkah.kin.net.Relative
import com.tokkah.kin.net.RingWatcher
import com.tokkah.kin.ui.CallCardMode
import com.tokkah.kin.ui.Person
import java.io.File
import kotlin.concurrent.thread
import kotlin.random.Random

/**
 * The front door's own state: who you know, who is reachable, and whether
 * anything is ringing. Kept out of the composable so the poll loop and the
 * presence refresh are not tied to a recomposition.
 *
 * A ring is a PERSON and a room: the room is minted by whoever places the call
 * and travels inside the signed ring, so the two ends never have to agree on a
 * word out of band.
 */
class KinState(root: File) {
    val identity = Identity(File(root, "kin"))
    val faces = Faces(File(root, "kin"))
    val watcher = RingWatcher(identity)
    val resume = com.tokkah.kin.net.Resume(File(root, "kin"))

    /** A call this phone never hung up on. Read once, at the front door. */
    @Volatile var pending: com.tokkah.kin.net.Resume.Live? = null

    val updater = com.tokkah.kin.net.Update(File(File(root, "kin").parentFile, "cache"))
    @Volatile var ready: com.tokkah.kin.net.Update.Release? = null
    @Volatile var readyFile: File? = null
    /** True while a call is running: an update never interrupts one. */
    @Volatile var inCall = false

    @Volatile var people: List<Person> = emptyList()
    @Volatile var incoming: Identity.Ring? = null
    @Volatile var outgoingTo: String? = null
    @Volatile var outgoingRoom: String? = null
    @Volatile var cardMode: CallCardMode = CallCardMode.INVITE
    @Volatile var cardLine: String? = null
    @Volatile var cardBecause: String? = null

    var onChanged: (() -> Unit)? = null
    /** Somebody answered, or we answered: go to the call in this room. */
    var onCall: ((room: String, who: String) -> Unit)? = null

    private var ringTimeoutAt = 0L

    fun start() {
        watcher.onRing = { r ->
            // A ring that arrives while we are already showing one is not a
            // second card: the first one is still the call being offered.
            if (incoming == null && cardMode != CallCardMode.RINGING) {
                incoming = r
                cardMode = CallCardMode.RINGING
                cardLine = null; cardBecause = null
                onChanged?.invoke()
            }
        }
        watcher.onBye = { r ->
            // They hung up before we answered, or declined our call.
            if (incoming?.from == r.from) {
                incoming = null
                cardMode = CallCardMode.INVITE
                onChanged?.invoke()
            } else if (outgoingTo == r.from) {
                failCall("@${r.from} declined", "maybe later")
            }
        }
        // A call ends when a human hangs up — so one that is still on disk is
        // still on, whatever happened to the process that was in it.
        pending = resume.pending()
        watcher.start()
        refresh()
        checkForUpdate()
    }

    fun stop() = watcher.stop()

    /**
     * Look for a newer build, verify it, and install it — every 30 minutes,
     * the Mac's own cadence, for the lifetime of the app.
     *
     * DEFERRED WHILE IN A CALL, always: an update that interrupts the thing the
     * app exists to do is worse than an update that waits half an hour.
     *
     * Where this copy is its own installer of record it replaces itself with no
     * prompt at all, which is the Mac's promise — download once and never think
     * about it again. Where it cannot, the row on the front door is the one tap,
     * and that difference is stated rather than hidden.
     */
    fun checkForUpdate(installed: String = com.tokkah.kin.net.Telemetry.VERSION) {
        if (updateThread != null) return
        updateThread = thread(isDaemon = true, name = "kin-update") {
            while (true) {
                runCatching { updateOnce(installed) }
                Thread.sleep(CHECK_EVERY_MS)
            }
        }
    }

    private var updateThread: Thread? = null
    var onInstall: ((java.io.File) -> Unit)? = null

    private fun updateOnce(installed: String) {
        // Never mid-call, and never while a call is being offered either: a
        // process replaced under a ringing phone is a missed call.
        if (inCall || cardMode != CallCardMode.INVITE) {
            android.util.Log.i("kin", "update: deferred, in a call")
            return
        }
        val r = updater.check()
        if (r == null) {
            android.util.Log.i("kin", "update: no release (${updater.lastError})")
            return
        }
        if (!updater.isNewer(r, installed)) {
            android.util.Log.i("kin", "update: ${r.version} is not newer than $installed")
            return
        }
        android.util.Log.i("kin", "update: ${r.version} is newer than $installed, fetching")
        if (readyFile?.name?.contains(r.version) == true) { offerInstall(); return }
        val f = updater.download(r)
        if (f == null) {
            android.util.Log.i("kin", "update: download failed (${updater.lastError})")
            return
        }
        android.util.Log.i("kin", "update: staged ${f.name}, ${f.length()} bytes")
        ready = r
        readyFile = f
        onChanged?.invoke()
        offerInstall()
    }

    private fun offerInstall() {
        val f = readyFile ?: return
        if (inCall || cardMode != CallCardMode.INVITE) return
        onInstall?.invoke(f)
    }

    /** The UI is listening for changes; publish what we already know. */
    fun onChangedReady() { onChanged?.invoke() }

    /** The people panel: known handles, most recent first, with faces and dots. */
    fun refresh() {
        thread(isDaemon = true) {
            if (!identity.claimed) identity.claim(android.os.Build.MODEL ?: "kin")
            val times = identity.lastCallTimes()
            val handles = identity.contactHandlesByRecency()
            var list = handles.map {
                Person(it, lastSeen = times[it]?.let { t -> Relative.time(t) },
                    face = faces.path(it))
            }
            people = list
            onChanged?.invoke()
            // Presence paints a dot and REORDERS NOTHING.
            val here = Presence.fetch(handles)
            people = list.map { Person(it.handle, here[it.handle] == true, it.lastSeen, it.face) }
            onChanged?.invoke()
        }
    }

    /** Place a call: mint the room, ring them, and wait. */
    fun call(who: String) {
        val handle = who.removePrefix("@").lowercase()
        if (!identity.handleOK(handle)) return
        val room = mintRoom()
        outgoingTo = handle
        outgoingRoom = room
        cardMode = CallCardMode.CALLING
        cardLine = null; cardBecause = null
        ringTimeoutAt = System.currentTimeMillis() + RING_TIMEOUT_MS
        onChanged?.invoke()
        thread(isDaemon = true) {
            // Warm the room while the ring travels, never before it: warming is
            // itself a stateful hop, and spending it in front of the ring moves
            // the delay onto the callee's phone instead of removing it.
            com.tokkah.kin.net.Rendezvous.warm(room)
            val sent = identity.ring(handle, room)
            if (!sent) {
                failCall("Could not reach @$handle", "they may not have Kin yet")
                return@thread
            }
            identity.rememberCalled(handle)
            identity.noteCallTime(handle)
            // Join our own end immediately: the call exists from here on, and
            // their answering is them arriving in it.
            onCall?.invoke(room, handle)
            while (outgoingTo == handle && System.currentTimeMillis() < ringTimeoutAt) {
                Thread.sleep(250)
            }
            if (outgoingTo == handle && cardMode == CallCardMode.CALLING) {
                // Not an error — a person who was not at their phone.
                failCall("@$handle didn’t answer", "they might be away")
            }
        }
    }

    /** They picked up (or we joined): the card's work is done. */
    fun forgetPending() {
        pending = null
        resume.end()
        onChanged?.invoke()
    }

    fun answered() {
        outgoingTo = null
        incoming = null
        cardMode = CallCardMode.INVITE
        cardLine = null; cardBecause = null
        onChanged?.invoke()
    }

    fun answerIncoming() {
        val r = incoming ?: return
        incoming = null
        cardMode = CallCardMode.INVITE
        identity.rememberCalled(r.from)
        identity.noteCallTime(r.from)
        onChanged?.invoke()
        onCall?.invoke(r.room, r.from)
    }

    /** A decline is a signed `bye`, not silence. */
    fun declineIncoming() {
        val r = incoming ?: return
        incoming = null
        cardMode = CallCardMode.INVITE
        onChanged?.invoke()
        thread(isDaemon = true) { identity.ring(r.from, r.room, kind = "bye") }
    }

    /** A ring in flight has a way out. */
    fun cancelOutgoing() {
        val who = outgoingTo
        val room = outgoingRoom
        outgoingTo = null
        cardMode = CallCardMode.INVITE
        cardLine = null; cardBecause = null
        onChanged?.invoke()
        if (who != null && room != null) {
            thread(isDaemon = true) { identity.ring(who, room, kind = "bye") }
        }
    }

    fun callAgain() {
        val who = outgoingTo ?: cardLine?.substringAfter("@")?.substringBefore(" ") ?: return
        call(who)
    }

    private fun failCall(line: String, why: String) {
        cardMode = CallCardMode.NO_ANSWER
        cardLine = line
        cardBecause = why
        onChanged?.invoke()
    }

    /** The same shape the Mac mints: three words a person can say out loud. */
    private fun mintRoom(): String {
        val w = WORDS
        return "${w.random()}-${w.random()}-${Random.nextInt(10, 99)}"
    }

    companion object {
        const val RING_TIMEOUT_MS = 30_000L
        /** The Mac's cadence, for the same reason: often enough to matter, rare
         *  enough to be free on somebody else's battery and data. */
        const val CHECK_EVERY_MS = 30L * 60 * 1000
        private val WORDS = listOf(
            "amber", "basil", "cedar", "delta", "ember", "fable", "grove", "hazel",
            "indigo", "jasper", "kite", "lilac", "mango", "nectar", "olive", "pearl",
            "quartz", "raven", "sage", "tulip", "umber", "violet", "willow", "yarrow",
        )
    }
}
