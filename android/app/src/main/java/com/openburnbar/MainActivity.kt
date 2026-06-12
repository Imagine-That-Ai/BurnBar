package com.openburnbar

import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.view.WindowCompat
import androidx.fragment.app.FragmentActivity
import com.openburnbar.ui.navigation.BurnBarNavHost
import com.openburnbar.ui.theme.AuroraTheme

class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
        )
        WindowCompat.setDecorFitsSystemWindows(window, false)
        handleIntent(intent)
        setContent {
            AuroraTheme {
                BurnBarNavHost()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        MainActivityIntentActions.stashPendingPromptFromIntent(intent)
        MainActivityE2EMissionActions.launchFromIntent(this, intent)
        MainActivityE2EHermesActions.launchFromIntent(this, intent)
        MainActivityE2EComputerUseActions.launchFromIntent(this, intent)
    }

    companion object {
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
        const val EXTRA_E2E_COMPUTER_USE = "openburnbar.e2e.computerUse"
        const val EXTRA_E2E_COMPUTER_USE_CONNECTION_ID = "openburnbar.e2e.computerUseConnectionId"
        const val EXTRA_E2E_COMPUTER_USE_INTENT_COUNT = "openburnbar.e2e.computerUseIntentCount"
        const val EXTRA_E2E_COMPUTER_USE_INTENT_INTERVAL_MILLIS = "openburnbar.e2e.computerUseIntentIntervalMillis"
        const val EXTRA_E2E_COMPUTER_USE_SEND_PANIC = "openburnbar.e2e.computerUseSendPanic"
        const val EXTRA_E2E_COMPUTER_USE_REPLAY_COUNT = "openburnbar.e2e.computerUseReplayCount"
        const val EXTRA_E2E_COMPUTER_USE_TAMPER_COUNT = "openburnbar.e2e.computerUseTamperCount"
        const val EXTRA_E2E_COMPUTER_USE_TAMPER_TIMESTAMP_STEP_MILLIS = "openburnbar.e2e.computerUseTamperTimestampStepMillis"
        const val EXTRA_E2E_COMPUTER_USE_APPROVAL_PROOF = "openburnbar.e2e.computerUseApprovalProof"
    }
}
