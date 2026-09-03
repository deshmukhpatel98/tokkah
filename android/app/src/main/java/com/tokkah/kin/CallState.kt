package com.tokkah.kin

import com.tokkah.kin.net.Faces
import com.tokkah.kin.net.Identity
import com.tokkah.kin.net.Presence
import com.tokkah.kin.net.Relative
import com.tokkah.kin.net.RingWatcher
import com.tokkah.kin.ui.CallCardMode
import com.tokkah.kin.ui.Person
import java.io.File
import java.security.SecureRandom
import kotlin.concurrent.thread

/**
 * The front door's own state: who you know, who is reachable, and whether
 * anything is ringing. Kept out of the composable so the poll loop and the
 * presence refresh are not tied to a recomposition.
 *
 * A ring is a PERSON and a room: the room is minted by whoever places the call
 * and travels inside the signed ring, so the two ends never have to agree on a
 * word out of band.
 *
 * Everything the Mac's `home()` (Launcher.swift) keeps in its `Target` lives
 * here: the field's verdict, the clipboard's room, the invite that was minted,
 * the two-second "copied", and the one switch.
 */
class KinState(
    root: File,
    private val installedVersion: String = "0",
    /**
     * Only ever used to make a noise. A ring that arrives while Kin is OPEN
     * never reaches RingService — the mailbox hands over to the activity at
     * ON_START — so without this the in-app ring was the one that stayed
     * silent, which is the opposite of the case that needs the sound least.
     */
    private val ctx: android.content.Context? = null,
) {
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
    /** [key] is the identity the call's handshake must present (base64), or null. */
    var onCall: ((room: String, who: String, key: String?) -> Unit)? = null

    private var ringTimeoutAt = 0L

    /**
     * Show a call being offered. From the in-app poll, or from the service
     * that opened this screen for it (the Mac's `gOffered`: one variable, two
     * routes in, one Answer button that works for both).
     */
    fun offer(r: Identity.Ring) {
        // A ring that arrives while we are already showing one is not a
        // second card: the first one is still the call being offered.
        if (incoming == null && cardMode != CallCardMode.RINGING) {
            incoming = r
            cardMode = CallCardMode.RINGING
            cardLine = null; cardBecause = null
            ctx?.let { Ringer.start(it) }
            onChanged?.invoke()
            // A ring that lands in THIS poller a moment after the window went
            // behind (the poll in flight when ON_STOP hit) would draw the card
            // where nobody can see it and ring on. The Mac's window rises for a
            // ring; so does this one, by the same grant the service uses.
            if (!RingService.appInFront) ctx?.let { c ->
                if (RingService.canOpenOverOthers(c)) c.startActivity(
                    android.content.Intent(c, MainActivity::class.java).apply {
                        flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP
                    },
                )
            }
        }
    }

    fun start() {
        watcher.onRing = { r -> offer(r) }
        watcher.onBye = { r ->
            // They hung up before we answered, or declined our call.
            if (incoming?.from == r.from) {
                incoming = null
                cardMode = CallCardMode.INVITE
                Ringer.stop()
                onChanged?.invoke()
            } else if (outgoingTo == r.from) {
                failCall("${Identity.display(r.from)} declined", "maybe later")
            }
        }
        // The server's word on silent mode arrives with every poll; the
        // switch draws it.
        watcher.onQuiet = { if (!reachBusy) onChanged?.invoke() }
        // A call ends when a human hangs up — so one that is still on disk is
        // still on, whatever happened to the process that was in it.
        pending = resume.pending()
        watcher.start()
        refresh()
        startPresenceRefresh()
        checkForUpdate()
        // The Mac checks when it is opened; the poll below is for the hours
        // it stays open.
        updateNow("Kin opened")
    }

    fun stop() {
        watcher.stop()
        presenceGen++
    }

    // ── THE GREEN DOTS, REFRESHED WHILE THE WINDOW IS OPEN (Launcher 796-815) ─
    private var presenceGen = 0
    private fun startPresenceRefresh() {
        val gen = ++presenceGen
        thread(isDaemon = true, name = "kin-presence") {
            while (gen == presenceGen) {
                Thread.sleep(15_000)
                if (gen != presenceGen) break
                val list = people
                if (list.isEmpty()) continue
                val here = Presence.fetch(list.map { it.handle })
                if (gen != presenceGen) break
                // Presence paints a dot and REORDERS NOTHING.
                people = list.map { Person(it.handle, here[it.handle] == true, it.lastSeen, it.face) }
                onChanged?.invoke()
            }
        }
    }

    // ── UPDATES ─────────────────────────────────────────────────────────────

    /**
     * Look for a newer build, verify it, and install it — every 60 s, the
     * Mac's cadence (`TK_UPDATE_POLL` defaults to 60), plus a check when Kin
     * is opened and when a call starts. The half-hour poll this replaced was
     * the bug `update-poll-was-half-an-hour` records: "updates not working".
     *
     * The DOWNLOAD may happen during a call; the INSTALL never does — an
     * update that interrupts the thing the app exists to do is worse than one
     * that waits. `ready` is set the moment the bytes are verified, so a call
     * can say "update ready — restarts when the call ends" the way the Mac's
     * status pill does.
     *
     * Where this copy is its own installer of record it replaces itself with no
     * prompt at all, which is the Mac's promise — download once and never think
     * about it again. Where it cannot, the row on the front door is the one tap,
     * and that difference is stated rather than hidden.
     */
    fun checkForUpdate(installed: String = installedVersion) {
        if (updateThread != null) return
        updateThread = thread(isDaemon = true, name = "kin-update") {
            while (true) {
                Thread.sleep(CHECK_EVERY_MS)
                runCatching { updateOnce(installed) }
            }
        }
    }

    /** One check now, off the caller's thread, if none is already running. */
    fun updateNow(why: String) {
        if (updateChecking) return
        android.util.Log.i("kin", "update: checking now -- $why")
        thread(isDaemon = true, name = "kin-update-now") { runCatching { updateOnce(installedVersion) } }
    }

    private var updateThread: Thread? = null
    @Volatile private var updateChecking = false
    var onInstall: ((java.io.File) -> Unit)? = null

    private fun updateOnce(installed: String) {
        if (updateChecking) return
        updateChecking = true
        try {
            val r = updater.check()
            if (r == null) {
                android.util.Log.i("kin", "update: no release (${updater.lastError})")
                return
            }
            if (!updater.isNewer(r, installed)) return
            if (readyFile?.name?.contains(r.version) == true) { offerInstall(); return }
            android.util.Log.i("kin", "update: ${r.version} is newer than $installed, fetching")
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
        } finally { updateChecking = false }
    }

    private var offeredFile: String? = null
    private var offeredAt = 0L

    private fun offerInstall() {
        val f = readyFile ?: return
        // Never mid-call, and never while a call is being offered either: a
        // process replaced under a ringing phone is a missed call.
        if (inCall || cardMode != CallCardMode.INVITE) {
            android.util.Log.i("kin", "update: ready, deferred until the call ends")
            return
        }
        // ONE offer per staged file, then a long pause: the minute poll offered
        // the same APK again while the first session was waiting on the
        // person's tap, and the system refused BOTH --
        // INSTALL_FAILED_VERIFICATION_FAILURE, seen live on the emulator.
        val now = System.currentTimeMillis()
        if (offeredFile == f.name && now - offeredAt < 10 * 60 * 1000) {
            android.util.Log.i("kin", "update: ${f.name} already offered; not again yet")
            return
        }
        offeredFile = f.name; offeredAt = now
        onInstall?.invoke(f)
    }

    /**
     * The call ended: the promise "update ready — restarts when the call ends"
     * is kept HERE. Until this existed the install was offered only by the
     * poll that found the update, which had already run and been refused for
     * being mid-call — a deferral with nothing to resume it.
     */
    fun callEnded() {
        inCall = false
        if (readyFile != null) thread(isDaemon = true) { Thread.sleep(400); offerInstall() }
    }

    /** The UI is listening for changes; publish what we already know. */
    fun onChangedReady() { onChanged?.invoke() }

    // ── THE PEOPLE ──────────────────────────────────────────────────────────

    /** The people panel: known handles, most recent first, with faces and dots. */
    fun refresh() {
        thread(isDaemon = true) {
            if (!identity.claimed) identity.claim(android.os.Build.MODEL ?: "kin")
            val times = identity.lastCallTimes()
            // Five, by recency, the Mac's own cap for the front card.
            val handles = identity.contactHandlesByRecency().take(5)
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

    /** Take somebody off the list. Their key is kept; a new call brings them back. */
    fun remove(handle: String) {
        if (cardMode == CallCardMode.CALLING) return
        identity.hide(handle)
        people = people.filter { it.handle != handle }
        com.tokkah.kin.net.Metrics.tap("home_remove")
        android.util.Log.i("kin", "home: removed @$handle")
        onChanged?.invoke()
    }

    // ── THE ONE FIELD ───────────────────────────────────────────────────────

    /** What the field decided. The Mac's `Intent`, minus the window closing. */
    sealed class Verdict {
        class Room(val name: String) : Verdict()
        class Ring(val handle: String) : Verdict()
        class Say(val status: String) : Verdict()
    }

    /**
     * Return in the one field — `Target.commit`. What was typed decides what
     * happens: a call link joins its room, a word with `-` or `_` (every
     * suggested room, and no legal handle) joins as a room, and anything else
     * is a name to ring. The messages are the Mac's, word for word.
     */
    fun commit(raw0: String): Verdict {
        val raw = raw0.trim()
        if (raw.isEmpty()) return Verdict.Say("Type a name, or paste a call link.")
        roomFromLink(raw)?.let { return Verdict.Room(it) }
        if (raw.contains("-") || raw.contains("_")) {
            return validateRoom(raw)?.let { Verdict.Room(it) }
                ?: Verdict.Say(if (raw.length > 64 || !raw.all { it.isLetterOrDigit() || it == '-' || it == '_' })
                    "Letters, numbers, - and _ only." else "Type a room name.")
        }
        val bare = raw.removePrefix("@").lowercase()
        if (!identity.handleOK(bare)) return Verdict.Say("Names are letters and numbers, starting with a letter.")
        if (bare == identity.handle) return Verdict.Say("That’s you.")
        return Verdict.Ring(bare)
    }

    /** Refuse rather than normalise: the room name is the rendezvous key AND the salt. */
    private fun validateRoom(raw: String): String? {
        val name = raw.trim()
        if (name.isEmpty() || name.length > 64) return null
        if (!name.all { it.isLetterOrDigit() || it == '-' || it == '_' }) return null
        return name
    }

    // ── THE CLIPBOARD ───────────────────────────────────────────────────────

    /** The room parsed off the clipboard, when the clipboard holds a call link. */
    @Volatile var clipRoom: String? = null

    /**
     * A link on the clipboard is a knock on the door. Checked when the window
     * comes forward, which is the only moment the copy could have changed.
     * The row names the room it would join; what fires is what was on screen.
     */
    fun scanClipboard(text: String?) {
        if (cardMode == CallCardMode.CALLING) return
        val room = text?.let { roomFromLink(it) }
        if (room == clipRoom) return
        clipRoom = room
        android.util.Log.i("kin", "home: clipboard link ${room ?: "none"}")
        onChanged?.invoke()
    }

    // ── THE INVITE, AND YOUR OWN NAME ───────────────────────────────────────

    /** One room per visit to this screen: pressing copy twice hands out the same link. */
    private var invited: String? = null
    @Volatile var inviteLabel = "Copy a link to invite someone"
    @Volatile var inviteValue = "copy"
    @Volatile var mineValue = "copy"

    /**
     * Mint a room, put its link on the clipboard, and stay on this screen —
     * `Target.copyInvite`. Returns the link so the caller can set the clipboard.
     * Warmed now: the link is out in the world and the room's first request is
     * the ~1100 ms one.
     */
    fun invite(): String {
        val room = invited ?: mintRoom()
        invited = room
        com.tokkah.kin.net.Rendezvous.warm(room)
        inviteLabel = "Link copied — send it to anyone"
        inviteValue = room
        onChanged?.invoke()
        revert(4000) {
            inviteLabel = "Copy a link to invite someone"
            inviteValue = "copy"
        }
        android.util.Log.i("kin", "home: invite link copied for $room")
        return "${com.tokkah.kin.net.Server.invite}/$room"
    }

    /** `Target.copyMine`: the word is a receipt for one press, so it reverts. */
    fun copiedMine() {
        mineValue = "copied"
        onChanged?.invoke()
        revert(2000) { mineValue = "copy" }
    }

    private var revertGen = 0
    private fun revert(afterMs: Long, then: () -> Unit) {
        val gen = ++revertGen
        thread(isDaemon = true) {
            Thread.sleep(afterMs)
            if (gen == revertGen) { then(); onChanged?.invoke() }
        }
    }

    // ── ONE SWITCH: "PEOPLE CAN CALL ME" ────────────────────────────────────
    //
    // Two mechanisms, one question. Whether a call MAY reach this phone is a
    // server flag (silent mode); whether it CAN with Kin closed is the
    // listening service and the notification permission it needs. Three honest
    // states, the Mac's:
    //
    //   on              silence lifted AND listening
    //   only when open  silence lifted, not listening — named, because it is
    //                   the state somebody would otherwise read as "on"
    //   off             silenced at the server
    //
    // The rate limit is part of this feature: a press that looks like it did
    // nothing gets pressed again, and pressing again is what guarantees the
    // 429 keeps coming. `reachBusy` refuses the second press, the sentence
    // says which failure this is, and a 429 retries itself once.

    /** Whether the phone is listening (service up, permission granted). Set by the UI. */
    @Volatile var listening = false
    @Volatile var reachBusy = false; private set
    @Volatile var reachTrouble: String? = null; private set
    /** null while busy; otherwise the switch position. */
    val reachOn: Boolean? get() = if (reachBusy) null else !identity.quietOn
    val reachHint: String get() = reachTrouble
        ?: if (!identity.quietOn && !listening)
            "Only while Kin is open. Allow Kin to show over other apps so a call can reach you when it’s closed."
        else ""

    /** Start listening. Returns false when a permission has to be asked first. */
    var listenOn: (() -> Boolean)? = null
    var listenOff: (() -> Unit)? = null

    /** The press: the other way from wherever it is now. */
    fun toggleReach() {
        if (reachBusy || cardMode == CallCardMode.CALLING) return
        attemptReach(turningOn = identity.quietOn)
    }

    private var retryGen = 0
    private fun attemptReach(turningOn: Boolean) {
        if (reachBusy) return
        reachBusy = true
        reachTrouble = null
        retryGen++
        onChanged?.invoke()
        thread(isDaemon = true, name = "kin-reach") {
            // The listening half first: with the silence lifted and no way to
            // hear a ring, "on" would be a lie for every moment Kin is not open.
            if (turningOn) listening = listenOn?.invoke() ?: false
            val ok = identity.setQuiet(!turningOn)
            val status = identity.lastQuietStatus
            if (!ok) {
                reachTrouble = if (status == 429) "Too many changes at once — trying again in a moment."
                               else "Couldn’t reach the server — nothing changed."
            } else if (!turningOn) {
                // Off means off: a "Kin is listening" notification while
                // nobody can call you is a notification that lies.
                listenOff?.invoke(); listening = false
            }
            reachBusy = false
            val on = !identity.quietOn
            com.tokkah.kin.net.Metrics.tap(if (turningOn) "reach_on" else "reach_off", ok = ok && on == turningOn)
            android.util.Log.i("kin", "home: people-can-call-me asked ${if (turningOn) "on" else "off"}," +
                " now ${if (on) (if (listening) "on" else "only-when-open") else "off"} quiet_http=$status")
            onChanged?.invoke()
            // A 429 is a "not yet", not a "no". One retry, after the window.
            if (!ok && status == 429) {
                val gen = retryGen
                Thread.sleep(12_000)
                if (gen == retryGen) attemptReach(turningOn)
            }
        }
    }

    /** The permission came back granted after a press: finish the "on". */
    fun listeningGranted() {
        listening = true
        onChanged?.invoke()
    }

    // ── PLACING AND TAKING CALLS ────────────────────────────────────────────

    /** Place a call: mint the room, ring them, and wait. */
    fun call(who: String) {
        val handle = who.removePrefix("@").lowercase()
        if (!identity.handleOK(handle)) return
        if (cardMode == CallCardMode.CALLING) return
        val room = mintRoom()
        outgoingTo = handle
        outgoingRoom = room
        cardMode = CallCardMode.CALLING
        cardLine = null; cardBecause = null
        ringTimeoutAt = System.currentTimeMillis() + RING_TIMEOUT_MS
        com.tokkah.kin.net.Metrics.fact("outcome", "calling")
        onChanged?.invoke()
        thread(isDaemon = true) {
            // ── ASK BEFORE RINGING (Launcher.swift `t.ring`) ────────────────
            //
            // A name typed wrong used to ring forever: the server accepted it,
            // the card said "Calling @meeraa" for as long as anyone watched.
            // Presence now says whether the name is CLAIMED, and whether their
            // Kin is awake — the first is a refusal in the Mac's words, the
            // second only a sentence, because a sleeping Mac is still rung.
            val pre = Presence.ask(handle)
            if (outgoingTo != handle) return@thread          // cancelled while asking
            if (pre.registered == false) {
                com.tokkah.kin.net.Metrics.count("ring_unregistered")
                failCall("Nobody has the name ${Identity.display(handle)} on Kin yet", "check the spelling")
                return@thread
            }
            if (pre.here == false) {
                cardLine = "${Identity.display(handle)}’s Mac is off right now — ringing it anyway"
                onChanged?.invoke()
            }
            // Warm the room while the ring travels, never before it: warming is
            // itself a stateful hop, and spending it in front of the ring moves
            // the delay onto the callee's phone instead of removing it.
            com.tokkah.kin.net.Rendezvous.warm(room)
            com.tokkah.kin.net.Metrics.count("ring_sent_try")
            val sent = identity.ring(handle, room)
            if (outgoingTo != handle) return@thread
            if (!sent) {
                com.tokkah.kin.net.Metrics.count("ring_sent_fail")
                failCall("Couldn’t reach ${Identity.display(handle)}", "check the name, and try again")
                return@thread
            }
            com.tokkah.kin.net.Metrics.count("ring_sent_ok")
            cardLine = null
            onChanged?.invoke()
            identity.rememberCalled(handle)
            identity.noteCallTime(handle)
            // Join our own end immediately: the call exists from here on, and
            // their answering is them arriving in it.
            // The key the server bound @handle to at registration, returned with
            // the ring; the pinned key from a previous call otherwise.
            onCall?.invoke(room, handle, identity.lastRingPeerKey ?: identity.contacts()[handle])
            while (outgoingTo == handle && System.currentTimeMillis() < ringTimeoutAt) {
                Thread.sleep(250)
            }
            if (outgoingTo == handle && cardMode == CallCardMode.CALLING) {
                // Not an error — a person who was not at their phone.
                com.tokkah.kin.net.Metrics.count("ring_timed_out")
                com.tokkah.kin.net.Metrics.fact("outcome", "no answer")
                failCall("${Identity.display(handle)} didn’t answer", "they might be away")
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
        Ringer.stop()
        outgoingTo = null
        incoming = null
        cardMode = CallCardMode.INVITE
        cardLine = null; cardBecause = null
        // A new visit to the front door mints a new invite.
        invited = null
        onChanged?.invoke()
    }

    fun answerIncoming() {
        Ringer.stop()
        val r = incoming ?: return
        incoming = null
        cardMode = CallCardMode.INVITE
        identity.rememberCalled(r.from)
        identity.noteCallTime(r.from)
        // Bind the name to the key that rang -- on ANSWER, not on arrival, or
        // anyone who rings once would own the name (Identity.swift `remember`).
        if (r.k.isNotEmpty()) identity.remember(r.from, r.k)
        onChanged?.invoke()
        onCall?.invoke(r.room, r.from, r.k.ifEmpty { null })
    }

    /** A decline is a signed `bye`, not silence. */
    fun declineIncoming() {
        Ringer.stop()
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

    private var lastCalled: String? = null
    fun callAgain() {
        val who = outgoingTo ?: lastCalled ?: return
        outgoingTo = null
        call(who)
    }

    private fun failCall(line: String, why: String) {
        lastCalled = outgoingTo
        cardMode = CallCardMode.NO_ANSWER
        cardLine = line
        cardBecause = why
        onChanged?.invoke()
    }

    companion object {
        /** The Mac's `WaitingCard.startRingTimeout`: 45 s. */
        const val RING_TIMEOUT_MS = 45_000L
        /** The Mac's `TK_UPDATE_POLL` default: once a minute. */
        const val CHECK_EVERY_MS = 60_000L

        /**
         * `xxx-xxxx-xxx`, lowercase, exactly as `Launcher.mintRoom()` does it:
         * 26^10 ≈ 47 bits, the same budget Meet spends, and short enough to read
         * down a phone. One shape for both apps, because the shape is what
         * `commit` uses to tell a room from a name.
         */
        fun mintRoom(): String {
            val b = ByteArray(10).also { SecureRandom().nextBytes(it) }
            val c = b.map { ('a' + ((it.toInt() and 0xff) % 26)) }.joinToString("")
            return c.substring(0, 3) + "-" + c.substring(3, 7) + "-" + c.substring(7, 10)
        }

        /**
         * `Launcher.roomFromLink`: tokkah://join/<room>, tokkah://<room>,
         * kin://…, and the https links people actually send each other
         * (kin.tokkah.com/<room>, room.tokkah.com/<room>, with or without the
         * scheme typed). Anything else is not a link.
         */
        fun roomFromLink(s: String): String? {
            val raw = s.trim()
            val lower = raw.lowercase()
            if (!lower.contains("://") && !lower.contains("tokkah.com")) return null
            val u = runCatching { java.net.URI(if (raw.contains("://")) raw else "https://$raw") }.getOrNull()
                ?: return null
            var name = (u.path ?: "").removePrefix("/")
            val scheme = u.scheme?.lowercase()
            if (scheme == "tokkah" || scheme == "kin") {
                if (name.isEmpty()) name = u.host ?: ""
                if (name == "join") name = ""
            } else {
                val h = u.host?.lowercase() ?: return null
                if (h != "tokkah.com" && !h.endsWith(".tokkah.com")) return null
            }
            val ok = name.isNotEmpty() && name.length <= 64 &&
                name.all { it.isLetterOrDigit() || it == '-' || it == '_' }
            return if (ok) name else null
        }
    }
}
