package com.openburnbar

import android.util.Log
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.crashlytics.FirebaseCrashlytics
import com.openburnbar.data.computeruse.AgentCapabilityGrantController
import com.openburnbar.data.computeruse.ComputerUseSessionGrantChallengeReceiver
import com.openburnbar.data.computeruse.ComputerUseSessionGrantNotificationCenter
import com.openburnbar.data.computeruse.ForegroundFragmentActivityTracker
import com.openburnbar.data.media.AndroidFileTransferService
import com.openburnbar.data.media.IrohBlobKeyStore
import com.openburnbar.data.media.MediaFileTransferService
import com.openburnbar.diagnostics.CrashReportingConsentStore
import com.openburnbar.irohrelay.OpenBurnBarIrohBlobFfiBackend
import com.openburnbar.remote.BurnBarRemoteBridge
import java.io.File
import java.security.MessageDigest

private const val LOG_CHALLENGE_ID_DIGEST_LENGTH = 16

private fun sha256Hex(value: String): String = MessageDigest.getInstance("SHA-256")
    .digest(value.toByteArray(Charsets.UTF_8))
    .joinToString("") { "%02x".format(it) }

/**
 * One-way digest used so logs can correlate challenge failures without ever
 * writing any portion of the raw challenge identifier to the log stream.
 */
private fun challengeIdLogDigest(challengeId: String): String = sha256Hex(challengeId).take(LOG_CHALLENGE_ID_DIGEST_LENGTH)

internal fun BurnBarApplication.installComputerUseSessionGrantReceiver() {
    ForegroundFragmentActivityTracker.install(this)
    val controller = AgentCapabilityGrantController(this)
    val notificationCenter = ComputerUseSessionGrantNotificationCenter(this)
    BurnBarApplication.agentCapabilityGrantController = controller
    BurnBarApplication.sessionGrantChallengeReceiver =
        ComputerUseSessionGrantChallengeReceiver(
            scope = BurnBarApplication.applicationScope,
            foregroundActivityProvider = { challengeId, expiresAtMillis ->
                ForegroundFragmentActivityTracker.current()
                    ?: run {
                        notificationCenter.showPendingChallenge(challengeId, expiresAtMillis)
                        try {
                            ForegroundFragmentActivityTracker.awaitResumedUntil(expiresAtMillis)
                        } finally {
                            notificationCenter.dismissPendingChallenge(challengeId)
                        }
                    }
            },
            grantHandler = { activity, delivery ->
                controller.grant(activity = activity, delivery = delivery)
            },
            failureHandler = { challenge, error ->
                Log.w(
                    "BurnBar",
                    "Session grant challenge failed " +
                        "idSha256=${challengeIdLogDigest(challenge.challengeId)}: ${error.message}",
                )
            },
        )
}

internal fun BurnBarApplication.installFileTransferService() {
    val blobKeyStore = IrohBlobKeyStore(applicationContext)
    val transferService =
        MediaFileTransferService(
            backend = OpenBurnBarIrohBlobFfiBackend(),
            configuration =
            MediaFileTransferService.Configuration(
                storeDirectory = File(filesDir, "mercury_blob_store"),
                inboxDirectory = File(filesDir, "mercury_blob_inbox"),
                secretKeyProvider = { blobKeyStore.secretKeyMaterial() },
            ),
        )
    registerFileTransferService(
        AndroidFileTransferService(
            appContext = applicationContext,
            service = transferService,
            settingsProvider = {
                getSharedPreferences("mercury_media", android.content.Context.MODE_PRIVATE)
                    .getBoolean("media_blob_transfer_enabled", true)
            },
        ),
    )
}

internal fun BurnBarApplication.logRemoteEngineReadiness() {
    val remoteReadiness = BurnBarRemoteBridge.readiness()
    Log.i(
        "BurnBar",
        "BurnBar remote engine readiness: protocol=${remoteReadiness.protocolVersion}, " +
            "native=${remoteReadiness.nativeBridgeAvailable}",
    )
}

internal fun BurnBarApplication.installDomainCoreShadowEvidence() {
    val domainCoreEvidenceChannel = com.openburnbar.data.DomainCoreBuildProfile.evidenceChannel()
    runCatching {
        if (domainCoreEvidenceChannel == null) {
            com.openburnbar.data.AndroidDomainCoreShadowEvidence.discardStoredSamples(this)
        } else {
            com.openburnbar.data.AndroidDomainCoreShadowEvidence.install(this, domainCoreEvidenceChannel)
        }
    }.onFailure { Log.w("BurnBar", "Domain-core evidence uploader disabled: ${it.message}") }
}

// Signal at-rest activation: AND the registry scheme with per-domain
// Remote Config enabled/required flags, mirroring iOS
// `MobileCloudVaultSignalPayloads.signalActivationState`. Source-aware
// and DEFAULT-OFF: a STATIC value (no remote value fetched, no in-app
// default registered) resolves false, so the producer path only emits
// Signal envelopes once an operator explicitly flips the flag true. The
// global (`signal_at_rest_v1_hard_kill`) and per-domain
// (`signal_at_rest_<id>_hard_kill`) hard-kill flags win over the enabled
// flag, matching the iOS/macOS activation readers — a hard kill flips
// every Android producer off without touching the per-domain ramp. Any
// Firebase failure also resolves OFF — Android stays fail-closed.
internal fun BurnBarApplication.installSignalAtRestActivationProvider() {
    com.openburnbar.data.cloud.AndroidCloudVaultSignalPayloads.signalAtRestActivationProvider = { domainID ->
        runCatching {
            val config = com.google.firebase.remoteconfig.FirebaseRemoteConfig.getInstance()
            val hardKill = config.getValue("signal_at_rest_v1_hard_kill").asBoolean() ||
                config.getValue("signal_at_rest_${domainID}_hard_kill").asBoolean()
            val enabledValue = config.getValue("signal_at_rest_${domainID}_enabled")
            val enabledValueIsStatic =
                enabledValue.source == com.google.firebase.remoteconfig.FirebaseRemoteConfig.VALUE_SOURCE_STATIC
            com.openburnbar.data.cloud.AndroidCloudVaultSignalPayloads.remoteActivationState(
                enabled = enabledValue.asBoolean(),
                required = config.getValue("signal_at_rest_${domainID}_required").asBoolean(),
                hardKill = hardKill,
                enabledValueIsStatic = enabledValueIsStatic,
            )
        }.getOrDefault(com.openburnbar.data.cloud.AndroidCloudVaultSignalPayloads.ActivationState.OFF)
    }
}

internal fun BurnBarApplication.installCrashReportingAndAnalytics() {
    // Crash reports are a separate diagnostics consent surface from opt-in
    // usage analytics. Default dark: a fresh install must not start
    // Crashlytics until the user turns on diagnostic crash reports.
    val crashlyticsEnabled = CrashReportingConsentStore.fromContext(this).isEnabled
    FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(crashlyticsEnabled)
    // Opt-in analytics: construct the consent-gated recorder and resume a
    // previously-consented session (no grant re-emit). Stays fully dark
    // until the user opts in AND an Amplitude key is configured — no SDK
    // construction, no network. Emits the session-start spine only when
    // already consented; first-run grant fires it from the consent prompt.
    runCatching {
        com.openburnbar.analytics.AnalyticsManager.initialize(this)
        val isFirstLaunch = detectFirstLaunch()
        com.openburnbar.analytics.AnalyticsManager.rememberLaunchContext(isFirstLaunch)
        com.openburnbar.analytics.AnalyticsManager.trackSessionStartIfConsented(isFirstLaunch)
        installAnalyticsIdentity()
    }.onFailure { Log.w("BurnBar", "Analytics init failed: ${it.message}") }
}

/**
 * First-launch detection for `app.session.started`'s `is_first_launch`.
 * A boolean marker in a private prefs file; flips to false after the first
 * read. Independent of analytics consent so the marker is correct whenever
 * the user eventually opts in. No PII — a single boolean.
 */
private fun BurnBarApplication.detectFirstLaunch(): Boolean {
    val prefs = getSharedPreferences("burnbar.analytics.lifecycle", android.content.Context.MODE_PRIVATE)
    val seen = prefs.getBoolean("has_launched_before", false)
    if (!seen) prefs.edit().putBoolean("has_launched_before", true).apply()
    return !seen
}

/**
 * Identify the signed-in user to analytics with a **hashed** account uid
 * (SHA-256, hex) — never the raw Firebase uid, email, or display name. The
 * recorder no-ops the call entirely until consent is granted, so nothing
 * leaks pre-opt-in. Cleared (`setUserId(null)`) on sign-out so a shared
 * device doesn't attribute one user's anonymous events to another.
 */
private fun installAnalyticsIdentity() {
    val listener = FirebaseAuth.AuthStateListener { auth ->
        val uid = auth.currentUser?.uid
        com.openburnbar.analytics.AnalyticsManager.setUserId(uid?.let { sha256Hex(it) })
    }
    FirebaseAuth.getInstance().addAuthStateListener(listener)
}
