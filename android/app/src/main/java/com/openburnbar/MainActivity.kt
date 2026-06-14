package com.openburnbar

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import com.openburnbar.services.media.AgentReplyNotificationState
import androidx.fragment.app.FragmentActivity
import com.openburnbar.security.enableOpenBurnBarScreenPrivacy
import com.openburnbar.ui.navigation.BurnBarNavHost
import com.openburnbar.ui.theme.AuroraTheme

class MainActivity : FragmentActivity() {
    /**
     * POST_NOTIFICATIONS runtime-permission launcher. Mirrors the
     * [HermesSquareVoiceSheet] microphone pattern: registered up front, the
     * grant result is persisted so the cloud fan-out (and the device doc's
     * `agentNotificationsEnabled`) reflects the real OS permission state instead
     * of a hardcoded `true`.
     */
    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            AgentReplyNotificationState.recordPermissionResult(applicationContext, granted)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableOpenBurnBarScreenPrivacy()
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
        )
        WindowCompat.setDecorFitsSystemWindows(window, false)
        requestNotificationPermissionIfNeeded()
        handleIntent(intent)
        setContent {
            AuroraTheme {
                BurnBarNavHost()
            }
        }
    }

    /**
     * On Android 13+ (TIRAMISU) POST_NOTIFICATIONS is a runtime permission; the
     * manifest declaration alone delivers nothing. Without this prompt every
     * agent-reply and Mercury-call notification is silently suppressed by the
     * OS while the backend marks the push "sent". Request it once at the first
     * notification-relevant entry point (app open). Pre-13 the permission is
     * granted at install time, so the launcher persists the granted state
     * directly.
     */
    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            AgentReplyNotificationState.recordPermissionResult(applicationContext, granted = true)
            return
        }
        val alreadyGranted =
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        if (alreadyGranted) {
            AgentReplyNotificationState.recordPermissionResult(applicationContext, granted = true)
            return
        }
        notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        // T-AND-03: this Activity is exported + BROWSABLE, so any app or web link can hand
        // it a `burnbar://...` VIEW intent. Validate/whitelist the host + dynamic segments
        // before the nav host consumes the deep link; drop a hostile/malformed link rather
        // than route it into a screen. Non-`burnbar` data and in-app (no data) intents pass
        // through unchanged.
        if (intent != null && Intent.ACTION_VIEW == intent.action) {
            val data = intent.data
            if (data != null && !isAllowedBurnBarDeepLink(data)) {
                intent.data = null
                return
            }
        }
        MainActivityIntentActions.stashPendingPromptFromIntent(intent)
        MainActivityE2EMissionActions.launchFromIntent(this, intent)
        MainActivityE2EHermesActions.launchFromIntent(this, intent)
        MainActivityE2EComputerUseActions.launchFromIntent(this, intent)
    }

    private fun isAllowedBurnBarDeepLink(data: android.net.Uri): Boolean =
        BurnBarDeepLinkValidator.isAllowed(
            scheme = data.scheme,
            host = data.host,
            pathSegments = data.pathSegments.orEmpty(),
        )

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
