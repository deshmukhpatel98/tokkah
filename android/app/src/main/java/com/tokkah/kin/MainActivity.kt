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

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The picture goes edge to edge; the card floats over it.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        // A ring notification carries the call it is about, so answering from
        // the lock screen lands in that call rather than at the front door.
        val fromRing = intent?.getStringExtra(RingService.EXTRA_ROOM)
        val ringWho = intent?.getStringExtra(RingService.EXTRA_FROM) ?: ""
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
        RingService.channels(this)
        setContent { KinApp(deep, if (fromRing != null) ringWho else "") }
    }
}

@Composable
fun KinApp(initialRoom: String?, ringWho: String = "") {
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
    // The notification permission is the one thing "People can call me" cannot
    // do for itself. Asked on the press that needs it; the switch finishes
    // itself when the answer comes back.
    lateinit var stateRef: KinState
    val askNotify = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { ok ->
        if (ok) {
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
    state.listening = prefs.getBoolean("listening", false) &&
        (android.os.Build.VERSION.SDK_INT < 33 || granted(ctx, Manifest.permission.POST_NOTIFICATIONS))
    state.listenOn = {
        prefs.edit().putBoolean("listening", true).apply()
        if (android.os.Build.VERSION.SDK_INT >= 33 && !granted(ctx, Manifest.permission.POST_NOTIFICATIONS)) {
            askNotify.launch(Manifest.permission.POST_NOTIFICATIONS)
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

    fun join(name: String, who: String = "") {
        if (name.isBlank()) return
        val s = CallSession(name.trim(), store = ctx.filesDir.resolve("kin"), who = who)
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
        state.inCall = false
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
        state.onCall = { room, who -> join(room, who); state.answered() }
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
            join(initialRoom, ringWho)
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
                ),
                cameraHint = cameraHint,
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
            var sentence by remember { mutableStateOf("connecting") }
            var muted by remember { mutableStateOf(false) }
            // ON when the call starts, the Mac's default (`camOff = false`): the
            // front door already showed your face, and a call that opens with
            // your camera off is a different product.
            var camOn by remember { mutableStateOf(false) }
            LaunchedEffect(s) {
                if (camGranted && !camOn) {
                    val started = withContext(Dispatchers.IO) { video?.startEncode() == true }
                    if (started) { camOn = true; s.camOn = true }
                    Metrics.tap("camera_auto", ok = started)
                }
            }
            var peeking by remember { mutableStateOf(false) }
            var turn by remember { mutableStateOf(Floor.State.IDLE) }
            var voicing by remember { mutableStateOf(false) }
            var caption by remember { mutableStateOf<String?>(null) }
            var bloom by remember { mutableStateOf<String?>(null) }
            var cueLevel by remember { mutableStateOf(0f) }
            var subsRef by remember { mutableStateOf<Subtitles?>(null) }

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
                    // The Mac's sentences, in the Mac's order of precedence.
                    sentence = when {
                        s.ended -> "the other person hung up"
                        !s.crypto.established -> "waiting for the other person"
                        // paused OUTRANKS everything: if audio is not arriving,
                        // never put the word "audio" beside the word "live".
                        s.heldSentence != null -> s.heldSentence!!
                        readyVersion != null -> "update $readyVersion ready — restarts when the call ends"
                        muted -> "you are muted"
                        else -> "connected"
                    }
                    turn = s.floor.state
                    voicing = s.gate.voicingNow
                    cueLevel = s.cue.level
                    // The words cross exactly while the voice cannot: muted by
                    // hand, or muted by the floor because it is not your turn.
                    subsRef?.setMuted(muted || s.floor.state == Floor.State.THEIRS)
                    // Nothing to read once they have stopped: a caption that
                    // outlives the sentence is furniture over somebody's face.
                    if (s.cue.idle && caption != null && !voicing) caption = null
                    if (s.cue.idle) bloom = null
                    delay(100)
                }
            }

            CallScreen(
                room = s.room,
                sentence = sentence,
                safetyCode = s.safetyCode,
                turnMine = turn == Floor.State.MINE,
                turnTheirs = turn == Floor.State.THEIRS,
                voicing = voicing,
                muted = muted,
                camOn = camOn,
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
                        video?.stop(); camOn = false; s.camOn = false
                        Metrics.tap("camera_off")
                    }
                },
                onFlip = {
                    val v = video
                    v?.let { it.facingFront = !it.facingFront }
                    Metrics.tap("flip", ok = v != null)
                },
                onLeave = { Metrics.tap("leave"); leave() },
                peeking = peeking,
                onPeek = { peeking = it },
                caption = caption,
                bloom = bloom,
                cueLevel = cueLevel,
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
