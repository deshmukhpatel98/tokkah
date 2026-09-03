package com.tokkah.kin

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Bundle
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import com.tokkah.kin.net.CallSession
import com.tokkah.kin.net.Floor
import com.tokkah.kin.net.Metrics
import com.tokkah.kin.net.Identity
import com.tokkah.kin.net.Server
import com.tokkah.kin.ui.CallScreen
import com.tokkah.kin.ui.HomeScreen
import com.tokkah.kin.ui.Palette
import com.tokkah.kin.ui.Person
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** Rig overrides read off the launch intent. Empty on every real launch. */
private val rigFlags = HashMap<String, Boolean>()
private var rigSaid: String? = null

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The picture goes edge to edge; the card floats over it.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        // A ring notification carries the call it is about, so answering from
        // the lock screen lands in that call rather than at the front door.
        val fromRing = intent?.getStringExtra(RingService.EXTRA_ROOM)
        val ringWho = intent?.getStringExtra(RingService.EXTRA_FROM) ?: ""
        // A ring opened directly by the service (no notification) must still
        // come up over the lock screen and light it, as the Mac's window does.
        if (ringWho.isNotEmpty() && android.os.Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true); setTurnScreenOn(true)
        }
        val ringKey = intent?.getStringExtra(RingService.EXTRA_KEY)
        val ringOffer = intent?.getBooleanExtra(RingService.EXTRA_OFFER, false) == true
        val deep = fromRing ?: intent?.data?.let { u ->
            (u.pathSegments?.lastOrNull() ?: u.host)?.takeIf { it.isNotBlank() }
        }
        // ── RIG ARMS, FROM THE LAUNCH INTENT ────────────────────────────────
        //
        // Every production cadence and every default gets an override the
        // harness can set, because an A/B that needs a rebuild between arms is
        // an A/B nobody runs twice. Read here and NOT from a build flag, so the
        // arms are the same binary — a rebuild between arms is a second
        // variable.
        for (k in listOf("turn", "decodeq")) {
            intent?.getStringExtra(k)?.let { rigFlags[k] = it == "1" || it == "true" }
        }
        run {
            rigSaid = intent?.getStringExtra("said")?.takeIf { it.isNotBlank() }
        }
        RingService.channels(this)
        // An unexplained death is a bug, and one nobody is told about is not
        // even that: book the last run's death, then arm the handler for this one.
        val kinDir = filesDir.resolve("kin")
        val ver = runCatching { packageManager.getPackageInfo(packageName, 0).versionName ?: "0" }.getOrDefault("0")
        Thread { runCatching { com.tokkah.kin.net.Crash.reportPrevious(kinDir, com.tokkah.kin.net.Telemetry(kinDir)) } }
            .apply { isDaemon = true }.start()
        com.tokkah.kin.net.Crash.arm(kinDir, ver)
        setContent { KinApp(deep, if (fromRing != null) ringWho else "", if (fromRing != null) ringKey else null, ringOffer) }
    }
}

@Composable
fun KinApp(initialRoom: String?, ringWho: String = "", ringKey: String? = null, ringOffer: Boolean = false) {
    val ctx = LocalContext.current
    var room by remember { mutableStateOf(if (ringWho.isEmpty()) initialRoom ?: "" else "") }
    var session by remember { mutableStateOf<CallSession?>(null) }
    var audio by remember { mutableStateOf<AudioDevice?>(null) }
    var video by remember { mutableStateOf<VideoDevice?>(null) }
    var settingsOpen by remember { mutableStateOf(false) }
    var cameraHint by remember { mutableStateOf<String?>(null) }
    var myHandle by remember { mutableStateOf("") }
    var people by remember { mutableStateOf(listOf<Person>()) }
    // Mirrored into Compose state, not read off the state object: a @Volatile
    // field is invisible to the snapshot system, so the card set by the poll
    // thread never recomposed anything and a real ring drew nothing.
    var cardMode by remember { mutableStateOf(com.tokkah.kin.ui.CallCardMode.INVITE) }
    var cardWho by remember { mutableStateOf("") }
    var cardLine by remember { mutableStateOf<String?>(null) }
    var cardBecause by remember { mutableStateOf<String?>(null) }
    var resumeRoom by remember { mutableStateOf<String?>(null) }
    var resumeWho by remember { mutableStateOf("") }
    var updateVersion by remember { mutableStateOf<String?>(null) }
    var clipRoom by remember { mutableStateOf<String?>(null) }
    var inviteLabel by remember { mutableStateOf("Copy a link to invite someone") }
    var inviteValue by remember { mutableStateOf("copy") }
    var mineValue by remember { mutableStateOf("copy") }
    var fieldStatus by remember { mutableStateOf("") }
    var reachOn by remember { mutableStateOf<Boolean?>(false) }
    var reachHint by remember { mutableStateOf("") }
    var nameTrouble by remember { mutableStateOf("") }
    var readyVersion by remember { mutableStateOf<String?>(null) }
    var removing by remember { mutableStateOf<String?>(null) }
    // The notification permission is the one thing "People can call me" cannot
    // do for itself. Asked on the press that needs it; the switch finishes
    // itself when the answer comes back.
    lateinit var stateRef: KinState
    // The grant is "display over other apps" -- a Settings page with one
    // switch, not a dialog -- and the answer is read on the way back.
    val askOverlay = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { _ ->
        if (RingService.canRing(ctx)) {
            RingService.start(ctx)
            ctx.getSharedPreferences("kin", Context.MODE_PRIVATE).edit().putBoolean("listening", true).apply()
            stateRef.listeningGranted()
        } else stateRef.onChangedReady()
    }

    // The version that is ACTUALLY INSTALLED, asked of the package manager.
    // A hardcoded constant here re-downloaded the release forever: 64 MB every
    // half hour of something already installed, on somebody else's battery and
    // data, while the app looked perfectly healthy — the same shape as the
    // failure Update.swift records for a copy that cannot write /Applications.
    val installedVersion = remember {
        runCatching {
            ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: "0"
        }.getOrDefault("0")
    }
    val state = remember { KinState(ctx.filesDir, installedVersion, ctx.applicationContext) }
    stateRef = state
    val identity = state.identity
    val prefs = ctx.getSharedPreferences("kin", Context.MODE_PRIVATE)
    // Listening = the service is up. It is up whenever the person asked for it
    // and the permission allows it.
    state.listening = prefs.getBoolean("listening", false) && RingService.canRing(ctx)
    state.listenOn = {
        prefs.edit().putBoolean("listening", true).apply()
        if (!RingService.canRing(ctx)) {
            askOverlay.launch(
                android.content.Intent(
                    android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    android.net.Uri.parse("package:" + ctx.packageName),
                ),
            )
            false
        } else { RingService.start(ctx); true }
    }
    state.listenOff = {
        prefs.edit().putBoolean("listening", false).apply()
        RingService.stop(ctx)
    }

    var micGranted by remember {
        mutableStateOf(granted(ctx, Manifest.permission.RECORD_AUDIO))
    }
    var camGranted by remember { mutableStateOf(granted(ctx, Manifest.permission.CAMERA)) }
    val askAll = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) {
        micGranted = granted(ctx, Manifest.permission.RECORD_AUDIO)
        camGranted = granted(ctx, Manifest.permission.CAMERA)
    }

    // Ask once, on arrival: the front door needs the camera to show you your
    // own face, and the call needs the microphone. Asking at the moment of the
    // tap puts a system dialog between a person and the call they are placing.
    LaunchedEffect(Unit) {
        if (!micGranted || !camGranted) {
            askAll.launch(arrayOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.CAMERA))
        }
    }

    fun join(name: String, who: String = "", key: String? = null) {
        if (name.isBlank()) return
        // Who the other end must be: the key handed in (the ring's, or the one
        // the server bound their name to), else the one pinned from a previous
        // call. Neither: first use, pinned once the handshake verifies.
        val expected = key?.let { Identity.b64d(it) }?.takeIf { it.size == 32 }
            ?: (if (who.isNotEmpty()) identity.contactKey(who) else null)
        val s = CallSession(name.trim(), store = ctx.filesDir.resolve("kin"), who = who,
            identitySeed = identity.seedCopy, peerKey = expected)
        if (who.isNotEmpty()) s.onPeerIdentity = { k -> identity.remember(who, Identity.b64e(k)) }
        s.appVersion = installedVersion
        s.useTurn = ctx.getSharedPreferences("kin", Context.MODE_PRIVATE).getBoolean("turn", true)
        // Rig arms, from the launch intent, so an A/B needs no rebuild.
        rigFlags["turn"]?.let { s.useTurn = it }
        rigFlags["decodeq"]?.let { s.useDecodeQueue = it }
        s.start()
        val a = AudioDevice(s, ctx.getSystemService(AudioManager::class.java))
        a.start()
        val v = VideoDevice(ctx, s)
        s.onKeyframeRequest = { v.requestKeyframe() }
        s.videoStats = { intArrayOf(v.framesEncoded, v.framesDecoded, v.decodedW, v.decodedH) }
        val geo = Geo(ctx)
        s.onTransportLock = {
            geo.onTransportLock()
            s.geoLat = geo.lat; s.geoLon = geo.lon; s.geoErr = geo.err
        }
        // Their picture, but only when the call knows WHO it is with: a face
        // filed under a room name would surface under whoever uses that word
        // next.
        if (who.isNotEmpty()) {
            v.wantFaceFor = who
            v.onFace = { handle, bmp -> state.faces.save(handle, bmp) }
            s.onVideoFrame = { payload, _ -> v.faceFromKeyframe(payload) }
        }
        session = s; audio = a; video = v
        state.inCall = true
        // The Mac checks for a new version when a call starts, and installs
        // it when the call ends.
        state.updateNow("a call started")
    }

    fun leave() {
        video?.stop(); audio?.stop()
        session?.stop(hungUp = true)
        video = null; audio = null; session = null
        state.callEnded()
        state.refresh()
    }

    // The mailbox, and the panel it fills. One owner, so the poll loop and the
    // presence refresh are not tied to a recomposition.
    DisposableEffect(state) {
        state.onChanged = {
            myHandle = identity.handle
            people = state.people.ifEmpty {
                if (KIN_FIXTURES) FIXTURES else emptyList()
            }
            cardMode = state.cardMode
            cardWho = state.incoming?.from ?: state.outgoingTo ?: ""
            cardLine = state.cardLine
            cardBecause = state.cardBecause
            resumeRoom = state.pending?.room
            resumeWho = state.pending?.who ?: ""
            updateVersion = state.ready?.version
            readyVersion = state.ready?.version
            clipRoom = state.clipRoom
            inviteLabel = state.inviteLabel
            inviteValue = state.inviteValue
            mineValue = state.mineValue
            reachOn = state.reachOn
            reachHint = state.reachHint
            nameTrouble = if (identity.claimed) "" else
                "This phone has no name yet, so nobody can call it. It takes one the first time it reaches the server."
        }
        state.onCall = { room, who, key -> join(room, who, key); state.answered() }
        // Silent where this copy is its own installer of record, one tap where
        // it is not. Either way the person downloaded Kin once.
        state.onInstall = { f ->
            val silent = Installer.canInstallSilently(ctx)
            android.util.Log.i("kin", "update: installing ${f.name}, silent=$silent")
            // Try the silent path regardless: the system decides, and if it
            // wants a tap it says so and that intent is honoured. Refusing to
            // try because the installer of record is null would mean a
            // sideloaded copy could never adopt itself.
            if (!Installer.install(ctx, f)) Installer.installWithPrompt(ctx, f)
        }
        val installReceiver = Installer.register(ctx)
        state.onChangedReady()
        onDispose {
            state.stop()
            runCatching { ctx.unregisterReceiver(installReceiver) }
        }
    }

    // ── ONE MAILBOX, ONE READER ─────────────────────────────────────────────
    //
    // The Mac's resident stands down whenever the window is open. The handover
    // has to happen on the LIFECYCLE, not on composition: pressing Home stops
    // the activity but leaves the composition alive, so a handover keyed on
    // disposal never ran — both readers polled, the in-app one drained the
    // mailbox first, and a ring arriving with the app backgrounded raised no
    // notification at all. It was not lost; it was answered by the half that
    // could not show it.
    val owner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val obs = androidx.lifecycle.LifecycleEventObserver { _, e ->
            when (e) {
                androidx.lifecycle.Lifecycle.Event.ON_RESUME -> {
                    micGranted = granted(ctx, Manifest.permission.RECORD_AUDIO)
                    camGranted = granted(ctx, Manifest.permission.CAMERA)
                    // The clipboard is readable only by the focused app, and
                    // focus lands a moment after resume.
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        val cb = ctx.getSystemService(ClipboardManager::class.java)
                        val text = runCatching {
                            cb?.primaryClip?.getItemAt(0)?.coerceToText(ctx)?.toString()
                        }.getOrNull()
                        state.scanClipboard(text)
                    }, 350)
                }
                androidx.lifecycle.Lifecycle.Event.ON_START -> {
                    RingService.appInFront = true
                    // Started HERE, in the foreground, where Android allows it:
                    // the service then runs for the whole session and merely
                    // stops reading while the window is up.
                    if (ctx.getSharedPreferences("kin", Context.MODE_PRIVATE)
                            .getBoolean("listening", false)) RingService.start(ctx)
                    state.start()
                }
                androidx.lifecycle.Lifecycle.Event.ON_STOP -> {
                    state.stop()
                    RingService.appInFront = false
                }
                else -> {}
            }
        }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }

    // Answering from the lock screen: the notification named the call, so go
    // straight into it rather than showing a front door nobody asked for.
    LaunchedEffect(initialRoom, ringWho) {
        if (ringWho.isNotEmpty() && initialRoom != null && session == null) {
            // Opened by the service with nobody having answered: this is the
            // Mac's `--incoming` -- the card asks, the ringtone keeps going,
            // and no room, socket or camera exists until Answer is pressed.
            if (ringOffer) state.offer(com.tokkah.kin.net.Identity.Ring(ringWho, initialRoom, 0, null, true, ringKey ?: ""))
            else join(initialRoom, ringWho, ringKey)
        }
    }



    // ── THE CALL IS ALL PICTURE ─────────────────────────────────────────────
    //
    // The Mac's call window hides its title bar and runs the picture to every
    // edge. A phone's equivalent is the status bar and gesture bar out of the
    // way for the length of the call, brought back by a swipe from the edge
    // (transient, never gone for good). The front door keeps them: a clock is
    // useful there and the Mac's front door has a title bar to match.
    val view = androidx.compose.ui.platform.LocalView.current
    LaunchedEffect(session != null) {
        val window = (view.context as? android.app.Activity)?.window ?: return@LaunchedEffect
        val c = androidx.core.view.WindowInsetsControllerCompat(window, view)
        if (session != null) {
            c.systemBarsBehavior = androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            c.hide(androidx.core.view.WindowInsetsCompat.Type.systemBars())
        } else {
            c.show(androidx.core.view.WindowInsetsCompat.Type.systemBars())
        }
    }

    Box(Modifier.fillMaxSize().background(Palette.bg)) {
        val s = session
        if (s == null) {
            HomeScreen(
                room = room, onRoom = { room = it; if (fieldStatus.isNotEmpty()) fieldStatus = "" },
                card = com.tokkah.kin.ui.HomeCard(
                    people = people,
                    myHandle = myHandle,
                    nameTrouble = nameTrouble,
                    resumeLabel = resumeRoom?.let { if (resumeWho.isNotEmpty()) "@$resumeWho" else it },
                    updateVersion = updateVersion,
                    clipRoom = clipRoom,
                    inviteLabel = inviteLabel,
                    inviteValue = inviteValue,
                    mineValue = mineValue,
                    status = fieldStatus,
                    settingsOpen = settingsOpen,
                    reachOn = reachOn,
                    reachHint = reachHint,
                    removing = removing,
                ),
                // A denied permission is said, with the way to fix it, the way
                // the Mac's pill does: the mic first (0.121: "a denied microphone
                // was completely invisible"), then the camera. Pressing the pill
                // opens this app's settings page, which is where the switch is.
                cameraHint = when {
                    !micGranted -> "Kin can’t hear you — tap here to turn on the microphone."
                    !camGranted -> "Camera access is off — tap here to turn it on."
                    else -> cameraHint
                },
                onHintClick = if (micGranted && camGranted) null else ({
                    Metrics.tap("permissions_open")
                    runCatching {
                        ctx.startActivity(android.content.Intent(
                            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.fromParts("package", ctx.packageName, null),
                        ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                }),
                onUpdate = {
                    // The bytes were checked against a signature we control
                    // before this row ever appeared; the system installer is
                    // the only thing on Android that can actually replace an
                    // app, so the last tap is the person's.
                    state.readyFile?.let { f ->
                        if (Installer.canInstallSilently(ctx)) Installer.install(ctx, f)
                        else Installer.installWithPrompt(ctx, f)
                    }
                },
                onSettings = { Metrics.tap("settings"); settingsOpen = !settingsOpen },
                onJoin = {
                    // What was typed decides what happens: a link joins its
                    // room, a word with - or _ joins as a room, a name rings.
                    when (val v = state.commit(room)) {
                        is KinState.Verdict.Room -> { fieldStatus = ""; Metrics.tap("join"); join(v.name) }
                        is KinState.Verdict.Ring -> { fieldStatus = ""; Metrics.tap("call"); state.call(v.handle) }
                        is KinState.Verdict.Say -> { fieldStatus = v.status; Metrics.tap("join", ok = false) }
                    }
                },
                onCall = { handle -> Metrics.tap("call_person"); state.call(handle) },
                onResume = {
                    state.pending?.let { join(it.room, it.who) }
                    state.pending = null
                },
                onJoinClip = { state.clipRoom?.let { Metrics.tap("join_clip"); join(it) } },
                onInvite = {
                    val link = state.invite()
                    val cb = ctx.getSystemService(ClipboardManager::class.java)
                    cb?.setPrimaryClip(ClipData.newPlainText("kin", link))
                    // A copy that did not land is a real failure mode and a
                    // silent one: the person pastes the last thing they copied.
                    Metrics.tap("invite_copy", ok = cb != null)
                },
                onCopyMine = {
                    if (myHandle.isNotEmpty()) {
                        val cb = ctx.getSystemService(ClipboardManager::class.java)
                        cb?.setPrimaryClip(ClipData.newPlainText("kin", "@$myHandle"))
                        state.copiedMine()
                        Metrics.tap("copy_mine", ok = cb != null)
                    }
                },
                onReach = { state.toggleReach() },
                onRemoveOffer = { removing = it },
                onRemove = { removing = null; state.remove(it) },
                onShareInvite = {
                    // The system share sheet with the same link the copy makes.
                    val link = state.invite()
                    Metrics.tap("invite_share")
                    runCatching {
                        val send = android.content.Intent(android.content.Intent.ACTION_SEND)
                            .setType("text/plain")
                            .putExtra(android.content.Intent.EXTRA_TEXT, link)
                        ctx.startActivity(android.content.Intent.createChooser(send, "Invite someone to Kin")
                            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                },
            ) {
                if (camGranted) SelfPreview { cameraHint = it }
            }
            // The calling card sits OVER the front door, because a call being
            // offered is not a different screen — it is something happening on
            // this one.
            if (cardMode != com.tokkah.kin.ui.CallCardMode.INVITE) {
                com.tokkah.kin.ui.CallCard(
                    mode = cardMode,
                    who = cardWho,
                    line = cardLine,
                    because = cardBecause,
                    faceFile = state.faces.path(cardWho),
                    onAnswer = { state.answerIncoming() },
                    onDecline = { state.declineIncoming() },
                    onCancel = { state.cancelOutgoing() },
                    onCallAgain = { state.callAgain() },
                )
            }
        } else {
            var sentence by remember { mutableStateOf("waiting for the other person") }
            var warning by remember { mutableStateOf("") }
            var noPicture by remember { mutableStateOf<String?>(null) }
            var peerPresent by remember { mutableStateOf(false) }
            var elapsed by remember { mutableStateOf<Int?>(null) }
            var startedAt by remember { mutableStateOf(0L) }
            var muted by remember { mutableStateOf(false) }
            // ON when the call starts, the Mac's default (`camOff = false`): the
            // front door already showed your face, and a call that opens with
            // your camera off is a different product.
            var camOn by remember { mutableStateOf(false) }
            var peeking by remember { mutableStateOf(false) }
            var turn by remember { mutableStateOf(Floor.State.IDLE) }
            var voicing by remember { mutableStateOf(false) }
            var loud by remember { mutableStateOf(0f) }
            // `--press said` on the Mac: a rig arm that shows a caption so the
            // pill can be photographed without a second person talking.
            var caption by remember { mutableStateOf(rigSaid) }
            var bloom by remember { mutableStateOf<String?>(null) }
            var cueLevel by remember { mutableStateOf(0f) }
            var subsRef by remember { mutableStateOf<Subtitles?>(null) }
            // The sheet: null closed, else the page.
            var page by remember { mutableStateOf<String?>(null) }
            var renameText by remember { mutableStateOf(identity.handle) }
            // A transient sentence in the status pill (`setStatus` from a row),
            // and when it stops being true.
            var note by remember { mutableStateOf<String?>(null) }
            var noteUntil by remember { mutableStateOf(0L) }
            var silentBusy by remember { mutableStateOf(false) }
            var settingsNote by remember { mutableStateOf("") }
            var updateChecking by remember { mutableStateOf(false) }
            var updateNote by remember { mutableStateOf("") }
            var speakerName by remember { mutableStateOf("") }
            var micName by remember { mutableStateOf("") }
            var dialFocus by remember { mutableStateOf(0) }
            var peerHandle by remember { mutableStateOf(s.who) }
            val cameraCount = remember {
                runCatching {
                    val cm = ctx.getSystemService(android.hardware.camera2.CameraManager::class.java)
                    cm.cameraIdList.map {
                        cm.getCameraCharacteristics(it).get(android.hardware.camera2.CameraCharacteristics.LENS_FACING)
                    }.distinct().size
                }.getOrDefault(1)
            }
            fun say(line: String, forMs: Long = 4000) { note = line; noteUntil = System.currentTimeMillis() + forMs }

            LaunchedEffect(s) {
                if (camGranted && !camOn) {
                    val started = withContext(Dispatchers.IO) { video?.startEncode() == true }
                    if (started) { camOn = true; s.camOn = true }
                    Metrics.tap("camera_auto", ok = started)
                }
            }

            DisposableEffect(s) {
                val subs = Subtitles(ctx, s)
                subsRef = subs
                s.onText = { text, final, _ ->
                    // A short one is the sound somebody makes to stay with you;
                    // a long one is something they said. The wire does not
                    // label them, and the length is the honest separator.
                    if (text.length <= 12 && final) { bloom = text; caption = null }
                    else { caption = text; bloom = null }
                }
                onDispose { subs.stop(); s.onText = null }
            }

            LaunchedEffect(s) {
                while (true) {
                    val now = System.currentTimeMillis()
                    val here = s.crypto.established && !s.ended && !s.left
                    if (here && startedAt == 0L) startedAt = now
                    peerPresent = here
                    elapsed = if (startedAt == 0L) null else ((now - startedAt) / 1000).toInt()
                    val name = if (peerHandle.isEmpty()) "They" else Identity.display(peerHandle)
                    // The Mac's sentences, in the Mac's order of precedence.
                    val computed = when {
                        s.ended -> "the other person hung up"
                        s.left -> "the other person left"
                        !s.crypto.established -> "waiting for the other person"
                        s.holding -> "$name’ll be right back…"
                        s.reconnecting -> "reconnecting…"
                        // paused OUTRANKS everything: if audio is not arriving,
                        // never put the word "audio" beside the word "live".
                        s.heldSentence != null -> s.heldSentence!!
                        readyVersion != null -> "update $readyVersion ready — restarts when the call ends"
                        muted -> "you are muted"
                        else -> "connected"
                    }
                    sentence = if (note != null && now < noteUntil) note!! else { note = null; computed }
                    // `Display.setPaused`: what is wrong with THEIR picture, in words.
                    val pMuted = s.peerMuted; val pCam = s.peerCamOff; val pPaused = s.peerVideoPaused
                    warning = if (!here) "" else when {
                        pMuted && pCam -> "their microphone and camera are off"
                        pMuted -> "their microphone is off"
                        pPaused && pCam -> "their camera is off and their connection is weak"
                        pPaused -> "their connection is weak — video paused, audio is still on"
                        pCam -> "their camera is off"
                        s.selfVideoPaused -> "your connection is weak — your video is paused, audio is still on"
                        else -> ""
                    }
                    noPicture = when {
                        !here -> null
                        pCam -> if (pMuted) "Camera and microphone off" else "Camera off"
                        pPaused -> "Reconnecting…"
                        else -> null
                    }
                    turn = s.floor.state
                    voicing = s.gate.voicingNow
                    loud = s.gate.nearLoudNow
                    cueLevel = s.cue.level
                    // The words cross exactly while the voice cannot: muted by
                    // hand, or muted by the floor because it is not your turn.
                    subsRef?.setMuted(muted || s.floor.state == Floor.State.THEIRS)
                    // Nothing to read once they have stopped: a caption that
                    // outlives the sentence is furniture over somebody's face.
                    if (s.cue.idle && caption != null && !voicing && caption != rigSaid) caption = null
                    if (s.cue.idle) bloom = null
                    if (page != null) { speakerName = audio?.speakerName() ?: ""; micName = audio?.micName() ?: "" }
                    delay(100)
                }
            }

            val inviteLink = com.tokkah.kin.net.Server.roomURL(s.room)

            // ── ringing somebody INTO this call ─────────────────────────────
            fun dialInto(raw: String) {
                val who = raw.trim().removePrefix("@").lowercase()
                if (!identity.handleOK(who)) { say("that is not a name"); Metrics.tap("call", ok = false); return }
                Metrics.tap("call")
                say("ringing ${Identity.display(who)}…", 30_000)
                peerHandle = who
                Thread {
                    val ok = identity.ring(who, s.room)
                    if (ok) { identity.rememberCalled(who); identity.noteCallTime(who) }
                    else say("couldn’t reach ${Identity.display(who)}")
                }.apply { isDaemon = true }.start()
            }

            fun commitRename() {
                val want = renameText.trim().removePrefix("@")
                if (!identity.handleOK(want.lowercase())) { Metrics.tap("rename", ok = false); say("that is not a name"); return }
                Metrics.tap("rename")
                say("asking for @${want.lowercase()}…", 15_000)
                Thread {
                    val r = identity.rename(want)
                    when (r) {
                        Identity.Renamed.OK -> { say("you are @${identity.handle}"); myHandle = identity.handle; page = "settings" }
                        Identity.Renamed.TAKEN -> say("@${want.lowercase()} belongs to someone else")
                        Identity.Renamed.NOT_A_NAME -> say("that is not a name")
                        Identity.Renamed.NO_ANSWER -> say("could not reach the internet — try again")
                    }
                }.apply { isDaemon = true }.start()
            }

            // ── THE SHEET'S PAGES, AS LISTS ─────────────────────────────────
            val sheet: List<com.tokkah.kin.ui.SheetItem>? = when (page) {
                null -> null
                "settings" -> buildList {
                    val h = identity.handle
                    if (h.isNotEmpty()) add(com.tokkah.kin.ui.SheetItem.Row("Your name", detail = "@$h",
                        valueIsAction = true, glyph = com.tokkah.kin.ui.GlyphKind.PERSON, onClick = {
                            ctx.getSystemService(ClipboardManager::class.java)
                                ?.setPrimaryClip(ClipData.newPlainText("kin", "@$h"))
                            Metrics.tap("copy_handle"); say("copied @$h")
                        }))
                    add(com.tokkah.kin.ui.SheetItem.Row("People", chevron = true,
                        glyph = com.tokkah.kin.ui.GlyphKind.PERSON, onClick = { Metrics.tap("people"); page = "people" }))
                    add(com.tokkah.kin.ui.SheetItem.Row(if (h.isEmpty()) "Choose your name" else "Change your name",
                        chevron = true, glyph = com.tokkah.kin.ui.GlyphKind.PENCIL,
                        onClick = { Metrics.tap("rename_open"); renameText = identity.handle; page = "rename" }))
                    // A choice between one thing is not a choice.
                    if (cameraCount > 1) add(com.tokkah.kin.ui.SheetItem.Row("Camera",
                        detail = if (video?.facingFront != false) "Front" else "Back", chevron = true,
                        glyph = com.tokkah.kin.ui.GlyphKind.CAMERA, onClick = { page = "camera" }))
                    // Android picks the microphone with the route: a fact, not a door.
                    add(com.tokkah.kin.ui.SheetItem.Row("Microphone", detail = micName.ifEmpty { "…" },
                        glyph = com.tokkah.kin.ui.GlyphKind.MIC, inert = true))
                    add(com.tokkah.kin.ui.SheetItem.Row("Speaker", detail = speakerName.ifEmpty { "…" }, chevron = true,
                        glyph = com.tokkah.kin.ui.GlyphKind.SPEAKER, onClick = { page = "speaker" }))
                    add(com.tokkah.kin.ui.SheetItem.Row("Calls when Kin is closed", switchState = state.listening,
                        glyph = com.tokkah.kin.ui.GlyphKind.PHONE, onClick = {
                            Metrics.tap("watch_row")
                            if (state.listening) { state.listenOff?.invoke(); state.listening = false
                                say("Kin will only ring while it’s open") }
                            else { state.listening = state.listenOn?.invoke() ?: false
                                say(if (state.listening) "people can reach you even when Kin is closed" else "setting up…") }
                            state.onChangedReady()
                        }))
                    if (!state.listening) add(com.tokkah.kin.ui.SheetItem.Hint("Right now Kin only rings while it’s open."))
                    val silent = identity.quietOn
                    add(com.tokkah.kin.ui.SheetItem.Row("Silent", switchState = if (silentBusy) null else silent,
                        detail = if (silentBusy) "…" else null, inert = silentBusy,
                        glyph = com.tokkah.kin.ui.GlyphKind.BELL, onClick = {
                            Metrics.tap("silent")
                            val want = !silent
                            say(if (want) "going silent…" else "turning silence off…")
                            silentBusy = true; settingsNote = ""
                            Thread {
                                val ok = identity.setQuiet(want)
                                silentBusy = false
                                if (ok) say(if (want) "silent" else "you can be reached")
                                else { say("could not change that"); settingsNote =
                                    if (identity.lastQuietStatus == 429) "Too many changes at once — try again in a moment."
                                    else "Couldn’t reach the server — nothing changed." }
                                state.onChangedReady()
                            }.apply { isDaemon = true }.start()
                        }))
                    if (settingsNote.isNotEmpty()) add(com.tokkah.kin.ui.SheetItem.Hint(settingsNote))
                    add(com.tokkah.kin.ui.SheetItem.Row("Encryption code", detail = s.safetyCode ?: "…",
                        valueIsWord = false, inert = true, glyph = com.tokkah.kin.ui.GlyphKind.LOCK))
                    add(com.tokkah.kin.ui.SheetItem.Hint(if (silent) "Silent: nobody can ring you. To them you simply look away."
                        else "Read it aloud. Same code on both screens means nobody is in the middle."))
                    val ready = state.readyFile
                    when {
                        ready != null -> add(com.tokkah.kin.ui.SheetItem.Row("Update ready", detail = "install",
                            valueIsAction = true, glyph = com.tokkah.kin.ui.GlyphKind.MORE, onClick = {
                                Metrics.tap("restart_for_update_row"); say("the update installs when the call ends") }))
                        updateChecking -> add(com.tokkah.kin.ui.SheetItem.Row("Version", detail = "checking…",
                            inert = true, glyph = com.tokkah.kin.ui.GlyphKind.MORE))
                        else -> add(com.tokkah.kin.ui.SheetItem.Row("Version", detail = installedVersion,
                            valueIsAction = true, glyph = com.tokkah.kin.ui.GlyphKind.MORE, onClick = {
                                Metrics.tap("check_update_row")
                                updateChecking = true; updateNote = ""
                                state.updateNow("asked from the panel")
                                Thread {
                                    Thread.sleep(6000)
                                    updateChecking = false
                                    updateNote = if (state.readyFile != null) "" else "This is the newest version."
                                    Thread.sleep(6000)
                                    if (updateNote.isNotEmpty()) updateNote = ""
                                }.apply { isDaemon = true }.start()
                            }))
                    }
                    if (updateNote.isNotEmpty()) add(com.tokkah.kin.ui.SheetItem.Hint(updateNote))
                    add(com.tokkah.kin.ui.SheetItem.Row("Licence", detail = "AGPL-3.0", inert = true,
                        glyph = com.tokkah.kin.ui.GlyphKind.MORE))
                    add(com.tokkah.kin.ui.SheetItem.Hint("Free software. The source, and your right to run your own: github.com/deshmukhpatel98/tokkah"))
                }
                "people" -> buildList {
                    val list = identity.contactHandles().take(6)
                    if (list.isEmpty()) add(com.tokkah.kin.ui.SheetItem.Hint("Talk to someone once and they’ll show up here."))
                    for (h in list) add(com.tokkah.kin.ui.SheetItem.Row("@$h", avatar = h, onClick = {
                        Metrics.tap("call_contact"); page = null; dialInto(h) }))
                    val h = identity.handle
                    if (h.isEmpty()) add(com.tokkah.kin.ui.SheetItem.Hint(nameTrouble.ifEmpty { "Your name on Kin isn’t set up yet." }))
                    else {
                        add(com.tokkah.kin.ui.SheetItem.Row("@$h", avatar = h, detail = "copy", valueIsAction = true,
                            ruled = list.isNotEmpty(), onClick = {
                                ctx.getSystemService(ClipboardManager::class.java)
                                    ?.setPrimaryClip(ClipData.newPlainText("kin", "@$h"))
                                Metrics.tap("copy_handle"); say("copied @$h")
                            }))
                        add(com.tokkah.kin.ui.SheetItem.Hint("Give this to someone and they can call you."))
                    }
                    // Only where it can work: mid-call there is no name field to hand over to.
                    if (!peerPresent) add(com.tokkah.kin.ui.SheetItem.Row("Call someone new", indent = true, onClick = {
                        Metrics.tap("call_new"); page = null; dialFocus++ }))
                    add(com.tokkah.kin.ui.SheetItem.Row("Back", indent = true, onClick = { Metrics.tap("people_back"); page = "settings" }))
                }
                "rename" -> listOf(
                    com.tokkah.kin.ui.SheetItem.Hint("This is the name people type to call you."),
                    com.tokkah.kin.ui.SheetItem.Field("a name", renameText, { renameText = it }, { commitRename() }),
                    com.tokkah.kin.ui.SheetItem.Row("Save this name", onClick = { commitRename() }),
                    com.tokkah.kin.ui.SheetItem.Row("Not now", onClick = { page = "settings" }),
                    com.tokkah.kin.ui.SheetItem.Hint("Letters and numbers, starting with a letter."),
                )
                "camera" -> buildList {
                    val front = video?.facingFront != false
                    for ((label, isFront) in listOf("Front camera" to true, "Back camera" to false)) {
                        add(com.tokkah.kin.ui.SheetItem.Row(label, checked = front == isFront, onClick = {
                            if (front != isFront) { val ok = video?.flip() == true; Metrics.tap("cam_pick", ok = ok) }
                            page = "settings"
                        }))
                    }
                    add(com.tokkah.kin.ui.SheetItem.Row("Back", onClick = { page = "settings" }))
                }
                "speaker" -> buildList {
                    val routes = audio?.routes() ?: emptyList()
                    for (r in routes) add(com.tokkah.kin.ui.SheetItem.Row(r.name, checked = r.name == speakerName, onClick = {
                        audio?.setRoute(r); page = "settings"
                    }))
                    add(com.tokkah.kin.ui.SheetItem.Row("Back", onClick = { page = "settings" }))
                }
                else -> null
            }

            CallScreen(
                ui = com.tokkah.kin.ui.CallUi(
                    peerHandle = peerHandle,
                    elapsed = elapsed,
                    sentence = sentence,
                    warning = warning,
                    peerPresent = peerPresent,
                    noPicture = noPicture,
                    inviteLink = inviteLink,
                    safetyCode = s.safetyCode,
                    turnMine = turn == Floor.State.MINE,
                    turnTheirs = turn == Floor.State.THEIRS,
                    voicing = voicing,
                    loud = loud,
                    muted = muted,
                    camOn = camOn,
                    canFlip = cameraCount > 1 && camGranted,
                    peeking = peeking,
                    caption = caption,
                    bloom = bloom,
                    cueLevel = cueLevel,
                    sheet = sheet,
                    dialFocus = dialFocus,
                ),
                // ok = the flag actually moved. A control that is pressed and
                // does nothing must be distinguishable from one nobody pressed.
                onMute = {
                    muted = !muted; s.selfMuted = muted
                    Metrics.tap("mute", ok = s.selfMuted == muted)
                },
                onCamera = {
                    if (!camOn) {
                        val started = video?.startEncode() == true
                        if (started) { camOn = true; s.camOn = true }
                        // A camera button that fails to bring the camera up is
                        // the single most reported thing in this app, and until
                        // now it looked identical to not pressing it.
                        Metrics.tap("camera_on", ok = started)
                    } else {
                        video?.stopEncode(); camOn = false; s.camOn = false
                        Metrics.tap("camera_off")
                    }
                },
                onFlip = {
                    val ok = video?.flip() == true
                    Metrics.tap("flip", ok = ok)
                },
                onLeave = { Metrics.tap("leave"); leave() },
                onPeek = { peeking = it },
                onPeople = { Metrics.tap("peek_people"); page = if (page == "people") null else "people" },
                onMore = { Metrics.tap("more"); page = if (page == null) "settings" else null },
                onCloseSheet = { page = null },
                onCopyInvite = {
                    val cb = ctx.getSystemService(ClipboardManager::class.java)
                    cb?.setPrimaryClip(ClipData.newPlainText("kin", inviteLink))
                    Metrics.tap("invite_copy", ok = cb != null)
                    cb != null
                },
                onDial = { dialInto(it) },
                farVideo = { FarVideo(video) },
                selfVideo = { if (camGranted) SelfPreview {} },
            )
        }
    }
}

/** The Mac's home-check plants three people; this plants the same three. */
private val FIXTURES = listOf(
    Person("meera", online = true, lastSeen = "5m ago"),
    Person("arjun", lastSeen = "yesterday"),
    Person("dad", lastSeen = "3w ago"),
)

private val KIN_FIXTURES =
    android.os.Build.FINGERPRINT.contains("generic") ||
    android.os.Build.FINGERPRINT.lowercase().contains("emulator") ||
    android.os.Build.MODEL.lowercase().contains("sdk")

private fun granted(ctx: Context, p: String) =
    ContextCompat.checkSelfPermission(ctx, p) == PackageManager.PERMISSION_GRANTED

/** Your own face, through a TextureView so the glass above it can refract it. */
@Composable
private fun SelfPreview(onHint: (String) -> Unit) {
    AndroidView(
        factory = { c -> CameraPreview(c).apply { this.onHint = onHint } },
        modifier = Modifier.fillMaxSize(),
        onRelease = { it.close() },
    )
}

/**
 * Their face. A SurfaceView, because here latency is the product.
 *
 * ── AND IT KEEPS ITS SHAPE ──────────────────────────────────────────────────
 *
 * A SurfaceView stretches its buffer to its bounds, so a 16:9 picture in a
 * 9:20 window made everybody tall and thin. Display.swift answers this with
 * `.resizeAspect` — fit inside, keep the shape — so the surface is sized to the
 * aspect the DECODER reports and centred. Their face is the wrong thing to
 * take liberties with.
 */
@Composable
private fun FarVideo(video: VideoDevice?) {
    var aspect by remember { mutableStateOf(16f / 9f) }
    DisposableEffect(video) {
        video?.onDecodedSize = { w, h -> if (h > 0) aspect = w.toFloat() / h }
        onDispose { video?.onDecodedSize = null }
    }
    Box(Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.Center) {
        AndroidView(
            factory = { c ->
                SurfaceView(c).apply {
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(h: SurfaceHolder) { video?.attachDisplay(h.surface) }
                        override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, ht: Int) {}
                        override fun surfaceDestroyed(h: SurfaceHolder) {}
                    })
                }
            },
            modifier = Modifier.fillMaxWidth().aspectRatio(aspect),
        )
    }
}
