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
import androidx.fragment.app.FragmentActivity
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.policy.MobileNavigationDecision
import com.openburnbar.data.policy.MobileOsDestination
import com.openburnbar.data.policy.MobileOsIntegrationPolicy
import com.openburnbar.security.enableOpenBurnBarScreenPrivacy
import com.openburnbar.services.media.AgentReplyNotificationState
import com.openburnbar.services.media.bindConsumedEvents
import com.openburnbar.services.media.persistConsumed
import com.openburnbar.ui.auth.LaunchSplashGate
import com.openburnbar.ui.navigation.BurnBarNavHost
import com.openburnbar.ui.theme.AuroraTheme
import com.openburnbar.wallpaper.livingthemes.LivingThemeIntent
import com.openburnbar.wallpaper.livingthemes.LivingThemesActivity

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
        if (routeLivingThemeIntent(intent)) return
        enableOpenBurnBarScreenPrivacy()
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
        )
        WindowCompat.setDecorFitsSystemWindows(window, false)
        requestNotificationPermissionIfNeeded()
        AgentReplyNotificationState.bindConsumedEvents(currentUid(), applicationContext)
        handleIntent(intent)
        setContent {
            AuroraTheme {
                LaunchSplashGate {
                    BurnBarNavHost()
                }
                // First-run, opt-in analytics consent prompt. Renders only while
                // consent is unset; declining or ignoring keeps analytics dark.
                com.openburnbar.ui.analytics.AnalyticsConsentPrompt()
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
        if (routeLivingThemeIntent(intent)) return
        enableOpenBurnBarScreenPrivacy()
        handleIntent(intent, warmStart = true)
    }

    private fun routeLivingThemeIntent(intent: Intent?): Boolean {
        if (LivingThemeIntent.parse(intent?.dataString) == null) return false
        startActivity(
            Intent(this, LivingThemesActivity::class.java)
                .setData(intent?.data),
        )
        finish()
        return true
    }

    private fun handleIntent(intent: Intent?, warmStart: Boolean = false) {
        MainActivityIntentActions.stashPendingPromptFromIntent(intent)
        routeDeepLink(intent, warmStart)
        MainActivityE2EMissionActions.launchFromIntent(this, intent)
        MainActivityE2EHermesActions.launchFromIntent(this, intent)
        MainActivityE2EComputerUseActions.launchFromIntent(this, intent)
    }

    /**
     * Captures the item id carried by a `burnbar://inbox/{itemId}` link.
     *
     * Navigation owns the *destination*: both `burnbar://inbox` and
     * `burnbar://inbox/{itemId}` are declared as `navDeepLink` patterns on the
     * Inbox composable (see `BurnBarNavHostSections.kt`), so Navigation matches
     * the launch intent and lands on the tab for free.
     *
     * What Navigation cannot do is *select the row*: the id addresses a
     * Firestore document that has not been fetched or decrypted yet when the
     * intent is routed. So the id is stashed here and
     * [com.openburnbar.ui.inbox.InboxScreen] claims it once its rows exist.
     *
     * Navigation also cannot handle the WARM case at all: `navDeepLink`
     * matching runs against the launch intent only, so a link delivered via
     * [onNewIntent] would stash the id and then leave the user on whatever tab
     * was open. For warm intents [InboxPendingNavigation] asks the nav host to
     * move to the Inbox tab itself.
     */
    private fun routeDeepLink(intent: Intent?, warmStart: Boolean) {
        val routed = MobileOsIntegrationPolicy.route(intent?.dataString)
        val eventId = intent?.getStringExtra(EXTRA_EVENT_ID)?.takeIf { it.isNotBlank() }
        val envelopePayload = MobileOsIntentNavigation.payloadFrom(intent)
        if (MobileOsIntentNavigation.hasPushEnvelope(envelopePayload)) {
            val decision = MobileOsIntentNavigation.navigation(
                payload = envelopePayload,
                activeUid = currentUid(),
                lastConsumedEventId = AgentReplyNotificationState.lastConsumedEventId,
            )
            if (decision != MobileNavigationDecision.NAVIGATE) return
        }
        persistConsumedIfPresent(eventId)
        when (routed.destination) {
            MobileOsDestination.INBOX -> {
                // The policy hands back a raw path segment; [BurnBarDeepLink] is
                // the parser that bounds and sanitizes it before it becomes a
                // lookup key or an Intent extra.
                InboxPendingItem.stash((BurnBarDeepLink.parseIntent(intent) as? BurnBarDeepLinkRoute.Inbox)?.itemId)
                if (warmStart) InboxPendingNavigation.request()
            }
            MobileOsDestination.MISSION -> {
                routed.missionId?.let { MobileMissionConsoleHost.shared().focusMission(it) }
                if (warmStart) OsPendingNavigation.request(routed, eventId)
            }
            MobileOsDestination.BURN,
            MobileOsDestination.MERCURY_CALL,
            -> if (warmStart) OsPendingNavigation.request(routed, eventId)
            MobileOsDestination.DEVICES ->
                // Devices is not a nav-graph destination, so cold and warm
                // taps both stash. YouView claims the request and opens
                // Connected Devices without auto-approving.
                OsPendingNavigation.request(routed, eventId)
            else -> Unit
        }
    }

    private fun currentUid(): String? = FirebaseAuth.getInstance().currentUser?.uid

    private fun persistConsumedIfPresent(eventId: String?) {
        if (eventId.isNullOrBlank()) return
        AgentReplyNotificationState.persistConsumed(eventId, currentUid(), applicationContext)
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
        const val EXTRA_EVENT_ID = "event_id"
        const val EXTRA_UID = "uid"
        const val EXTRA_EXPIRES_AT_MILLIS = "expires_at_millis"
        const val EXTRA_CREATED_AT_MILLIS = "created_at_millis"
        const val EXTRA_PUSH_TYPE = "type"
    }
}
