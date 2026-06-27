package com.openburnbar

import android.app.Application
import android.content.Context
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.appcheck.AppCheckProviderFactory
import com.google.firebase.appcheck.FirebaseAppCheck
import com.google.firebase.appcheck.playintegrity.PlayIntegrityAppCheckProviderFactory
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.crashlytics.FirebaseCrashlytics
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Query
import com.google.firebase.messaging.FirebaseMessaging
import com.openburnbar.data.budget.BudgetNotificationCenter
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingDirectory
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingPublicKeyProvider
import com.openburnbar.data.hermes.relay.HermesRelayKeyStore
import com.openburnbar.data.media.AndroidFileTransferService
import com.openburnbar.data.media.IrohBlobKeyStore
import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.data.media.MediaFileTransferService
import com.openburnbar.data.media.RetainedIrohControlTransportPool
import com.openburnbar.data.text.TextExpansionSyncWorker
import com.openburnbar.data.widget.BurnBarWidgetSnapshotStore
import com.openburnbar.data.widget.BurnBarWidgetSyncWorker
import com.openburnbar.diagnostics.CrashReportingConsentStore
import com.openburnbar.irohrelay.IrohDialTarget
import com.openburnbar.irohrelay.IrohPairingPublisher
import com.openburnbar.irohrelay.IrohRelayStream
import com.openburnbar.irohrelay.OpenBurnBarIrohBlobFfiBackend
import com.openburnbar.irohrelay.OpenBurnBarIrohFfiBackend
import com.openburnbar.irohrelay.OpenBurnBarIrohNativeContext
import com.openburnbar.remote.BurnBarRemoteBridge
import com.openburnbar.services.media.AgentReplyNotificationState
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.tasks.await

internal object IrohPairingSelection {
    /**
     * Server-side window for the pairing listener query. 3 — not 1 — so the
     * blank-connectionId / malformed-timestamp fallback in [newestCandidates]
     * stays reachable: a corrupt newest record falls back to the next valid
     * one instead of stopping the media coordinator.
     */
    const val QUERY_LIMIT = 3L

    data class Candidate(
        val connectionId: String,
        val publishedAtMillis: Long,
    )

    fun newest(documents: List<DocumentSnapshot>): Candidate? = newestCandidates(
        documents.mapNotNull { document ->
            val connectionId = document.getString("connectionId")
                ?: document.getString("id")
                ?: document.id
            val normalizedConnectionId = connectionId.trim().takeIf { it.isNotBlank() }
                ?: return@mapNotNull null
            Candidate(
                connectionId = normalizedConnectionId,
                publishedAtMillis = document.getLong("publishedAtMillis") ?: 0L,
            )
        },
    )

    fun newestCandidates(candidates: List<Candidate>): Candidate? = candidates
        .filter { it.connectionId.isNotBlank() }
        .maxWithOrNull(
            compareBy<Candidate> { it.publishedAtMillis }
                .thenBy { it.connectionId },
        )
}

class BurnBarApplication : Application() {
    companion object {
        lateinit var appContext: Context
            private set

        /**
         * Whether [onCreate] has installed [appContext] yet. `lateinit`'s
         * `::isInitialized` is only visible inside the declaring class, so
         * early-running singletons (e.g. the global visual settings store)
         * check this before touching context-backed prefs.
         */
        val isAppContextInitialized: Boolean
            get() = ::appContext.isInitialized

        /** App-process scope used for FCM token persistence and pairing listener bookkeeping. */
        internal val applicationScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        private const val IROH_PAIRING_COLLECTION = "iroh_pairing"
        private const val DEVICE_ID_PREF_NAME = "burnbar.device"
        private const val DEVICE_ID_PREF_KEY = "stable_device_id"
        private const val MEDIA_CONTROL_DIAL_TIMEOUT_MILLIS = 15_000L
        private const val LOG_NODE_ID_PREFIX_LENGTH = 12

        @Volatile internal var mediaControlCoordinator: MediaControlStreamCoordinator? = null

        // RR-7b — the live PhoneControlSender for the currently paired Mac, published by the mirror
        // surfaces (ScreenShareViewer / InlineAgentMirror) when a control stream is established and
        // cleared when it closes. The Agent Watch surface reuses it to sign + transmit approvals.
        @Volatile internal var activePhoneControlSender: com.openburnbar.data.computeruse.PhoneControlSender? = null

        @Volatile internal var fileTransferService: AndroidFileTransferService? = null

        @Volatile var agentCapabilityGrantController:
            com.openburnbar.data.computeruse.AgentCapabilityGrantController? = null
    }

    private var pairingListener: ListenerRegistration? = null
    private var authListener: FirebaseAuth.AuthStateListener? = null
    internal val controlTransportPool by lazy {
        RetainedIrohControlTransportPool { relayURL ->
            val keyStore = HermesRelayKeyStore(applicationContext)
            runCatching {
                if (!OpenBurnBarIrohFfiBackend.isAvailable()) {
                    error("Android iroh native backend is unavailable in this build.")
                }
                com.openburnbar.data.hermes.relay.HermesIrohRelayTransport.defaultTransport(
                    keyStore = keyStore,
                    relayURL = relayURL,
                )
            }.getOrElse { error ->
                Log.e("BurnBar", "Mercury iroh transport unavailable: ${error.message}", error)
                throw error
            }
        }
    }

    @Volatile internal var activeCoordinatorConnection: String? = null

    @Volatile internal var activeCoordinatorPublishedAtMillis: Long? = null

    @Volatile internal var activeCoordinatorTarget: IrohDialTarget? = null
    internal val mediaCoordinatorLock = Mutex()

    override fun onCreate() {
        super.onCreate()
        appContext = applicationContext
        OpenBurnBarIrohNativeContext.install(applicationContext)
        val remoteReadiness = BurnBarRemoteBridge.readiness()
        Log.i(
            "BurnBar",
            "BurnBar remote engine readiness: protocol=${remoteReadiness.protocolVersion}, " +
                "native=${remoteReadiness.nativeBridgeAvailable}",
        )
        // T-AND-06: install the Sentry privacy scrubber BEFORE anything can capture a crash/ANR,
        // so no payload or breadcrumb can ship prompt/credential fragments off device. This reads
        // the manifest-configured DSN/options and adds beforeSend/beforeBreadcrumb on top.
        runCatching { SentryPrivacyInit.install(applicationContext) }
            .onFailure { Log.w("BurnBar", "Sentry privacy scrubber install failed: ${it.message}") }
        FirebaseApp.initializeApp(this)
        installAppCheckProvider()
        // F2/F7/F10: land remote kill-switch values so the default-ON
        // protection flags can be remotely disabled (the flags default ON via
        // the source-aware reader; this makes the override reachable). iOS
        // does this in MobileMediaBudgetStatusStore.
        com.openburnbar.data.computeruse.RemoteConfigBootstrap.activate()
        // Signal at-rest activation: AND the registry scheme with a per-domain
        // Remote Config kill switch (`signal_at_rest_<id>_enabled`), mirroring
        // iOS `MobileCloudVaultSignalPayloads.signalSealingIsEnabled`. Source-aware
        // and DEFAULT-OFF: a STATIC value (no remote value fetched, no in-app
        // default registered) resolves false, so the producer path only emits
        // Signal envelopes once an operator explicitly flips the flag true. Any
        // Firebase failure also resolves false — Android stays fail-closed.
        com.openburnbar.data.cloud.AndroidCloudVaultSignalPayloads.signalAtRestActivationProvider = { domainID ->
            runCatching {
                val value = com.google.firebase.remoteconfig.FirebaseRemoteConfig.getInstance()
                    .getValue("signal_at_rest_${domainID}_enabled")
                if (value.source == com.google.firebase.remoteconfig.FirebaseRemoteConfig.VALUE_SOURCE_STATIC) {
                    false
                } else {
                    value.asBoolean()
                }
            }.getOrDefault(false)
        }
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
        // Widget snapshot: hydrate from disk + schedule the 15-min refresh.
        BurnBarWidgetSnapshotStore.bind(this)
        BurnBarWidgetSyncWorker.enqueuePeriodic(this)
        TextExpansionSyncWorker.enqueuePeriodic(this)
        BudgetNotificationCenter.ensureChannel(this)

        // Phase 6: Hermes iroh transport bootstraps lazily — first send on
        // `HermesIrohRelayTransport.transport()` brings the endpoint up.
        // Nothing eager required here.
        installFileTransferService()

        // Phase 6: when Firebase Auth is ready AND a paired Mac iroh
        // record exists, dial the media-control coordinator so file
        // transfers can fire without first establishing a chat stream.
        installAuthListener()

        // Phase 6: register the FCM token under
        // users/{uid}/devices/{deviceId}/fcm_token so triggerVoIPCall
        // can send a Mercury push to this device.
        AgentReplyNotificationState.installLifecycleTracking(this)
        com.openburnbar.data.cloud.CloudVaultRotationPickupLifecycle.install(this)
        registerFcmToken()
    }

    private fun installFileTransferService() {
        val blobKeyStore = IrohBlobKeyStore(applicationContext)
        val transferService = MediaFileTransferService(
            backend = OpenBurnBarIrohBlobFfiBackend(),
            configuration = MediaFileTransferService.Configuration(
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
                    getSharedPreferences("mercury_media", MODE_PRIVATE)
                        .getBoolean("media_blob_transfer_enabled", true)
                },
            ),
        )
    }

    private fun installAuthListener() {
        val listener = FirebaseAuth.AuthStateListener { auth ->
            val uid = auth.currentUser?.uid
            if (uid == null) {
                tearDownPairingListener()
                stopMediaControlCoordinator()
                applicationScope.launch {
                    BurnBarWidgetSyncWorker.clearAndRefresh(applicationContext)
                }
            } else {
                applicationScope.launch {
                    runCatching {
                        ComputerUseSecurityCallableClient().bindAppCheckAttestation()
                    }.onFailure { error ->
                        Log.w("BurnBar", "App Check attestation bind failed: ${error.message}")
                    }
                }
                restartPairingListener(uid)
            }
        }
        authListener = listener
        FirebaseAuth.getInstance().addAuthStateListener(listener)
        // Cover the case where Auth is already signed in by the time
        // onCreate runs (warm starts).
        FirebaseAuth.getInstance().currentUser?.uid?.let { restartPairingListener(it) }
    }

    private fun restartPairingListener(uid: String) {
        tearDownPairingListener()
        pairingListener = FirebaseFirestore.getInstance()
            .collection("users").document(uid)
            .collection(IROH_PAIRING_COLLECTION)
            .orderBy("publishedAtMillis", Query.Direction.DESCENDING)
            .limit(IrohPairingSelection.QUERY_LIMIT)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    Log.w("BurnBar", "Iroh pairing listener error: ${error.message}")
                    return@addSnapshotListener
                }
                val selected = IrohPairingSelection.newest(snapshot?.documents.orEmpty())
                if (selected == null) {
                    stopMediaControlCoordinator()
                    return@addSnapshotListener
                }
                if (
                    selected.connectionId == activeCoordinatorConnection &&
                    selected.publishedAtMillis == activeCoordinatorPublishedAtMillis
                ) {
                    return@addSnapshotListener
                }
                applicationScope.launch {
                    runCatching {
                        ensureMediaControlCoordinator(uid = uid, selection = selected)
                    }.onFailure { error ->
                        Log.w("BurnBar", "Mercury pairing refresh failed: ${error.message}")
                        stopMediaControlCoordinator()
                    }
                }
            }
    }

    private fun tearDownPairingListener() {
        pairingListener?.remove()
        pairingListener = null
    }

    private suspend fun ensureMediaControlCoordinator(uid: String, selection: IrohPairingSelection.Candidate, forceRestart: Boolean = false) {
        ensureMediaControlCoordinatorManaged(uid = uid, selection = selection, forceRestart = forceRestart)
    }

    suspend fun ensureMediaControlStream(connectionID: String, forceRestart: Boolean = false) {
        val normalizedConnectionID = connectionID.trim().takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("Mercury requires a paired Mac connection id.")
        val uid = FirebaseAuth.getInstance().currentUser?.uid
            ?: error("Mercury requires a signed-in Firebase user.")
        ensureMediaControlCoordinator(
            uid = uid,
            selection = IrohPairingSelection.Candidate(
                connectionId = normalizedConnectionID,
                publishedAtMillis = if (activeCoordinatorConnection == normalizedConnectionID) {
                    activeCoordinatorPublishedAtMillis ?: 0L
                } else {
                    0L
                },
            ),
            forceRestart = forceRestart,
        )
    }

    /**
     * External hook so the in-app dispatcher (or tests) can register an
     * `AndroidFileTransferService` once the file-transfer backend +
     * configuration are available. After registration, the next paired
     * Mac record refresh starts the media-control coordinator.
     */
    fun registerFileTransferService(service: AndroidFileTransferService) {
        fileTransferService = service
        mediaControlCoordinator?.attachReceiver(service)
        val uid = FirebaseAuth.getInstance().currentUser?.uid
        val connectionId = activeCoordinatorConnection
        if (uid != null && connectionId != null) {
            val publishedAtMillis = activeCoordinatorPublishedAtMillis ?: 0L
            applicationScope.launch {
                runCatching {
                    ensureMediaControlCoordinator(
                        uid = uid,
                        selection = IrohPairingSelection.Candidate(
                            connectionId = connectionId,
                            publishedAtMillis = publishedAtMillis,
                        ),
                    )
                }.onFailure { error ->
                    Log.w("BurnBar", "Mercury coordinator receiver attach failed: ${error.message}")
                    stopMediaControlCoordinator()
                }
            }
        }
    }

    private fun stopMediaControlCoordinator() {
        val coordinator = mediaControlCoordinator ?: return
        applicationScope.launch {
            runCatching { coordinator.stop() }
            runCatching { controlTransportPool.shutdown() }
        }
        mediaControlCoordinator = null
        activeCoordinatorConnection = null
        activeCoordinatorPublishedAtMillis = null
        activeCoordinatorTarget = null
    }

    internal suspend fun fetchVerifiedPairingTarget(uid: String, connectionId: String): IrohDialTarget {
        val publicKey = FirestoreIrohPairingPublicKeyProvider().fetchPublicKey(uid)
        return IrohPairingPublisher(FirestoreIrohPairingDirectory()).fetchAndVerify(
            uid = uid,
            connectionId = connectionId,
            publicKey = publicKey,
        )
    }

    /**
     * Default control-stream dialer. The production iroh transport is
     * provided through `HermesIrohRelayTransport.defaultTransport(...)`
     * once the AAR is on the classpath; without the AAR we fall back to
     * the in-process loopback transport so the wiring still completes
     * for tests and CI screenshots.
     */
    internal suspend fun dialControlStream(target: IrohDialTarget): IrohRelayStream {
        Log.i(
            "BurnBar",
            "Mercury control dial target node=${target.nodeId.take(
                LOG_NODE_ID_PREFIX_LENGTH,
            )} relay=${target.relayURL != null} directAddresses=${target.directAddresses.size}",
        )
        return controlTransportPool.dial(target, timeoutMillis = MEDIA_CONTROL_DIAL_TIMEOUT_MILLIS)
    }

    /**
     * First-launch detection for `app.session.started`'s `is_first_launch`.
     * A boolean marker in a private prefs file; flips to false after the first
     * read. Independent of analytics consent so the marker is correct whenever
     * the user eventually opts in. No PII — a single boolean.
     */
    private fun detectFirstLaunch(): Boolean {
        val prefs = getSharedPreferences("burnbar.analytics.lifecycle", MODE_PRIVATE)
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
            com.openburnbar.analytics.AnalyticsManager.setUserId(uid?.let { hashedAccountId(it) })
        }
        FirebaseAuth.getInstance().addAuthStateListener(listener)
    }

    private fun hashedAccountId(uid: String): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(uid.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    private fun registerFcmToken() {
        applicationScope.launch {
            runCatching {
                val token = FirebaseMessaging.getInstance().token.await()
                AgentReplyNotificationState.persistToken(applicationContext, token)
            }.onFailure {
                Log.w("BurnBar", "FCM token registration failed: ${it.message}")
            }
        }
    }

    /**
     * Three-way provider selection — chosen so App Check enforcement on
     * the server can stay ON in every distribution channel:
     *
     * 1. **Debug builds** (`BuildConfig.DEBUG`): use the Firebase Debug
     *    provider. On first launch the SDK logs a debug secret; that
     *    secret must be registered in the Firebase Console → App Check →
     *    "Manage debug tokens" list (one entry per developer device).
     *
     * 2. **Release builds destined for Firebase App Distribution**
     *    (`BuildConfig.USE_DEBUG_APP_CHECK == true`): use the Debug
     *    provider but pre-seed its SharedPreferences with the fixed
     *    `BuildConfig.APP_CHECK_DEBUG_TOKEN`. The same token is
     *    pre-registered server-side, so every install of this APK passes
     *    App Check without exposing real Play Integrity attestation —
     *    necessary because Play Integrity rejects APKs that have never
     *    been uploaded to Play Console.
     *
     * 3. **Release builds destined for Play Store**
     *    (default — both flags unset): use PlayIntegrity. Real users get
     *    real attestation, and the debug token is never on this APK.
     *
     * Server-side enforcement remains ENFORCED in every case.
     */
    private fun installAppCheckProvider() {
        val factory: AppCheckProviderFactory = when {
            BuildConfig.DEBUG -> {
                seedDebugAppCheckTokenIfNeeded(this, BuildConfig.APP_CHECK_DEBUG_TOKEN)
                Log.i("BurnBar", "AppCheck: using Debug provider (debug build)")
                debugAppCheckProviderFactory()
            }
            BuildConfig.USE_DEBUG_APP_CHECK -> {
                seedDebugAppCheckTokenIfNeeded(this, BuildConfig.APP_CHECK_DEBUG_TOKEN)
                Log.i("BurnBar", "AppCheck: using Debug provider (App Distribution build, seeded token)")
                debugAppCheckProviderFactory()
            }
            else -> {
                Log.i("BurnBar", "AppCheck: using Play Integrity (production)")
                PlayIntegrityAppCheckProviderFactory.getInstance()
            }
        }
        FirebaseAppCheck.getInstance().installAppCheckProviderFactory(factory)
    }

    private fun debugAppCheckProviderFactory(): AppCheckProviderFactory {
        val factoryClass = Class.forName("com.google.firebase.appcheck.debug.DebugAppCheckProviderFactory")
        return factoryClass.getMethod("getInstance")
            .invoke(null) as? AppCheckProviderFactory
            ?: error("DebugAppCheckProviderFactory.getInstance returned an unexpected type")
    }

    /**
     * Seed Firebase's Debug provider SharedPreferences with a pre-registered
     * debug secret so every instance of this APK presents the same token to
     * the App Check exchange endpoint. The SDK stores its secret under
     *
     *   prefs  : "com.google.firebase.appcheck.debug.store.{persistenceKey}"
     *   key    : "com.google.firebase.appcheck.debug.DEBUG_SECRET"
     *
     * (extracted from `StorageHelper` in firebase-appcheck-debug 18.x —
     * file `com/google/firebase/appcheck/debug/internal/StorageHelper.java`)
     */
    private fun seedDebugAppCheckTokenIfNeeded(context: Context, token: String) {
        if (token.isBlank()) {
            Log.w("BurnBar", "USE_DEBUG_APP_CHECK is true but no APP_CHECK_DEBUG_TOKEN set — token will be auto-generated and printed to logcat.")
            return
        }
        val persistenceKey = FirebaseApp.getInstance().persistenceKey
        val prefsName = "com.google.firebase.appcheck.debug.store.$persistenceKey"
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val existing = prefs.getString("com.google.firebase.appcheck.debug.DEBUG_SECRET", null)
        if (existing != token) {
            prefs.edit().putString("com.google.firebase.appcheck.debug.DEBUG_SECRET", token).apply()
        }
    }
}

private fun MediaControlStreamCoordinator.Phase.isActiveOrConnecting(): Boolean = this is MediaControlStreamCoordinator.Phase.Dialing ||
    this is MediaControlStreamCoordinator.Phase.Live ||
    this is MediaControlStreamCoordinator.Phase.Reconnecting

internal object MediaControlCoordinatorReusePolicy {
    fun shouldReuse(
        activeConnectionID: String?,
        phase: MediaControlStreamCoordinator.Phase?,
        selection: IrohPairingSelection.Candidate,
        forceRestart: Boolean,
    ): Boolean {
        if (phase == null) return false
        if (activeConnectionID != selection.connectionId) return false
        return if (forceRestart) {
            phase is MediaControlStreamCoordinator.Phase.Live ||
                phase is MediaControlStreamCoordinator.Phase.Dialing
        } else {
            phase.isActiveOrConnecting()
        }
    }
}
