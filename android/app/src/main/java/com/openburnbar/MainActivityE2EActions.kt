package com.openburnbar

import android.content.Intent
import android.util.Log
import androidx.lifecycle.lifecycleScope
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.hermes.HermesConnectionMode
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.hermes.refreshRelayConnections
import com.openburnbar.data.hermes.selectConnection
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal object MainActivityE2EMissionActions {
    fun launchFromIntent(activity: MainActivity, intent: Intent?) {
        if (!BuildConfig.DEBUG || intent?.getBooleanExtra(MainActivity.EXTRA_E2E_LAUNCH_MISSION, false) != true) return
        activity.lifecycleScope.launch {
            runCatching {
                MainActivityE2EAuth.ensureSignedIn(
                    intent,
                    "Android E2E mission requires the expected Firebase user to already be signed in, or email/password extras.",
                )
                CLIAgentMissionDispatcher().dispatch(
                    title = "Android E2E Mission",
                    prompt = intent.getStringExtra(MainActivity.EXTRA_E2E_MISSION_PROMPT)?.takeIf { it.isNotBlank() } ?: "android ok",
                    missionKind = "custom",
                    requestedRuntime = intent.getStringExtra(MainActivity.EXTRA_E2E_MISSION_RUNTIME)?.takeIf { it.isNotBlank() } ?: "openclaw",
                    targetProject = intent.getStringExtra(MainActivity.EXTRA_E2E_MISSION_TARGET)?.takeIf { it.isNotBlank() },
                    depth = "standard",
                    approvalMode = "read_only",
                    commandsAllowed = false,
                    fileEditsAllowed = false,
                )
            }.onFailure { err ->
                Log.e(MainActivityE2EConstants.TAG, "Android E2E mission failed: ${err.message}", err)
            }
        }
    }
}

internal object MainActivityE2EHermesActions {
    fun launchFromIntent(activity: MainActivity, intent: Intent?) {
        if (!BuildConfig.DEBUG || intent?.getBooleanExtra(MainActivity.EXTRA_E2E_HERMES_IROH, false) != true) return
        activity.lifecycleScope.launch {
            val service = HermesService(appContext = activity.applicationContext)
            try {
                MainActivityE2EAuth.ensureSignedIn(
                    intent,
                    "Android Hermes iroh E2E requires the expected Firebase user to already be signed in, or email/password extras.",
                )
                service.refreshRelayConnections()
                val requestedConnectionId =
                    intent.getStringExtra(MainActivity.EXTRA_E2E_HERMES_CONNECTION_ID)
                        ?.takeIf { it.isNotBlank() }
                val relay =
                    service.connections.value.firstOrNull {
                        it.mode == HermesConnectionMode.RELAY_LINK &&
                            (requestedConnectionId == null || it.id == requestedConnectionId)
                    } ?: error("No Hermes relay-link connection is available for Android E2E.")
                service.selectConnection(relay)
                delay(MainActivityE2EConstants.HERMES_IROH_CONNECT_DELAY_MILLIS)

                val model = resolveHermesModel(intent, service, relay)
                val prompt =
                    intent.getStringExtra(MainActivity.EXTRA_E2E_HERMES_PROMPT)
                        ?.takeIf { it.isNotBlank() }
                        ?: "Respond with exactly: android iroh ok"

                service.sendMessage(prompt, model)
                awaitHermesAssistantResponse(service, model)
            } catch (err: IllegalStateException) {
                Log.e(MainActivityE2EConstants.TAG, "Android Hermes iroh E2E failed: ${err.message}", err)
            } finally {
                service.destroy()
            }
        }
    }

    private suspend fun resolveHermesModel(intent: Intent, service: HermesService, relay: com.openburnbar.data.hermes.HermesConnectionRecord): String {
        val modelExtra = intent.getStringExtra(MainActivity.EXTRA_E2E_HERMES_MODEL)?.trim().orEmpty()
        return modelExtra.takeIf { it.isNotBlank() && !it.equals("auto", ignoreCase = true) }
            ?: relay.advertisedModel
            ?: service.modelOptions.value.firstOrNull()?.modelID
            ?: "hermes"
    }

    private suspend fun awaitHermesAssistantResponse(service: HermesService, model: String) {
        val deadline = System.currentTimeMillis() + MainActivityE2EConstants.HERMES_IROH_TIMEOUT_MILLIS
        while (System.currentTimeMillis() < deadline) {
            val assistant = service.messages.value.lastOrNull { it.role == "assistant" }
            if (assistant != null && !service.isStreaming.value) {
                if (assistant.isError) error(assistant.content)
                Log.i(
                    MainActivityE2EConstants.TAG,
                    "Android Hermes iroh E2E complete model=$model responseChars=${assistant.content.length}",
                )
                return
            }
            delay(MainActivityE2EConstants.HERMES_IROH_POLL_MILLIS)
        }
        error("Android Hermes iroh E2E timed out waiting for assistant response.")
    }
}

internal object MainActivityE2EConstants {
    const val TAG = "BurnBarE2E"
    const val HERMES_IROH_CONNECT_DELAY_MILLIS = 750L
    const val HERMES_IROH_POLL_MILLIS = 250L
    const val HERMES_IROH_TIMEOUT_MILLIS = 600_000L
    const val COMPUTER_USE_DIAL_TIMEOUT_MILLIS = 10_000L
    const val COMPUTER_USE_APPROVAL_TIMEOUT_MILLIS = 30_000L
    const val COMPUTER_USE_BURST_WARMUP_MILLIS = 800L
    const val COMPUTER_USE_CHAOS_SETTLE_MILLIS = 3_000L
    const val COMPUTER_USE_DEFAULT_INTENT_COUNT = 2
    const val COMPUTER_USE_MAX_INTENT_COUNT = 250
    const val COMPUTER_USE_DEFAULT_INTERVAL_MILLIS = 350L
    const val COMPUTER_USE_MAX_INTERVAL_MILLIS = 5_000L
    const val COMPUTER_USE_MAX_REPLAY_COUNT = 1_000
    const val COMPUTER_USE_MAX_TAMPER_COUNT = 100
    const val COMPUTER_USE_MAX_TAMPER_TIMESTAMP_STEP_MILLIS = 250L
    const val COMPUTER_USE_REPLAY_PROGRESS_INTERVAL = 100
    const val COMPUTER_USE_TAMPER_PROGRESS_INTERVAL = 20
    const val COMPUTER_USE_TAP_ORIGIN_NORMALIZED = 0.18
    const val COMPUTER_USE_TAP_OFFSET_STEP = 0.015
    const val COMPUTER_USE_TAP_MODULO_X = 5
    const val COMPUTER_USE_TAP_MODULO_Y = 3
    const val COMPUTER_USE_SCROLL_CENTER_X = 0.50
    const val COMPUTER_USE_SCROLL_START_Y = 0.62
    const val COMPUTER_USE_SCROLL_END_Y = 0.38
    const val COMPUTER_USE_TAMPER_TAP_X = 0.22
    const val COMPUTER_USE_TAMPER_OFFSET_BASE = 0.42
    const val COMPUTER_USE_TAMPER_OFFSET_STEP = 0.01
    const val COMPUTER_USE_TAMPER_MODULO = 5
    const val MILLIS_PER_SECOND = 1_000.0
    const val SWIFT_REFERENCE_EPOCH_OFFSET_SECONDS = 978_307_200.0
    const val MERCURY_NODE_ID_LOG_PREFIX_LENGTH = 12
}
