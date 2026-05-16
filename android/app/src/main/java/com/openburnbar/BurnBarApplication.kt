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
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.messaging.FirebaseMessaging
import com.openburnbar.data.hermes.relay.HermesRelayKeyStore
import com.openburnbar.data.media.AndroidFileTransferService
import com.openburnbar.data.media.MediaControlStreamCoordinator
import com.openburnbar.data.widget.BurnBarWidgetSnapshotStore
import com.openburnbar.data.widget.BurnBarWidgetSyncWorker
import com.openburnbar.irohrelay.IrohDialTarget
import com.openburnbar.irohrelay.IrohRelayStream
import com.openburnbar.irohrelay.IrohRelayTransport
import com.openburnbar.irohrelay.LoopbackIrohRelayRendezvous
import com.openburnbar.irohrelay.LoopbackIrohRelayTransport
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

class BurnBarApplication : Application() {
    companion object {
        lateinit var appContext: Context
            private set

        /** App-process scope used for FCM token persistence and pairing listener bookkeeping. */
        internal val applicationScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        private const val IROH_PAIRING_COLLECTION = "iroh_pairing"
        private const val DEVICE_ID_PREF_NAME = "burnbar.device"
        private const val DEVICE_ID_PREF_KEY = "stable_device_id"

        @Volatile internal var mediaControlCoordinator: MediaControlStreamCoordinator? = null
            private set

        @Volatile internal var fileTransferService: AndroidFileTransferService? = null
            private set
    }

    private var pairingListener: ListenerRegistration? = null
    private var authListener: FirebaseAuth.AuthStateListener? = null
    @Volatile private var activeCoordinatorConnection: String? = null

    override fun onCreate() {
        super.onCreate()
        appContext = applicationContext
        FirebaseApp.initializeApp(this)
        installAppCheckProvider()
        FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(true)
        // Widget snapshot: hydrate from disk + schedule the 15-min refresh.
        BurnBarWidgetSnapshotStore.bind(this)
        BurnBarWidgetSyncWorker.enqueuePeriodic(this)

        // Phase 6: Hermes iroh transport bootstraps lazily — first send on
        // `HermesIrohRelayTransport.transport()` brings the endpoint up.
        // Nothing eager required here.

        // Phase 6: when Firebase Auth is ready AND a paired Mac iroh
        // record exists, dial the media-control coordinator so file
        // transfers can fire without first establishing a chat stream.
        installAuthListener()

        // Phase 6: register the FCM token under
        // users/{uid}/devices/{deviceId}/fcm_token so triggerVoIPCall
        // can send a Mercury push to this device.
        registerFcmToken()
    }

    private fun installAuthListener() {
        val listener = FirebaseAuth.AuthStateListener { auth ->
            val uid = auth.currentUser?.uid
            if (uid == null) {
                tearDownPairingListener()
                stopMediaControlCoordinator()
            } else {
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
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    Log.w("BurnBar", "Iroh pairing listener error: ${error.message}")
                    return@addSnapshotListener
                }
                val connectionId = snapshot?.documents
                    ?.mapNotNull { it.getString("connectionId")?.takeIf { id -> id.isNotBlank() } }
                    ?.firstOrNull()
                    ?: return@addSnapshotListener
                if (connectionId == activeCoordinatorConnection) return@addSnapshotListener
                applicationScope.launch {
                    ensureMediaControlCoordinator(uid = uid, connectionId = connectionId)
                }
            }
    }

    private fun tearDownPairingListener() {
        pairingListener?.remove()
        pairingListener = null
    }

    private suspend fun ensureMediaControlCoordinator(uid: String, connectionId: String) {
        val existing = mediaControlCoordinator
        if (existing != null && activeCoordinatorConnection == connectionId) return
        existing?.stop()
        val receiver = fileTransferService ?: run {
            // Phase 1a / 1b: AndroidFileTransferService is wired by the
            // call surface once a `MediaFileTransferService` (with
            // backend + storage configuration) is configured. Until
            // then we keep the coordinator dormant — Mac → Android push
            // is still served by the chat stream's piggy-back path.
            Log.i("BurnBar", "MediaControlStreamCoordinator deferred: file transfer service not wired yet.")
            return
        }
        val dialer = MediaControlStreamCoordinator.StreamDialer { dialedUid, dialedConnection ->
            dialControlStream(uid = dialedUid, connectionId = dialedConnection)
        }
        val coordinator = MediaControlStreamCoordinator(
            dialer = dialer,
            receiver = receiver,
        )
        mediaControlCoordinator = coordinator
        activeCoordinatorConnection = connectionId
        runCatching { receiver.attachControlStream(coordinator) }
            .onFailure { Log.w("BurnBar", "attachControlStream failed: ${it.message}") }
        runCatching { coordinator.start(uid = uid, connectionID = connectionId) }
            .onFailure { Log.w("BurnBar", "MediaControlStreamCoordinator.start failed: ${it.message}") }
    }

    /**
     * External hook so the in-app dispatcher (or tests) can register an
     * `AndroidFileTransferService` once the file-transfer backend +
     * configuration are available. After registration, the next paired
     * Mac record refresh starts the media-control coordinator.
     */
    fun registerFileTransferService(service: AndroidFileTransferService) {
        fileTransferService = service
        val uid = FirebaseAuth.getInstance().currentUser?.uid
        val connectionId = activeCoordinatorConnection
        if (uid != null && connectionId != null) {
            applicationScope.launch { ensureMediaControlCoordinator(uid = uid, connectionId = connectionId) }
        }
    }

    private fun stopMediaControlCoordinator() {
        val coordinator = mediaControlCoordinator ?: return
        applicationScope.launch { runCatching { coordinator.stop() } }
        mediaControlCoordinator = null
        activeCoordinatorConnection = null
    }

    /**
     * Default control-stream dialer. The production iroh transport is
     * provided through `HermesIrohRelayTransport.defaultTransport(...)`
     * once the AAR is on the classpath; without the AAR we fall back to
     * the in-process loopback transport so the wiring still completes
     * for tests and CI screenshots.
     */
    private suspend fun dialControlStream(uid: String, connectionId: String): IrohRelayStream {
        val keyStore = HermesRelayKeyStore(applicationContext)
        val transport: IrohRelayTransport = runCatching {
            com.openburnbar.data.hermes.relay.HermesIrohRelayTransport.defaultTransport(keyStore = keyStore)
        }.getOrElse { LoopbackIrohRelayTransport(rendezvous = LoopbackIrohRelayRendezvous()) }
        val identity = transport.start()
        // Best-effort dial — the dialer surfaces TimedOut / EndpointNotReady
        // to the coordinator's reconnect loop.
        val target = IrohDialTarget(nodeId = identity.nodeId)
        return transport.connect(target, timeoutMillis = 5_000L)
    }

    private fun registerFcmToken() {
        applicationScope.launch {
            runCatching {
                val token = FirebaseMessaging.getInstance().token.await()
                val uid = FirebaseAuth.getInstance().currentUser?.uid ?: return@runCatching
                val deviceId = resolveStableDeviceId()
                FirebaseFirestore.getInstance()
                    .collection("users").document(uid)
                    .collection("devices").document(deviceId)
                    .set(
                        mapOf(
                            "fcm_token" to token,
                            "platform" to "android",
                            "updated_at_millis" to System.currentTimeMillis(),
                        ),
                        com.google.firebase.firestore.SetOptions.merge(),
                    )
                    .await()
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
        return factoryClass.getMethod("getInstance").invoke(null) as AppCheckProviderFactory
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
