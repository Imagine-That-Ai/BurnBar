package com.openburnbar

import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.lifecycleScope
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.hermes.HermesConnectionMode
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.assistants.PiPendingPrompt
import com.openburnbar.ui.navigation.BurnBarNavHost
import com.openburnbar.ui.navigation.HermesPendingPrompt
import com.openburnbar.ui.theme.AuroraTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        stashPendingPromptFromIntent(intent)
        launchE2EMissionFromIntent(intent)
        launchE2EHermesIrohFromIntent(intent)
        setContent {
            AuroraTheme {
                BurnBarNavHost()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        stashPendingPromptFromIntent(intent)
        launchE2EMissionFromIntent(intent)
        launchE2EHermesIrohFromIntent(intent)
    }

    /**
     * Read the optional "assistant" + "prompt" hint from a launch / new
     * intent and stash the prompt into the matching pending-prompt
     * singleton. Both intent forms are accepted:
     *
     *   • Direct extras: `EXTRA_ASSISTANT` ("hermes" | "pi") + `EXTRA_PROMPT`.
     *     Widget chips use this path via `actionStartActivity(Intent.putExtra)`.
     *   • Deep-link URI: `burnbar://hermes?prompt=…` or `burnbar://pi?prompt=…`,
     *     also `burnbar://assistants?runtime=pi&prompt=…`. Adb / external
     *     deep links use this path.
     *
     * The assistant tab destination itself is resolved by the existing
     * deep-link route in `BurnBarNavHost`; this hook only owns the
     * prompt-stash side of the bridge.
     */
    private fun stashPendingPromptFromIntent(intent: Intent?) {
        if (intent == null) return
        val prompt = readPromptHint(intent)?.takeIf { it.isNotBlank() } ?: return
        val assistant = readAssistantHint(intent)
        if (assistant == ASSISTANT_PI) {
            PiPendingPrompt.pending = prompt
        } else {
            HermesPendingPrompt.pending = prompt
        }
    }

    private fun readAssistantHint(intent: Intent): String {
        intent.getStringExtra(EXTRA_ASSISTANT)?.lowercase()?.let { return it }
        intent.data?.let { uri ->
            uri.getQueryParameter("runtime")?.lowercase()?.let { return it }
            // `burnbar://pi` and `burnbar://hermes` both encode runtime in
            // the host segment — fall back to that when no explicit hint
            // is present.
            uri.host?.lowercase()?.let { host ->
                if (host == ASSISTANT_PI || host == ASSISTANT_HERMES) return host
            }
        }
        return ASSISTANT_HERMES
    }

    private fun readPromptHint(intent: Intent): String? {
        intent.getStringExtra(EXTRA_PROMPT)?.let { return it }
        return intent.data?.getQueryParameter("prompt")
    }

    private fun launchE2EMissionFromIntent(intent: Intent?) {
        if (!BuildConfig.DEBUG || intent?.getBooleanExtra(EXTRA_E2E_LAUNCH_MISSION, false) != true) return
        lifecycleScope.launch {
            val auth = FirebaseAuth.getInstance()
            val expectedUid = intent.getStringExtra(EXTRA_E2E_FIREBASE_UID)
            if (expectedUid.isNullOrBlank() || auth.currentUser?.uid != expectedUid) {
                val email = intent.getStringExtra(EXTRA_E2E_FIREBASE_EMAIL)?.takeIf { it.isNotBlank() }
                val password = intent.getStringExtra(EXTRA_E2E_FIREBASE_PASSWORD)?.takeIf { it.isNotBlank() }
                if (email == null || password == null) return@launch
                auth.signInWithEmailAndPassword(email, password).await()
            }

            CLIAgentMissionDispatcher().dispatch(
                title = "Android E2E Mission",
                prompt = intent.getStringExtra(EXTRA_E2E_MISSION_PROMPT)?.takeIf { it.isNotBlank() } ?: "android ok",
                missionKind = "custom",
                requestedRuntime = intent.getStringExtra(EXTRA_E2E_MISSION_RUNTIME)?.takeIf { it.isNotBlank() } ?: "openclaw",
                targetProject = intent.getStringExtra(EXTRA_E2E_MISSION_TARGET)?.takeIf { it.isNotBlank() },
                depth = "standard",
                approvalMode = "read_only",
                commandsAllowed = false,
                fileEditsAllowed = false,
            )
        }
    }

    private fun launchE2EHermesIrohFromIntent(intent: Intent?) {
        if (!BuildConfig.DEBUG || intent?.getBooleanExtra(EXTRA_E2E_HERMES_IROH, false) != true) return
        lifecycleScope.launch {
            val service = HermesService(appContext = applicationContext)
            try {
                val auth = FirebaseAuth.getInstance()
                val expectedUid = intent.getStringExtra(EXTRA_E2E_FIREBASE_UID)
                if (expectedUid.isNullOrBlank() || auth.currentUser?.uid != expectedUid) {
                    val email = intent.getStringExtra(EXTRA_E2E_FIREBASE_EMAIL)?.takeIf { it.isNotBlank() }
                    val password = intent.getStringExtra(EXTRA_E2E_FIREBASE_PASSWORD)?.takeIf { it.isNotBlank() }
                    if (email == null || password == null) {
                        throw IllegalStateException("Android Hermes iroh E2E requires the expected Firebase user to already be signed in, or email/password extras.")
                    }
                    auth.signInWithEmailAndPassword(email, password).await()
                }

                service.refreshRelayConnections()
                val requestedConnectionId = intent.getStringExtra(EXTRA_E2E_HERMES_CONNECTION_ID)
                    ?.takeIf { it.isNotBlank() }
                val relay = service.connections.value.firstOrNull {
                    it.mode == HermesConnectionMode.RELAY_LINK &&
                        (requestedConnectionId == null || it.id == requestedConnectionId)
                } ?: throw IllegalStateException("No Hermes relay-link connection is available for Android E2E.")
                service.selectConnection(relay)
                delay(750)

                val modelExtra = intent.getStringExtra(EXTRA_E2E_HERMES_MODEL)?.trim().orEmpty()
                val model = modelExtra.takeIf { it.isNotBlank() && !it.equals("auto", ignoreCase = true) }
                    ?: relay.advertisedModel
                    ?: service.modelOptions.value.firstOrNull()?.modelID
                    ?: "hermes"
                val prompt = intent.getStringExtra(EXTRA_E2E_HERMES_PROMPT)
                    ?.takeIf { it.isNotBlank() }
                    ?: "Respond with exactly: android iroh ok"

                service.sendMessage(prompt, model)
                val deadline = System.currentTimeMillis() + ANDROID_HERMES_IROH_E2E_TIMEOUT_MILLIS
                while (System.currentTimeMillis() < deadline) {
                    val assistant = service.messages.value.lastOrNull { it.role == "assistant" }
                    if (assistant != null && !service.isStreaming.value) {
                        if (assistant.isError) throw IllegalStateException(assistant.content)
                        Log.i(TAG, "Android Hermes iroh E2E complete model=$model responseChars=${assistant.content.length}")
                        return@launch
                    }
                    delay(250)
                }
                throw IllegalStateException("Android Hermes iroh E2E timed out waiting for assistant response.")
            } catch (err: Throwable) {
                Log.e(TAG, "Android Hermes iroh E2E failed: ${err.message}", err)
            } finally {
                service.destroy()
            }
        }
    }

    companion object {
        private const val TAG = "BurnBarE2E"
        const val EXTRA_ASSISTANT = "burnbar.assistant"
        const val EXTRA_PROMPT = "burnbar.prompt"
        const val ASSISTANT_HERMES = "hermes"
        const val ASSISTANT_PI = "pi"
        const val EXTRA_E2E_LAUNCH_MISSION = "openburnbar.e2e.launchMission"
        const val EXTRA_E2E_FIREBASE_UID = "openburnbar.e2e.firebaseUid"
        const val EXTRA_E2E_FIREBASE_EMAIL = "openburnbar.e2e.firebaseEmail"
        const val EXTRA_E2E_FIREBASE_PASSWORD = "openburnbar.e2e.firebasePassword"
        const val EXTRA_E2E_MISSION_RUNTIME = "openburnbar.e2e.missionRuntime"
        const val EXTRA_E2E_MISSION_TARGET = "openburnbar.e2e.missionTarget"
        const val EXTRA_E2E_MISSION_PROMPT = "openburnbar.e2e.missionPrompt"
        const val EXTRA_E2E_HERMES_IROH = "openburnbar.e2e.hermesIroh"
        const val EXTRA_E2E_HERMES_CONNECTION_ID = "openburnbar.e2e.hermesConnectionId"
        const val EXTRA_E2E_HERMES_MODEL = "openburnbar.e2e.hermesModel"
        const val EXTRA_E2E_HERMES_PROMPT = "openburnbar.e2e.hermesPrompt"
        private const val ANDROID_HERMES_IROH_E2E_TIMEOUT_MILLIS = 600_000L
    }
}
