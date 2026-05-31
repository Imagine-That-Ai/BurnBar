package com.openburnbar

import android.app.Application
import android.content.Context
import android.util.Log
import com.google.firebase.FirebaseApp
import com.openburnbar.data.budget.BudgetNotificationCenter
import com.openburnbar.data.computeruse.ComputerUseSecurityCallableClient
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
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingDirectory
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingPublicKeyProvider
import com.openburnbar.data.hermes.relay.HermesRelayKeyStore
import com.openburnbar.data.budget.BudgetNotificationCenter
import com.openburnbar.data.media.AndroidFileTransferService
import com.openburnbar.data.media.IrohBlobKeyStore
import com.openburnbar.data.media.MediaFileTransferService
import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.data.media.RetainedIrohControlTransportPool
import com.openburnbar.data.widget.BurnBarWidgetSnapshotStore
import com.openburnbar.data.widget.BurnBarWidgetSyncWorker
import com.openburnbar.data.text.TextExpansionSyncWorker
import com.openburnbar.services.media.AgentReplyNotificationState
import com.openburnbar.irohrelay.IrohDialTarget
import com.openburnbar.irohrelay.IrohPairingPublisher
import com.openburnbar.irohrelay.OpenBurnBarIrohBlobFfiBackend
import com.openburnbar.irohrelay.OpenBurnBarIrohFfiBackend
import com.openburnbar.irohrelay.IrohRelayStream
import com.openburnbar.irohrelay.IrohRelayTransport
import com.openburnbar.irohrelay.OpenBurnBarIrohNativeContext
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await

internal object IrohPairingSelection {
    data class Candidate(
        val connectionId: String,
        val publishedAtMillis: Long,
    )

    fun newest(documents: List<DocumentSnapshot>): Candidate? =
        newestCandidates(
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
            }
        )

    fun newestCandidates(candidates: List<Candidate>): Candidate? =
        candidates
            .filter { it.connectionId.isNotBlank() }
            .maxWithOrNull(
                compareBy<Candidate> { it.publishedAtMillis }
                    .thenBy { it.connectionId }
            )
}

class BurnBarApplication : Application() {
    companion object {
        lateinit var appContext: Context
            private set

        /** App-process scope used for FCM token persistence and pairing listener bookkeeping. */
        internal val applicationScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        private const val IROH_PAIRING_COLLECTION = "iroh_pairing"
        private const val DEVICE_ID_PREF_NAME = "burnbar.device"
        private const val DEVICE_ID_PREF_KEY = "stable_device_id"
        private const val MEDIA_CONTROL_DIAL_TIMEOUT_MILLIS = 15_000L

        @Volatile internal var mediaControlCoordinator: MediaControlStreamCoordinator? = null
            private set

        @Volatile internal var fileTransferService: AndroidFileTransferService? = null
            private set

        @Volatile var agentCapabilityGrantController:
            com.openburnbar.data.computeruse.AgentCapabilityGrantController? = null
    }

    private var pairingListener: ListenerRegistration? = null
    private var authListener: FirebaseAuth.AuthStateListener? = null
    private val controlTransportPool by lazy {
        RetainedIrohControlTransportPool { relayURL ->
            val keyStore = HermesRelayKeyStore(applicationContext)
            runCatching {
                if (!OpenBurnBarIrohFfiBackend.isAvailable()) {
                    throw IllegalStateException("Android iroh native backend is unavailable in this build.")
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
    @Volatile private var activeCoordinatorConnection: String? = null
    @Volatile private var activeCoordinatorPublishedAtMillis: Long? = null
    @Volatile private var activeCoordinatorTarget: IrohDialTarget? = null
    private val mediaCoordinatorLock = Mutex()

    override fun onCreate() {
        super.onCreate()
        appContext = applicationContext
        OpenBurnBarIrohNativeContext.install(applicationContext)
        FirebaseApp.initializeApp(this)
        installAppCheckProvider()
        val crashlyticsEnabled = getSharedPreferences("burnbar.diagnostics", MODE_PRIVATE)
            .getBoolean("crashlytics_enabled", false)
        FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(crashlyticsEnabled)
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
            )
        )
    }

    private fun installAuthListener() {
        val listener = FirebaseAuth.AuthStateListener { auth ->
            val uid = auth.currentUser?.uid
            if (uid == null) {
                tearDownPairingListener()
                stopMediaControlCoordinator()
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
                    ensureMediaControlCoordinator(uid = uid, selection = selected)
                }
            }
    }

    private fun tearDownPairingListener() {
        pairingListener?.remove()
        pairingListener = null
    }

    private suspend fun ensureMediaControlCoordinator(
        uid: String,
        selection: IrohPairingSelection.Candidate,
        forceRestart: Boolean = false,
    ) {
        mediaCoordinatorLock.withLock {
            val connectionId = selection.connectionId
            val existing = mediaControlCoordinator
            val existingPhase = existing?.phase?.value
            if (
                MediaControlCoordinatorReusePolicy.shouldReuse(
                    activeConnectionID = activeCoordinatorConnection,
                    phase = existingPhase,
                    selection = selection,
                    forceRestart = forceRestart,
                )
            ) {
                if (activeCoordinatorPublishedAtMillis != selection.publishedAtMillis) {
                    activeCoordinatorPublishedAtMillis = selection.publishedAtMillis
                    runCatching {
                        activeCoordinatorTarget = fetchVerifiedPairingTarget(
                            uid = uid,
                            connectionId = connectionId,
                        )
                    }.onFailure {
                        Log.w("BurnBar", "Mercury pairing refresh target update failed: ${it.message}")
                    }
                }
                Log.i("BurnBar", "Mercury coordinator reuse connectionID=$connectionId phase=${existingPhase?.label()}")
                return
            }

            Log.i(
                "BurnBar",
                "Mercury coordinator rebuild connectionID=$connectionId forceRestart=$forceRestart previousPhase=${existingPhase?.label() ?: "none"}",
            )
            val target = fetchVerifiedPairingTarget(uid = uid, connectionId = connectionId)
            existing?.stop()
            controlTransportPool.shutdown()
            val dialer = MediaControlStreamCoordinator.StreamDialer { dialedUid, dialedConnection ->
                val dialTarget = activeCoordinatorTarget
                    ?: fetchVerifiedPairingTarget(uid = dialedUid, connectionId = dialedConnection)
                dialControlStream(dialTarget)
            }
            val coordinator = MediaControlStreamCoordinator(
                dialer = dialer,
                receiver = fileTransferService,
                controlAuthorityPeerNodeIdProvider = {
                    runCatching {
                        com.openburnbar.data.computeruse.PhoneControlSigningKeyStore(this@BurnBarApplication)
                            .peerNodeId()
                    }.getOrNull()
                },
            )
            mediaControlCoordinator = coordinator
            activeCoordinatorConnection = connectionId
            activeCoordinatorPublishedAtMillis = selection.publishedAtMillis
            activeCoordinatorTarget = target
            fileTransferService?.let { receiver ->
                runCatching {
                    coordinator.attachReceiver(receiver)
                    receiver.attachControlStream(coordinator)
                }.onFailure { Log.w("BurnBar", "attachControlStream failed: ${it.message}") }
            }
            runCatching { coordinator.start(uid = uid, connectionID = connectionId) }
                .onFailure { Log.w("BurnBar", "MediaControlStreamCoordinator.start failed: ${it.message}") }
        }
    }

    suspend fun ensureMediaControlStream(connectionID: String, forceRestart: Boolean = false) {
        val normalizedConnectionID = connectionID.trim().takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("Mercury requires a paired Mac connection id.")
        val uid = FirebaseAuth.getInstance().currentUser?.uid
            ?: throw IllegalStateException("Mercury requires a signed-in Firebase user.")
        ensureMediaControlCoordinator(
            uid = uid,
            selection = IrohPairingSelection.Candidate(
                connectionId = normalizedConnectionID,
                publishedAtMillis = if (activeCoordinatorConnection == normalizedConnectionID)
                    activeCoordinatorPublishedAtMillis ?: 0L
                else 0L,
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
                ensureMediaControlCoordinator(
                    uid = uid,
                    selection = IrohPairingSelection.Candidate(
                        connectionId = connectionId,
                        publishedAtMillis = publishedAtMillis,
                    ),
                )
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

    private suspend fun fetchVerifiedPairingTarget(uid: String, connectionId: String): IrohDialTarget {
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
    private suspend fun dialControlStream(target: IrohDialTarget): IrohRelayStream {
        Log.i(
            "BurnBar",
            "Mercury control dial target node=${target.nodeId.take(12)} relay=${target.relayURL != null} directAddresses=${target.directAddresses.size}",
        )
        return controlTransportPool.dial(target, timeoutMillis = MEDIA_CONTROL_DIAL_TIMEOUT_MILLIS)
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
     * Derive a stable device id from `Settings.Secure.ANDROID_ID` SHA-256
     * hashed and base16-encoded. Persist in SharedPreferences so the id
     * survives the user clearing ANDROID_ID across factory resets that
     * preserve app data (the value persists at the same path the iOS
     * APNs branch writes to: `users/{uid}/devices/{deviceId}`).
     */
    @Suppress("HardwareIds")
    private fun resolveStableDeviceId(): String {
        val prefs = getSharedPreferences(DEVICE_ID_PREF_NAME, Context.MODE_PRIVATE)
        prefs.getString(DEVICE_ID_PREF_KEY, null)?.let { return it }
        val androidId = runCatching {
            android.provider.Settings.Secure.getString(
                contentResolver,
                android.provider.Settings.Secure.ANDROID_ID,
            )
        }.getOrNull().orEmpty().ifBlank { "android-${System.currentTimeMillis()}" }
        val digest = MessageDigest.getInstance("SHA-256").digest(androidId.toByteArray(Charsets.UTF_8))
        val hex = buildString(digest.size * 2) {
            for (b in digest) {
                val v = b.toInt() and 0xff
                if (v < 0x10) append('0')
                append(Integer.toHexString(v))
            }
        }
        prefs.edit().putString(DEVICE_ID_PREF_KEY, hex).apply()
        return hex
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

private fun MediaControlStreamCoordinator.Phase.isActiveOrConnecting(): Boolean =
    this is MediaControlStreamCoordinator.Phase.Dialing ||
        this is MediaControlStreamCoordinator.Phase.Live ||
        this is MediaControlStreamCoordinator.Phase.Reconnecting

private fun MediaControlStreamCoordinator.Phase.label(): String = when (this) {
    MediaControlStreamCoordinator.Phase.Idle -> "idle"
    MediaControlStreamCoordinator.Phase.Dialing -> "dialing"
    MediaControlStreamCoordinator.Phase.Live -> "live"
    is MediaControlStreamCoordinator.Phase.Reconnecting -> "reconnecting"
    MediaControlStreamCoordinator.Phase.Stopped -> "stopped"
    is MediaControlStreamCoordinator.Phase.Failed -> "failed"
}

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
