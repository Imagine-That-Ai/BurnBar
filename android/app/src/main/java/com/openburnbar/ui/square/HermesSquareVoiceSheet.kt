package com.openburnbar.ui.square

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import com.openburnbar.data.square.AgentIdentityRegistry

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HermesSquareVoiceSheet(
    registry: AgentIdentityRegistry,
    currentThreadAgentURI: String? = null,
    onIntent: (AndroidVoiceIntent) -> Unit,
    onDismiss: () -> Unit,
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
                PackageManager.PERMISSION_GRANTED,
        )
    }
    val permissionLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            permissionGranted = granted
            if (!granted) {
                errorMessage = "Voice access denied. Grant microphone permission in Settings to use voice commands."
            }
        }

    LaunchedEffect(Unit) {
        if (!permissionGranted) permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
    }
    DisposableEffect(Unit) { onDispose { recognizer.destroy() } }

    val nameMap = registry.identities.associateBy({ it.displayName.lowercase() }, { it.id })

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = state, containerColor = MaterialTheme.colorScheme.surface) {
        VoiceSheetContent(
            state =
            VoiceSheetCaptureState(
                listening = listening,
                transcript = transcript,
                permissionGranted = permissionGranted,
                recognizer = recognizer,
                errorMessage = errorMessage,
            ),
            callbacks =
            VoiceHoldToTalkCallbacks(
                onListeningChange = { listening = it },
                onTranscriptChange = { transcript = it },
                onCaptureError = { errorMessage = it },
                onCaptureStart = {
                    errorMessage = null
                    transcript = ""
                },
                onReleaseWithTranscript = { finalTranscript ->
                    val intent =
                        resolveVoiceIntentOnRelease(finalTranscript, nameMap, currentThreadAgentURI)
                            ?: return@VoiceHoldToTalkCallbacks
                    onIntent(intent)
                    onDismiss()
                },
            ),
        )
    }
}

internal fun beginCapture(recognizer: SpeechRecognizer, onPartial: (String) -> Unit, onFailure: (String) -> Unit) {
    val intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }
    recognizer.setRecognitionListener(
        object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onError(error: Int) {
                onFailure(
                    when (error) {
                        SpeechRecognizer.ERROR_AUDIO -> "Audio unavailable."
                        SpeechRecognizer.ERROR_NO_MATCH -> "Couldn't hear that — try again."
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission denied."
                        SpeechRecognizer.ERROR_NETWORK -> "Speech recognition needs network. Reconnect and try."
                        else -> "Speech recognition failed (#$error)."
                    },
                )
            }
            override fun onResults(results: Bundle?) {
                results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let(onPartial)
            }
            override fun onPartialResults(partial: Bundle?) {
                partial?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let(onPartial)
            }
            override fun onEvent(eventType: Int, params: Bundle?) {}
        },
    )
    recognizer.startListening(intent)
}

sealed class AndroidVoiceIntent {
    data class SendMessageToCurrentThread(val text: String) : AndroidVoiceIntent()
    data class OpenAgent(val agentURI: String) : AndroidVoiceIntent()
    data class DispatchMission(val prompt: String, val runtimeHint: String?) : AndroidVoiceIntent()
    data class Search(val query: String) : AndroidVoiceIntent()
    object AmbientBriefing : AndroidVoiceIntent()
    data class FallbackToHermes(val text: String) : AndroidVoiceIntent()

    val displayLabel: String get() =
        when (this) {
            is SendMessageToCurrentThread -> "Reply to current thread"
            is OpenAgent -> "Open agent"
            is DispatchMission -> "Dispatch mission"
            is Search -> "Search"
            is AmbientBriefing -> "Ambient briefing"
            is FallbackToHermes -> "Ask Hermes"
        }
}

object AndroidVoiceIntentResolver {
    fun resolve(transcript: String, installedAgentNames: Map<String, String>, currentThreadAgentURI: String? = null): AndroidVoiceIntent {
        val cleaned = transcript.trim()
        if (cleaned.isEmpty()) return AndroidVoiceIntent.FallbackToHermes("")
        return resolveNonEmpty(cleaned, installedAgentNames, currentThreadAgentURI)
    }

    private fun resolveNonEmpty(cleaned: String, installedAgentNames: Map<String, String>, currentThreadAgentURI: String?): AndroidVoiceIntent {
        val lower = cleaned.lowercase()
        val ambientPhrases = listOf("what's important", "whats important", "what is important", "give me the briefing", "ambient briefing", "what's new", "whats new")
        if (ambientPhrases.any { lower.contains(it) }) return AndroidVoiceIntent.AmbientBriefing
        val searchPrefix = listOf("search for ", "search ", "find me ", "find ").firstOrNull { lower.startsWith(it) }
        if (searchPrefix != null) return AndroidVoiceIntent.Search(cleaned.drop(searchPrefix.length).trim())
        val openIntent =
            listOf("open ", "show me ", "switch to ").firstNotNullOfOrNull { prefix ->
                if (!lower.startsWith(prefix)) return@firstNotNullOfOrNull null
                installedAgentNames[cleaned.drop(prefix.length).trim().lowercase()]?.let { AndroidVoiceIntent.OpenAgent(it) }
            }
        return resolveDispatchMission(lower, cleaned, installedAgentNames)
            ?: openIntent
            ?: if (currentThreadAgentURI != null) AndroidVoiceIntent.SendMessageToCurrentThread(cleaned) else AndroidVoiceIntent.FallbackToHermes(cleaned)
    }

    private fun resolveDispatchMission(lower: String, cleaned: String, installedAgentNames: Map<String, String>): AndroidVoiceIntent.DispatchMission? {
        if (lower.startsWith("dispatch ")) {
            val sepIdx = lower.indexOf(" to ", startIndex = "dispatch ".length)
            if (sepIdx >= 0) {
                val first = cleaned.substring("dispatch ".length, sepIdx).trim()
                val second = cleaned.substring(sepIdx + " to ".length).trim()
                return AndroidVoiceIntent.DispatchMission(first, installedAgentNames[second.lowercase()] ?: second.lowercase())
            }
        }
        for ((prefix, sep) in listOf("have " to " run ", "ask " to " to ")) {
            if (lower.startsWith(prefix)) {
                val sepIdx = lower.indexOf(sep, startIndex = prefix.length)
                if (sepIdx >= 0) {
                    val first = cleaned.substring(prefix.length, sepIdx).trim()
                    val second = cleaned.substring(sepIdx + sep.length).trim()
                    return AndroidVoiceIntent.DispatchMission(second, installedAgentNames[first.lowercase()] ?: first.lowercase())
                }
            }
        }
        return null
    }
}
