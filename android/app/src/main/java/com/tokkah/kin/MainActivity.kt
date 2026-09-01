package com.tokkah.kin

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.tokkah.kin.net.CallSession
import com.tokkah.kin.net.Floor
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A deep link is a room: tokkah://join/<room>, tokkah://<room>, kin://…
        val deep = intent?.data?.let { u ->
            (u.pathSegments?.lastOrNull() ?: u.host)?.takeIf { it.isNotBlank() }
        }
        setContent { KinApp(deep) }
    }
}

@Composable
fun KinApp(initialRoom: String?) {
    val ctx = LocalContext.current
    var room by remember { mutableStateOf(initialRoom ?: "") }
    var session by remember { mutableStateOf<CallSession?>(null) }
    var device by remember { mutableStateOf<AudioDevice?>(null) }
    var micGranted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED)
    }
    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        micGranted = it
    }

    fun join(name: String) {
        if (name.isBlank()) return
        val s = CallSession(name.trim())
        s.start()
        val d = AudioDevice(s, ctx.getSystemService(AudioManager::class.java))
        d.start()
        session = s; device = d
    }

    fun leave() {
        device?.stop(); session?.stop()
        device = null; session = null
    }

    Box(Modifier.fillMaxSize().background(Glass.bg)) {
        val s = session
        if (s == null) JoinScreen(room, { room = it }, micGranted,
            onAskMic = { askMic.launch(Manifest.permission.RECORD_AUDIO) },
            onJoin = { join(room) })
        else CallScreen(s, device, onLeave = { leave() })
    }
}

@Composable
private fun JoinScreen(
    room: String, onRoom: (String) -> Unit, micGranted: Boolean,
    onAskMic: () -> Unit, onJoin: () -> Unit,
) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Kin", color = Glass.fg, fontSize = 44.sp, fontWeight = FontWeight.Light)
        Spacer(Modifier.height(8.dp))
        Text("Type the same words on both ends.", color = Glass.fg.copy(alpha = 0.55f),
            fontSize = 15.sp, textAlign = TextAlign.Center)
        Spacer(Modifier.height(28.dp))
        OutlinedTextField(
            value = room, onValueChange = onRoom, singleLine = true,
            placeholder = { Text("room", color = Glass.fg.copy(alpha = 0.35f)) },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
            colors = OutlinedTextFieldDefaults.colors(
                focusedTextColor = Glass.fg, unfocusedTextColor = Glass.fg,
                focusedBorderColor = Glass.accent, unfocusedBorderColor = Glass.glassLine,
                cursorColor = Glass.accent,
            ),
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(20.dp))
        if (!micGranted) {
            Text("Kin needs the microphone to carry your voice.",
                color = Glass.warn, fontSize = 14.sp, textAlign = TextAlign.Center)
            Spacer(Modifier.height(10.dp))
            Button(onClick = onAskMic, colors = ButtonDefaults.buttonColors(
                containerColor = Glass.accent, contentColor = Glass.bg)) {
                Text("Allow microphone")
            }
        } else {
            Button(
                onClick = onJoin, enabled = room.isNotBlank(),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Glass.accent, contentColor = Glass.bg,
                    disabledContainerColor = Glass.fill(0.10f),
                    disabledContentColor = Glass.fg.copy(alpha = 0.35f)),
                modifier = Modifier.fillMaxWidth().height(50.dp),
                shape = RoundedCornerShape(12.dp),
            ) { Text("Join", fontSize = 17.sp) }
        }
    }
}

@Composable
private fun CallScreen(s: CallSession, d: AudioDevice?, onLeave: () -> Unit) {
    // No numbers on the consumer surface: plain words only.
    var sentence by remember { mutableStateOf("connecting") }
    var muted by remember { mutableStateOf(false) }
    var turn by remember { mutableStateOf(Floor.State.IDLE) }
    var edge by remember { mutableStateOf(0f) }

    LaunchedEffect(s) {
        while (true) {
            sentence = when {
                !s.crypto.established -> "connecting"
                s.ended -> "they left"
                s.peerMuted -> "they are muted"
                else -> "connected"
            }
            turn = s.floor.state
            edge = if (s.gate.voicingNow) 1f else 0f
            delay(100)
        }
    }

    Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.height(24.dp))
        // The speaking edge: colour is whose turn, and it is never dark.
        Box(
            Modifier.fillMaxWidth().height(if (turn == Floor.State.MINE) 6.dp else 4.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(when (turn) {
                    Floor.State.MINE -> Glass.ok.copy(alpha = 0.35f + 0.65f * edge)
                    Floor.State.THEIRS -> Glass.accent.copy(alpha = 0.85f)
                    else -> Glass.fill(0.14f)
                })
        )
        Spacer(Modifier.weight(1f))
        Text(s.room, color = Glass.fg, fontSize = 30.sp, fontWeight = FontWeight.Light)
        Spacer(Modifier.height(10.dp))
        Text(sentence, color = Glass.fg.copy(alpha = 0.6f), fontSize = 16.sp)
        s.safetyCode?.let {
            Spacer(Modifier.height(18.dp))
            Text(it, color = Glass.fg.copy(alpha = 0.45f), fontSize = 14.sp)
            Text("read this aloud to check nobody is in the middle",
                color = Glass.fg.copy(alpha = 0.3f), fontSize = 12.sp, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Button(
                onClick = { muted = !muted; s.selfMuted = muted },
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (muted) Glass.warn else Glass.fill(0.12f),
                    contentColor = if (muted) Glass.bg else Glass.fg),
                shape = CircleShape, modifier = Modifier.height(56.dp),
            ) { Text(if (muted) "Muted" else "Mic") }
            Button(
                onClick = onLeave,
                colors = ButtonDefaults.buttonColors(
                    containerColor = Glass.destructive, contentColor = Glass.fg),
                shape = CircleShape, modifier = Modifier.height(56.dp),
            ) { Text("Leave") }
        }
        Spacer(Modifier.height(20.dp))
    }
}
