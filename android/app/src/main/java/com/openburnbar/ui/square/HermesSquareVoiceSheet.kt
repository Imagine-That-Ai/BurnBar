package com.openburnbar.ui.square

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.openburnbar.data.square.AgentIdentityRegistry

// MARK: - Hermes Square Voice Sheet (Hermes Square §6.7)
//
// Android parity of `VoiceCommandSurface.swift`. Press-and-hold the mic
// to record; release to resolve the transcript into a `VoiceIntent` via
// `AndroidVoiceIntentResolver`. Uses `SpeechRecognizer` rather than
// Whisper-on-device — first-class API on every modern Android, zero
// model download, identical "hold to talk" ergonomics.
//
// Permissions: `RECORD_AUDIO` requested at first invocation via the
// Activity-result API. Denied path surfaces a clear message and a deep
// link to settings is intentionally NOT offered (anti-pattern).

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareVoiceSheet(
    registry: AgentIdentityRegistry,
    currentThreadAgentURI: String? = null,
    onIntent: (AndroidVoiceIntent) -> Unit,
    onDismiss: () -> Unit
) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = LocalContext.current
    val recognizer = remember { SpeechRecognizer.createSpeechRecognizer(context) }
    var transcript by remember { mutableStateOf("") }
    var listening by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var permissionGranted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        )
    }
    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        permissionGranted = granted
        if (!granted) {
            errorMessage = "Voice access denied. Grant microphone permission in Settings to use voice commands."
        }
    }

    LaunchedEffect(Unit) {
        if (!permissionGranted) {
            permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    DisposableEffect(Unit) {
        onDispose { recognizer.destroy() }
    }

    val nameMap = registry.identities.associateBy(
        keySelector = { it.displayName.lowercase() },
        valueTransform = { it.id }
    )

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = MaterialTheme.colorScheme.surface
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp, vertical = 18.dp)
        ) {
            Text(
                "Voice command",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Spacer(modifier = Modifier.height(8.dp))

            // Transcript box
            Surface(
                shape = RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(14.dp)) {
                    Text(
                        if (listening) "Listening…" else "Hold to talk",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        if (transcript.isBlank())
                            "Try \"open Claude\", \"dispatch the brief to Codex\", or \"what's important?\""
                        else transcript,
                        fontSize = 14.sp,
                        color = if (transcript.isBlank())
                            MaterialTheme.colorScheme.onSurfaceVariant
                        else MaterialTheme.colorScheme.onSurface
                    )
                }
            }

            Spacer(modifier = Modifier.height(18.dp))

            // Hold-to-talk button
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(120.dp)
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(if (listening) 104.dp else 96.dp)
                        .clip(RoundedCornerShape(50))
                        .background(
                            Brush.linearGradient(
                                listOf(
                                    Color(0xFFF45B69),
                                    Color(0xFFFFA800)
                                )
                            )
                        )
                        .pointerInput(permissionGranted) {
                            awaitPointerEventScope {
                                while (true) {
                                    val event = awaitPointerEvent()
                                    val pressed = event.changes.any { it.pressed }
                                    if (pressed && !listening && permissionGranted) {
                                        beginCapture(
                                            recognizer = recognizer,
                                            onPartial = { transcript = it },
                                            onFailure = { msg ->
                                                errorMessage = msg
                                                listening = false
                                            }
                                        )
                                        listening = true
                                        errorMessage = null
                                        transcript = ""
                                    } else if (!pressed && listening) {
                                        listening = false
                                        recognizer.stopListening()
                                        val finalTranscript = transcript
                                        if (finalTranscript.isNotBlank()) {
                                            val intent = AndroidVoiceIntentResolver.resolve(
                                                transcript = finalTranscript,
                                                installedAgentNames = nameMap,
                                                currentThreadAgentURI = currentThreadAgentURI
                                            )
                                            onIntent(intent)
                                            onDismiss()
                                        }
                                    }
                                }
                            }
                        }
                ) {
                    Icon(
                        imageVector = Icons.Filled.Mic,
                        contentDescription = "Hold to talk",
                        tint = Color.White,
                        modifier = Modifier.size(36.dp)
                    )
                }
            }

            errorMessage?.let { msg ->
                Spacer(modifier = Modifier.height(12.dp))
                Text(
                    msg,
                    color = MaterialTheme.colorScheme.error,
                    fontSize = 12.sp
                )
            }
        }
    }
}

// MARK: - SpeechRecognizer plumbing

private fun beginCapture(
    recognizer: SpeechRecognizer,
    onPartial: (String) -> Unit,
    onFailure: (String) -> Unit
) {
    val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
    }
    recognizer.setRecognitionListener(object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onError(error: Int) {
            val msg = when (error) {
                SpeechRecognizer.ERROR_AUDIO -> "Audio unavailable."
                SpeechRecognizer.ERROR_NO_MATCH -> "Couldn't hear that — try again."
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission denied."
                SpeechRecognizer.ERROR_NETWORK -> "Speech recognition needs network. Reconnect and try."
                else -> "Speech recognition failed (#$error)."
            }
            onFailure(msg)
        }
        override fun onResults(results: Bundle?) {
            val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION) ?: emptyList()
            if (list.isNotEmpty()) onPartial(list[0])
        }
        override fun onPartialResults(partial: Bundle?) {
            val list = partial?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION) ?: emptyList()
            if (list.isNotEmpty()) onPartial(list[0])
        }
        override fun onEvent(eventType: Int, params: Bundle?) {}
    })
    recognizer.startListening(intent)
}

// MARK: - VoiceIntent (Android parity of Swift VoiceIntent)

sealed class AndroidVoiceIntent {
    data class SendMessageToCurrentThread(val text: String) : AndroidVoiceIntent()
    data class OpenAgent(val agentURI: String) : AndroidVoiceIntent()
    data class DispatchMission(val prompt: String, val runtimeHint: String?) : AndroidVoiceIntent()
    data class Search(val query: String) : AndroidVoiceIntent()
    object AmbientBriefing : AndroidVoiceIntent()
    data class FallbackToHermes(val text: String) : AndroidVoiceIntent()

    val displayLabel: String get() = when (this) {
        is SendMessageToCurrentThread -> "Reply to current thread"
        is OpenAgent -> "Open agent"
        is DispatchMission -> "Dispatch mission"
        is Search -> "Search"
        is AmbientBriefing -> "Ambient briefing"
        is FallbackToHermes -> "Ask Hermes"
    }
}

object AndroidVoiceIntentResolver {
    fun resolve(
        transcript: String,
        installedAgentNames: Map<String, String>,
        currentThreadAgentURI: String? = null
    ): AndroidVoiceIntent {
        val cleaned = transcript.trim()
        if (cleaned.isEmpty()) return AndroidVoiceIntent.FallbackToHermes("")
        val lower = cleaned.lowercase()

        val ambient = listOf(
            "what's important", "whats important", "what is important",
            "give me the briefing", "ambient briefing", "what's new", "whats new"
        )
        if (ambient.any { lower.contains(it) }) return AndroidVoiceIntent.AmbientBriefing

        listOf("search for ", "search ", "find me ", "find ").firstOrNull { lower.startsWith(it) }?.let { prefix ->
            val query = cleaned.drop(prefix.length).trim()
            return AndroidVoiceIntent.Search(query)
        }

        listOf("open ", "show me ", "switch to ").forEach { prefix ->
            if (lower.startsWith(prefix)) {
                val name = cleaned.drop(prefix.length).trim().lowercase()
                installedAgentNames[name]?.let { return AndroidVoiceIntent.OpenAgent(it) }
            }
        }

        // dispatch X to Y
        if (lower.startsWith("dispatch ")) {
            val sepIdx = lower.indexOf(" to ", startIndex = "dispatch ".length)
            if (sepIdx >= 0) {
                val first = cleaned.substring("dispatch ".length, sepIdx).trim()
                val second = cleaned.substring(sepIdx + " to ".length).trim()
                val hint = installedAgentNames[second.lowercase()] ?: second.lowercase()
                return AndroidVoiceIntent.DispatchMission(prompt = first, runtimeHint = hint)
            }
        }

        // have X run Y / ask X to Y
        for ((prefix, sep) in listOf("have " to " run ", "ask " to " to ")) {
            if (lower.startsWith(prefix)) {
                val sepIdx = lower.indexOf(sep, startIndex = prefix.length)
                if (sepIdx >= 0) {
                    val first = cleaned.substring(prefix.length, sepIdx).trim()
                    val second = cleaned.substring(sepIdx + sep.length).trim()
                    val hint = installedAgentNames[first.lowercase()] ?: first.lowercase()
                    return AndroidVoiceIntent.DispatchMission(prompt = second, runtimeHint = hint)
                }
            }
        }

        return if (currentThreadAgentURI != null) {
            AndroidVoiceIntent.SendMessageToCurrentThread(cleaned)
        } else {
            AndroidVoiceIntent.FallbackToHermes(cleaned)
        }
    }
}
