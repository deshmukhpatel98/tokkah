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
import com.tokkah.kin.net.Identity
import com.tokkah.kin.net.Server
import com.tokkah.kin.ui.CallScreen
import com.tokkah.kin.ui.HomeScreen
import com.tokkah.kin.ui.Palette
import com.tokkah.kin.ui.Person
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

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
    var quiet by remember { mutableStateOf(false) }
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
    var listening by remember {
        mutableStateOf(ctx.getSharedPreferences("kin", Context.MODE_PRIVATE)
            .getBoolean("listening", false))
    }
    val askNotify = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { ok -> if (ok) { RingService.start(ctx); listening = true } }

    val state = remember { KinState(ctx.filesDir) }
    val identity = state.identity

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
        s.start()
        val a = AudioDevice(s, ctx.getSystemService(AudioManager::class.java))
        a.start()
        val v = VideoDevice(ctx, s)
        s.onKeyframeRequest = { v.requestKeyframe() }
        // Their picture, but only when the call knows WHO it is with: a face
        // filed under a room name would surface under whoever uses that word
        // next.
        if (who.isNotEmpty()) {
            v.wantFaceFor = who
            v.onFace = { handle, bmp -> state.faces.save(handle, bmp) }
            s.onVideoFrame = { payload, _ -> v.faceFromKeyframe(payload) }
        }
        session = s; audio = a; video = v
    }

    fun leave() {
        video?.stop(); audio?.stop()
        session?.stop(hungUp = true)
        video = null; audio = null; session = null
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
        }
        state.onCall = { room, who -> join(room, who); state.answered() }
        state.onChangedReady()
        onDispose { state.stop() }
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
                room = room, onRoom = { room = it },
                people = people,
                myHandle = myHandle,
                cameraHint = cameraHint,
                resumeRoom = resumeRoom?.let { if (resumeWho.isNotEmpty()) "@$resumeWho" else it },
                updateVersion = updateVersion,
                onUpdate = {
                    // The bytes were checked against a signature we control
                    // before this row ever appeared; the system installer is
                    // the only thing on Android that can actually replace an
                    // app, so the last tap is the person's.
                    state.readyFile?.let { f ->
                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            ctx, ctx.packageName + ".files", f,
                        )
                        ctx.startActivity(
                            android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                            },
                        )
                    }
                },
                pastedLink = null,
                settingsOpen = settingsOpen,
                listening = listening,
                onListening = { on ->
                    ctx.getSharedPreferences("kin", Context.MODE_PRIVATE)
                        .edit().putBoolean("listening", on).apply()
                    if (on) {
                        if (android.os.Build.VERSION.SDK_INT >= 33 &&
                            !granted(ctx, Manifest.permission.POST_NOTIFICATIONS)) {
                            askNotify.launch(Manifest.permission.POST_NOTIFICATIONS)
                        } else { RingService.start(ctx); listening = true }
                    } else { RingService.stop(ctx); listening = false }
                },
                onSettings = { settingsOpen = !settingsOpen },
                onJoin = {
                    // A handle rings a person; anything else is a room name.
                    val typed = room.trim().removePrefix("@")
                    if (identity.handleOK(typed) && typed != myHandle) state.call(typed)
                    else join(room)
                },
                onCall = { handle -> state.call(handle) },
                onResume = {
                    state.pending?.let { join(it.room, it.who) }
                    state.pending = null
                },
                onInvite = {
                    val link = "${Server.invite}/${room.ifBlank { myHandle }}"
                    ctx.getSystemService(ClipboardManager::class.java)
                        ?.setPrimaryClip(ClipData.newPlainText("kin", link))
                },
                quiet = quiet,
                onQuiet = { on -> quiet = on },
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
            var camOn by remember { mutableStateOf(false) }
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
                    sentence = when {
                        !s.crypto.established -> "connecting"
                        s.ended -> "they left"
                        // paused OUTRANKS everything: if audio is not arriving,
                        // never put the word "audio" beside the word "live".
                        s.heldSentence != null -> s.heldSentence!!
                        s.peerMuted -> "they are muted"
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
                onMute = { muted = !muted; s.selfMuted = muted },
                onCamera = {
                    if (!camOn) { if (video?.startEncode() == true) { camOn = true; s.camOn = true } }
                    else { video?.stop(); camOn = false; s.camOn = false }
                },
                onFlip = { video?.let { it.facingFront = !it.facingFront } },
                onLeave = { leave() },
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
