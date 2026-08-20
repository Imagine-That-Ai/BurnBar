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
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistration
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.cloud.MercuryDeviceRegistrationPreflight
import com.openburnbar.data.cloud.MercuryDeviceRegistrationState
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
import com.openburnbar.data.computeruse.IrohControllerRouteRegistrarProvider
import com.openburnbar.data.hermes.HermesAuthLifecycleRegistry
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingDirectory
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingPublicKeyProvider
import com.openburnbar.data.hermes.relay.HermesRelayKeyStore
import com.openburnbar.data.media.AndroidFileTransferService
import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.data.media.RetainedIrohControlTransportPool
import com.openburnbar.data.text.TextExpansionSyncWorker
import com.openburnbar.data.widget.BurnBarWidgetSnapshotStore
import com.openburnbar.data.widget.BurnBarWidgetSyncWorker
import com.openburnbar.diagnostics.CrashReportingConsentStore
import com.openburnbar.irohrelay.IrohDialTarget
import com.openburnbar.irohrelay.IrohPairingPublisher
import com.openburnbar.irohrelay.IrohRelayStream
import com.openburnbar.irohrelay.OpenBurnBarIrohFfiBackend
import com.openburnbar.irohrelay.OpenBurnBarIrohNativeContext
import com.openburnbar.remote.BurnBarRemoteBridge
import com.openburnbar.services.media.AgentReplyNotificationState
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
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

internal object ControllerAuthStatePolicy {
    fun shouldReconcile(previousUid: String?, nextUid: String?): Boolean = previousUid != nextUid

    fun isCurrent(expectedUid: String?, expectedEpoch: Long, currentUid: String?, currentEpoch: Long): Boolean =
        expectedUid == currentUid && expectedEpoch == currentEpoch
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
        private const val LOG_UID_PREFIX_LENGTH = 8

        @Volatile internal var mediaControlCoordinator: MediaControlStreamCoordinator? = null

        private val _mercuryDeviceRegistrationState =
            MutableStateFlow<MercuryDeviceRegistrationState>(MercuryDeviceRegistrationState.Idle)
        internal val mercuryDeviceRegistrationState: StateFlow<MercuryDeviceRegistrationState> =
            _mercuryDeviceRegistrationState.asStateFlow()

        /** Publish hook for the trust-observer extension in `BurnBarApplicationMercuryTrustSections.kt`. */
        internal fun publishMercuryDeviceRegistrationState(state: MercuryDeviceRegistrationState) {
            _mercuryDeviceRegistrationState.value = state
        }

        // RR-7b — the live PhoneControlSender for the currently paired Mac, published by the mirror
        // surfaces (ScreenShareViewer / InlineAgentMirror) when a control stream is established and
        // cleared when it closes. The Agent Watch surface reuses it to sign + transmit approvals.
        @Volatile internal var activePhoneControlSender: com.openburnbar.data.computeruse.PhoneControlSender? = null

        @Volatile internal var fileTransferService: AndroidFileTransferService? = null

        @Volatile var agentCapabilityGrantController:
            com.openburnbar.data.computeruse.AgentCapabilityGrantController? = null

        @Volatile internal var sessionGrantChallengeReceiver:
            com.openburnbar.data.computeruse.ComputerUseSessionGrantChallengeReceiver? = null

        internal suspend fun signOutSafely(auth: FirebaseAuth) {
            val application = if (isAppContextInitialized) {
                appContext.applicationContext as? BurnBarApplication
            } else {
                null
            }
            if (application != null) {
                application.signOutWithControllerTeardown(auth)
                return
            }
            val routeGate = IrohControllerRouteRegistrarProvider.holdAuthTransitionGate()
            val hermesGate = HermesAuthLifecycleRegistry.holdAuthTransitionGate()
            try {
                runCatching { HermesAuthLifecycleRegistry.closeResourcesForTransition(hermesGate) }
                    .onFailure { error -> Log.w("BurnBar", "Hermes teardown before sign-out failed: ${error.message}") }
                runCatching { IrohControllerRouteRegistrarProvider.invalidateAllIfCreated(revokeRemote = true) }
                    .onFailure { error ->
                        Log.w("BurnBar", "Controller-route revocation before sign-out failed: ${error.message}")
                    }
                auth.signOut()
            } finally {
                HermesAuthLifecycleRegistry.releaseAuthTransitionGate(hermesGate)
                IrohControllerRouteRegistrarProvider.releaseAuthTransitionGate(routeGate)
            }
        }
    }

    private var pairingListener: ListenerRegistration? = null

    /** Escrow trust-state observer; lives alongside the pairing listener and shares its teardown. */
    internal var escrowTrustListener: ListenerRegistration? = null
    private var authListener: FirebaseAuth.AuthStateListener? = null
    private var controllerRouteAuthUid: String? = null
    internal val controllerAuthTransitionLock = Mutex()
    private val controllerAuthEpoch = AtomicLong()
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
    internal val controllerRouteRegistrar by lazy {
        IrohControllerRouteRegistrarProvider.fromContext(applicationContext)
    }

    @Volatile internal var activeCoordinatorConnection: String? = null

    @Volatile internal var activeCoordinatorUid: String? = null

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
        installComputerUseSessionGrantReceiver()
        applicationScope.launch(Dispatchers.IO) {
            runCatching { com.openburnbar.ui.share.BurnbarShareInboxProcessor.processPending(this@BurnBarApplication) }
        }
        val domainCoreEvidenceChannel = com.openburnbar.data.DomainCoreBuildProfile.evidenceChannel()
        runCatching {
            if (domainCoreEvidenceChannel == null) {
                com.openburnbar.data.AndroidDomainCoreShadowEvidence.discardStoredSamples(this)
            } else {
                com.openburnbar.data.AndroidDomainCoreShadowEvidence.install(this, domainCoreEvidenceChannel)
            }
        }.onFailure { Log.w("BurnBar", "Domain-core evidence uploader disabled: ${it.message}") }
        // F2/F7/F10: land remote kill-switch values so the default-ON
        // protection flags can be remotely disabled (the flags default ON via
        // the source-aware reader; this makes the override reachable). iOS
        // does this in MobileMediaBudgetStatusStore.
        com.openburnbar.data.computeruse.RemoteConfigBootstrap.activate()
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

    private fun installAuthListener() {
        val listener = FirebaseAuth.AuthStateListener { auth ->
            val uid = auth.currentUser?.uid
            if (!ControllerAuthStatePolicy.shouldReconcile(previousUid = controllerRouteAuthUid, nextUid = uid)) {
                Log.i("BurnBar", "Mercury auth callback ignored for unchanged uid=${uid?.take(LOG_UID_PREFIX_LENGTH) ?: "signed-out"}")
                return@AuthStateListener
            }
            val epoch = controllerAuthEpoch.incrementAndGet()
            val gate = IrohControllerRouteRegistrarProvider.holdAuthTransitionGate()
            val hermesGate = HermesAuthLifecycleRegistry.holdAuthTransitionGate()
            tearDownPairingListener()
            applicationScope.launch {
                reconcileControllerAuthState(uid = uid, epoch = epoch, gate = gate, hermesGate = hermesGate)
            }
        }
        authListener = listener
        FirebaseAuth.getInstance().addAuthStateListener(listener)
    }

    private suspend fun reconcileControllerAuthState(
        uid: String?,
        epoch: Long,
        gate: IrohControllerRouteRegistrarProvider.AuthTransitionGateToken,
        hermesGate: HermesAuthLifecycleRegistry.TransitionToken,
    ) {
        try {
            controllerAuthTransitionLock.withLock {
                if (controllerAuthEpoch.get() != epoch) return@withLock
                val previousUid = controllerRouteAuthUid
                controllerRouteRegistrar.beginAuthTransition()
                try {
                    runCatching { HermesAuthLifecycleRegistry.closeResourcesForTransition(hermesGate) }
                        .onFailure { error -> Log.w("BurnBar", "Hermes auth transition cleanup failed: ${error.message}") }
                    stopMediaControlCoordinatorAndWait()
                    if (previousUid != null && previousUid != uid) {
                        // Firebase has already switched identities at this callback. Purge local
                        // ownership without issuing an old-account revoke as the replacement user.
                        runCatching { controllerRouteRegistrar.invalidateAll(revokeRemote = false) }
                            .onFailure { error ->
                                Log.w("BurnBar", "Controller-route auth transition cleanup failed: ${error.message}")
                            }
                    }
                    controllerRouteAuthUid = uid
                } finally {
                    controllerRouteRegistrar.endAuthTransition()
                }

                if (!controllerAuthStateIsCurrent(uid = uid, epoch = epoch)) return@withLock
                IrohControllerRouteRegistrarProvider.releaseAuthTransitionGate(gate)
                if (uid == null || (previousUid != null && previousUid != uid)) {
                    BurnBarWidgetSyncWorker.clearAndRefresh(applicationContext)
                }
                if (uid == null) {
                    _mercuryDeviceRegistrationState.value = MercuryDeviceRegistrationState.Idle
                    return@withLock
                }
                val registration = registerMercuryDeviceBeforePairing(uid = uid, epoch = epoch)
                if (registration == null) {
                    // Don't strand this sign-in in Failed until the next auth
                    // transition: retry the preflight with backoff.
                    scheduleMercuryRegistrationRetry(uid = uid, epoch = epoch, attempt = 1)
                    return@withLock
                }
                if (controllerAuthStateIsCurrent(uid = uid, epoch = epoch)) {
                    // Restart first: it tears down both listeners before re-arming pairing.
                    restartPairingListener(uid = uid, epoch = epoch)
                    observeEscrowDeviceTrust(uid = uid, epoch = epoch, deviceId = registration.deviceId)
                }
            }
        } finally {
            HermesAuthLifecycleRegistry.releaseAuthTransitionGate(hermesGate)
            IrohControllerRouteRegistrarProvider.releaseAuthTransitionGate(gate)
        }
    }

    internal suspend fun registerMercuryDeviceBeforePairing(uid: String, epoch: Long): AndroidEscrowDeviceRegistration? {
        val securityClient = ComputerUseSecurityCallableClient()
        val registrationPreflight =
            MercuryDeviceRegistrationPreflight { expectedUid ->
                securityClient.bindAppCheckAttestation(expectedUid)
                AndroidEscrowDeviceRegistry(securityClient = securityClient)
                    .registerSelf(uid = expectedUid)
            }
        return runCatching {
            registrationPreflight.run(uid = uid) { state ->
                if (controllerAuthStateIsCurrent(uid = uid, epoch = epoch)) {
                    _mercuryDeviceRegistrationState.value = state
                }
            }
        }.getOrElse { registrationFailure ->
            if (registrationFailure is CancellationException) throw registrationFailure
            Log.w(
                "BurnBar",
                "Mercury Android registration preflight failed; pairing remains stopped: ${registrationFailure.message}",
                registrationFailure,
            )
            null
        }
    }

    internal fun restartPairingListener(uid: String, epoch: Long) {
        tearDownPairingListener()
        pairingListener = FirebaseFirestore.getInstance()
            .collection("users").document(uid)
            .collection(IROH_PAIRING_COLLECTION)
            .orderBy("publishedAtMillis", Query.Direction.DESCENDING)
            .limit(IrohPairingSelection.QUERY_LIMIT)
            .addSnapshotListener { snapshot, error ->
                if (!controllerAuthStateIsCurrent(uid = uid, epoch = epoch)) {
                    return@addSnapshotListener
                }
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
                    if (!controllerAuthStateIsCurrent(uid = uid, epoch = epoch)) {
                        return@launch
                    }
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
        escrowTrustListener?.remove()
        escrowTrustListener = null
    }

    internal fun controllerAuthStateIsCurrent(uid: String?, epoch: Long): Boolean = ControllerAuthStatePolicy.isCurrent(
        expectedUid = uid,
        expectedEpoch = epoch,
        currentUid = FirebaseAuth.getInstance().currentUser?.uid,
        currentEpoch = controllerAuthEpoch.get(),
    )

    private suspend fun ensureMediaControlCoordinator(uid: String, selection: IrohPairingSelection.Candidate, forceRestart: Boolean = false) {
        check(controllerRouteAuthUid == uid && FirebaseAuth.getInstance().currentUser?.uid == uid) {
            "Mercury controller auth changed before the pairing stream could start."
        }
        ensureMediaControlCoordinatorManaged(uid = uid, selection = selection, forceRestart = forceRestart)
    }

    internal suspend fun signOutWithControllerTeardown(auth: FirebaseAuth) {
        controllerAuthEpoch.incrementAndGet()
        val gate = IrohControllerRouteRegistrarProvider.holdAuthTransitionGate()
        val hermesGate = HermesAuthLifecycleRegistry.holdAuthTransitionGate()
        tearDownPairingListener()
        try {
            controllerAuthTransitionLock.withLock {
                controllerRouteRegistrar.beginAuthTransition()
                try {
                    runCatching { HermesAuthLifecycleRegistry.closeResourcesForTransition(hermesGate) }
                        .onFailure { error -> Log.w("BurnBar", "Hermes teardown before sign-out failed: ${error.message}") }
                    stopMediaControlCoordinatorAndWait()
                    runCatching { controllerRouteRegistrar.invalidateAll(revokeRemote = true) }
                        .onFailure { error ->
                            Log.w("BurnBar", "Controller-route revocation before sign-out failed: ${error.message}")
                        }
                    controllerRouteAuthUid = null
                    auth.signOut()
                } finally {
                    controllerRouteRegistrar.endAuthTransition()
                }
            }
        } finally {
            HermesAuthLifecycleRegistry.releaseAuthTransitionGate(hermesGate)
            IrohControllerRouteRegistrarProvider.releaseAuthTransitionGate(gate)
        }
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
        applicationScope.launch { stopMediaControlCoordinatorAndWait() }
    }

    private suspend fun stopMediaControlCoordinatorAndWait() {
        mediaCoordinatorLock.withLock {
            val coordinator = mediaControlCoordinator
            mediaControlCoordinator = null
            activeCoordinatorUid = null
            activeCoordinatorConnection = null
            activeCoordinatorPublishedAtMillis = null
            activeCoordinatorTarget = null
            runCatching { coordinator?.stop() }
            runCatching { controlTransportPool.shutdown() }
        }
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
     * Default control-stream dialer. Production requires the native iroh backend and fails closed
     * during transport-pool construction when the AAR/native library is unavailable.
     */
    internal suspend fun dialControlStream(uid: String, connectionId: String, target: IrohDialTarget): IrohRelayStream {
        Log.i(
            "BurnBar",
            "Mercury control dial target node=${target.nodeId.take(
                LOG_NODE_ID_PREFIX_LENGTH,
            )} relay=${target.relayURL != null} directAddresses=${target.directAddresses.size}",
        )
        return controlTransportPool.dial(
            target = target,
            timeoutMillis = MEDIA_CONTROL_DIAL_TIMEOUT_MILLIS,
            beforeConnect = { endpointIdentity ->
                controllerRouteRegistrar.ensureRegistered(
                    uid = uid,
                    connectionId = connectionId,
                    endpointIdentity = endpointIdentity,
                )
            },
        )
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

    /** Debug builds use per-device SDK tokens; every distributed build uses Play Integrity. */
    private fun installAppCheckProvider() {
        val factory: AppCheckProviderFactory = when {
            BuildConfig.DEBUG -> {
                Log.i("BurnBar", "AppCheck: using Debug provider (debug build)")
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
        if (forceRestart) return false
        return phase.isActiveOrConnecting()
    }
}
