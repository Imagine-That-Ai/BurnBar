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
import com.openburnbar.data.computeruse.InMemoryPhoneControlCounterStore
import com.openburnbar.data.computeruse.PhoneControlAuthorityDocumentFactory
import com.openburnbar.data.computeruse.PhoneControlAuthorityPublisher
import com.openburnbar.data.computeruse.PhoneControlAuthorityEnvelope
import com.openburnbar.data.computeruse.PhoneControlIntent
import com.openburnbar.data.computeruse.PhoneControlIntentKind
import com.openburnbar.data.computeruse.PhoneControlSender
import com.openburnbar.data.computeruse.PhoneControlSigner
import com.openburnbar.data.computeruse.PhoneControlSigningKeyStore
import com.openburnbar.data.hermes.HermesConnectionMode
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingDirectory
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingPublicKeyProvider
import com.openburnbar.data.hermes.relay.HermesIrohRelayTransport
import com.openburnbar.data.hermes.relay.HermesRelayKeyStore
import com.openburnbar.data.assistants.PiPendingPrompt
import com.openburnbar.data.media.MediaStreamClass
import com.openburnbar.ui.navigation.BurnBarNavHost
import com.openburnbar.ui.navigation.HermesPendingPrompt
import com.openburnbar.ui.theme.AuroraTheme
import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalResponse
import com.openburnbar.irohrelay.HermesRealtimeRelayControlPayload
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntent
import com.openburnbar.irohrelay.HermesRealtimeRelayInputIntentKind
import com.openburnbar.irohrelay.IrohPairingPublisher
import java.security.MessageDigest
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        stashPendingPromptFromIntent(intent)
        launchE2EMissionFromIntent(intent)
        launchE2EHermesIrohFromIntent(intent)
        launchE2EComputerUseFromIntent(intent)
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
        launchE2EComputerUseFromIntent(intent)
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

    private fun launchE2EComputerUseFromIntent(intent: Intent?) {
        if (!BuildConfig.DEBUG || intent?.getBooleanExtra(EXTRA_E2E_COMPUTER_USE, false) != true) return
        lifecycleScope.launch {
            try {
                val auth = FirebaseAuth.getInstance()
                val expectedUid = intent.getStringExtra(EXTRA_E2E_FIREBASE_UID)
                if (expectedUid.isNullOrBlank() || auth.currentUser?.uid != expectedUid) {
                    val email = intent.getStringExtra(EXTRA_E2E_FIREBASE_EMAIL)?.takeIf { it.isNotBlank() }
                    val password = intent.getStringExtra(EXTRA_E2E_FIREBASE_PASSWORD)?.takeIf { it.isNotBlank() }
                    if (email == null || password == null) {
                        throw IllegalStateException("Android Computer Use E2E requires the expected Firebase user to already be signed in, or email/password extras.")
                    }
                    auth.signInWithEmailAndPassword(email, password).await()
                }
                val uid = auth.currentUser?.uid ?: throw IllegalStateException("Android Computer Use E2E has no signed-in Firebase user.")
                val connectionId = intent.getStringExtra(EXTRA_E2E_COMPUTER_USE_CONNECTION_ID)
                    ?.takeIf { it.isNotBlank() }
                    ?: throw IllegalStateException("Android Computer Use E2E requires connectionId.")
                computerUseProofLog("start uid=$uid connection=$connectionId")

                val pairingPublicKey = FirestoreIrohPairingPublicKeyProvider().fetchPublicKey(uid)
                val target = IrohPairingPublisher(FirestoreIrohPairingDirectory()).fetchAndVerify(
                    uid = uid,
                    connectionId = connectionId,
                    publicKey = pairingPublicKey,
                )
                computerUseProofLog("pairing_verified node=${target.nodeId}")

                val transport = HermesIrohRelayTransport.defaultTransport(
                    keyStore = HermesRelayKeyStore(applicationContext),
                    relayURL = target.relayURL,
                )
                transport.start()
                val stream = transport.connect(target, timeoutMillis = 10_000L)
                computerUseProofLog("dial_opened connection=$connectionId")
                val approvalProof = intent.getBooleanExtra(EXTRA_E2E_COMPUTER_USE_APPROVAL_PROOF, false)
                var approvalCompleted = false

                val keyStore = PhoneControlSigningKeyStore(applicationContext)
                val publicKey = keyStore.publicKey()
                val peerNodeId = keyStore.peerNodeId()
                val deviceId = androidDeviceIdForComputerUseProof()
                val authority = PhoneControlAuthorityDocumentFactory.document(
                    connectionId = connectionId,
                    deviceId = deviceId,
                    publicKey = publicKey,
                    publishedAtMillis = System.currentTimeMillis(),
                )
                computerUseProofLog("authority_attempt peer=$peerNodeId device=$deviceId keys=${authority.asMap().keys.sorted()}")
                PhoneControlAuthorityPublisher().publish(
                    uid = uid,
                    authority = authority,
                )
                computerUseProofLog("authority_published peer=$peerNodeId device=$deviceId")
                val approvalJob = if (approvalProof) {
                    launch {
                        val approvalFrame = withTimeoutOrNull(30_000L) {
                            var matched: HermesRealtimeRelayFrame? = null
                            while (matched == null) {
                                val candidate = stream.receive() ?: break
                                if (candidate.type == HermesRealtimeRelayFrameType.CONTROL_APPROVAL_REQUEST &&
                                    candidate.control?.approvalRequest != null
                                ) {
                                    matched = candidate
                                } else {
                                    computerUseProofLog("approval_wait_ignored_frame type=${candidate.type}")
                                }
                            }
                            matched
                        } ?: throw IllegalStateException("timed out waiting for control approval request")
                        val request = approvalFrame.control?.approvalRequest
                            ?: throw IllegalStateException("approval request frame missing request payload")
                        computerUseProofLog("approval_request_received approvalId=${request.approvalId} tool=${request.toolKind}")
                        stream.send(HermesRealtimeRelayFrame(
                            type = HermesRealtimeRelayFrameType.CONTROL_APPROVAL_RESPONSE,
                            uid = uid,
                            connectionId = connectionId,
                            control = HermesRealtimeRelayControlPayload(
                                streamClass = MediaStreamClass.CONTROL_APPROVAL.raw,
                                sessionId = request.sessionId,
                                approvalResponse = HermesRealtimeRelayApprovalResponse(
                                    approvalId = request.approvalId,
                                    decision = HermesRealtimeRelayApprovalResponse.Decision.APPROVE,
                                    respondedBy = "phone",
                                    respondedAt = swiftDateReferenceSeconds(),
                                    note = "Android live paired-device approval proof",
                                ),
                            ),
                        ))
                        approvalCompleted = true
                        computerUseProofLog("approval_response_sent approvalId=${request.approvalId}")
                    }
                } else {
                    null
                }

                stream.send(HermesRealtimeRelayFrame(
                    type = HermesRealtimeRelayFrameType.CONTROL_CLASSIFY,
                    uid = uid,
                    connectionId = connectionId,
                    control = HermesRealtimeRelayControlPayload(
                        streamClass = MediaStreamClass.CONTROL_INPUT.raw,
                        authorityPeerNodeId = peerNodeId,
                    ),
                ))
                computerUseProofLog("classified_live connection=$connectionId")
                approvalJob?.join()
                if (approvalProof && !approvalCompleted) {
                    throw IllegalStateException("approval proof did not complete")
                }

                var lastSentFrame: HermesRealtimeRelayFrame? = null
                val sender = PhoneControlSender(
                    uid = uid,
                    connectionId = connectionId,
                    peerNodeId = peerNodeId,
                    privateKeySeedProvider = { keyStore.privateKeySeed() },
                    counterStore = InMemoryPhoneControlCounterStore(),
                    frameSink = { frame ->
                        lastSentFrame = frame
                        stream.send(frame)
                    },
                )
                delay(800)
                val intentCount = intent.getIntExtra(EXTRA_E2E_COMPUTER_USE_INTENT_COUNT, 2)
                    .coerceIn(1, 250)
                val intervalMillis = intent.getLongExtra(EXTRA_E2E_COMPUTER_USE_INTENT_INTERVAL_MILLIS, 350L)
                    .coerceIn(0L, 5_000L)
                val sendPanic = intent.getBooleanExtra(EXTRA_E2E_COMPUTER_USE_SEND_PANIC, true)
                val replayCount = intent.getIntExtra(EXTRA_E2E_COMPUTER_USE_REPLAY_COUNT, 0)
                    .coerceIn(0, 1_000)
                val tamperCount = intent.getIntExtra(EXTRA_E2E_COMPUTER_USE_TAMPER_COUNT, 0)
                    .coerceIn(0, 100)
                val tamperTimestampStepMillis = intent.getLongExtra(EXTRA_E2E_COMPUTER_USE_TAMPER_TIMESTAMP_STEP_MILLIS, 0L)
                    .coerceIn(0L, 250L)
                computerUseProofLog("burst_start count=$intentCount intervalMillis=$intervalMillis sendPanic=$sendPanic")
                for (index in 0 until intentCount) {
                    val authority = if (index % 2 == 0) {
                        sender.send(PhoneControlIntent(
                            kind = PhoneControlIntentKind.TAP,
                            normalizedX = 0.18 + ((index % 5) * 0.015),
                            normalizedY = 0.18 + ((index % 3) * 0.015),
                        ))
                    } else {
                        sender.send(PhoneControlIntent(
                            kind = PhoneControlIntentKind.SCROLL,
                            normalizedX = 0.50,
                            normalizedY = 0.62,
                            normalizedX2 = 0.50,
                            normalizedY2 = 0.38,
                        ))
                    }
                    val kind = if (index % 2 == 0) "tap" else "scroll"
                    computerUseProofLog("sent_$kind index=${index + 1} counter=${authority.counter}")
                    if (intervalMillis > 0L) delay(intervalMillis)
                }
                computerUseProofLog("burst_complete count=$intentCount")
                if (replayCount > 0) {
                    val replayFrame = lastSentFrame
                        ?: throw IllegalStateException("replay chaos requires at least one sent frame")
                    computerUseProofLog("replay_chaos_start count=$replayCount")
                    repeat(replayCount) { index ->
                        stream.send(replayFrame)
                        if ((index + 1) % 100 == 0) {
                            computerUseProofLog("replay_chaos_progress count=${index + 1}")
                        }
                    }
                    computerUseProofLog("replay_chaos_complete count=$replayCount")
                }
                if (tamperCount > 0) {
                    val privateKeySeed = keyStore.privateKeySeed()
                        ?: throw IllegalStateException("tamper chaos requires a phone-control private key")
                    computerUseProofLog("tamper_chaos_start count=$tamperCount")
                    for (index in 0 until tamperCount) {
                        val counter = intentCount.toLong() + index + 1L
                        val signedIntent = PhoneControlIntent(
                            kind = PhoneControlIntentKind.TAP,
                            normalizedX = 0.22,
                            normalizedY = 0.22,
                        )
                        val tamperedIntent = signedIntent.copy(normalizedX = 0.42 + ((index % 5) * 0.01))
                        val authority = PhoneControlSigner.sign(
                            intent = signedIntent,
                            peerNodeId = peerNodeId,
                            counter = counter,
                            timestampMillis = System.currentTimeMillis() + (index * tamperTimestampStepMillis),
                            privateKeySeed = privateKeySeed,
                        )
                        stream.send(computerUseIntentFrame(
                            uid = uid,
                            connectionId = connectionId,
                            intent = tamperedIntent,
                            authority = authority,
                        ))
                        if ((index + 1) % 20 == 0) {
                            computerUseProofLog("tamper_chaos_progress count=${index + 1}")
                        }
                    }
                    computerUseProofLog("tamper_chaos_complete count=$tamperCount")
                }
                if (sendPanic) {
                    val authority = sender.send(PhoneControlIntent(kind = PhoneControlIntentKind.PANIC))
                    computerUseProofLog("sent_panic counter=${authority.counter}")
                }
                if (replayCount > 0 || tamperCount > 0) {
                    delay(3_000)
                }
                stream.close()
                transport.shutdown()
            } catch (err: Throwable) {
                computerUseProofLog("failed error=${err.message ?: err.javaClass.simpleName}")
                Log.e(TAG, "Android Computer Use E2E failed: ${err.message}", err)
            }
        }
    }

    private fun computerUseIntentFrame(
        uid: String,
        connectionId: String,
        intent: PhoneControlIntent,
        authority: PhoneControlAuthorityEnvelope,
    ): HermesRealtimeRelayFrame =
        HermesRealtimeRelayFrame(
            type = HermesRealtimeRelayFrameType.CONTROL_INPUT_INTENT,
            uid = uid,
            connectionId = connectionId,
            control = HermesRealtimeRelayControlPayload(
                streamClass = MediaStreamClass.CONTROL_INPUT.raw,
                inputIntent = HermesRealtimeRelayInputIntent(
                    kind = when (intent.kind) {
                        PhoneControlIntentKind.TAP -> HermesRealtimeRelayInputIntentKind.TAP
                        PhoneControlIntentKind.DRAG_START -> HermesRealtimeRelayInputIntentKind.DRAG_START
                        PhoneControlIntentKind.DRAG_MOVE -> HermesRealtimeRelayInputIntentKind.DRAG_MOVE
                        PhoneControlIntentKind.DRAG_END -> HermesRealtimeRelayInputIntentKind.DRAG_END
                        PhoneControlIntentKind.TYPE -> HermesRealtimeRelayInputIntentKind.TYPE
                        PhoneControlIntentKind.SHORTCUT -> HermesRealtimeRelayInputIntentKind.SHORTCUT
                        PhoneControlIntentKind.SCROLL -> HermesRealtimeRelayInputIntentKind.SCROLL
                        PhoneControlIntentKind.PANIC -> HermesRealtimeRelayInputIntentKind.PANIC
                    },
                    normalizedX = intent.normalizedX,
                    normalizedY = intent.normalizedY,
                    normalizedX2 = intent.normalizedX2,
                    normalizedY2 = intent.normalizedY2,
                    text = intent.text,
                    key = intent.key,
                    modifiers = intent.modifiers,
                    authority = HermesRealtimeRelayAuthorityEnvelope(
                        peerNodeId = authority.peerNodeId,
                        counter = authority.counter,
                        timestamp = authority.swiftDateReferenceSeconds,
                        intentHashBlake3 = authority.intentHashBlake3,
                        signatureEd25519 = authority.signatureEd25519,
                    ),
                ),
            ),
        )

    @Suppress("HardwareIds")
    private fun androidDeviceIdForComputerUseProof(): String {
        val androidId = android.provider.Settings.Secure.getString(
            contentResolver,
            android.provider.Settings.Secure.ANDROID_ID,
        ).orEmpty()
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(androidId.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return "android-$digest"
    }

    private fun swiftDateReferenceSeconds(nowMillis: Long = System.currentTimeMillis()): Double =
        (nowMillis.toDouble() / 1_000.0) - 978_307_200.0

    private fun computerUseProofLog(message: String) {
        val line = "AndroidComputerUseE2E $message"
        Log.i(TAG, line)
        val payload = """{"event":"${message.replace("\"", "\\\"")}","timestamp":${System.currentTimeMillis()}}""" + "\n"
        runCatching {
            openFileOutput("computer-use-e2e-proof.jsonl", MODE_APPEND).use {
                it.write(payload.toByteArray(Charsets.UTF_8))
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
        const val EXTRA_E2E_COMPUTER_USE = "openburnbar.e2e.computerUse"
        const val EXTRA_E2E_COMPUTER_USE_CONNECTION_ID = "openburnbar.e2e.computerUseConnectionId"
        const val EXTRA_E2E_COMPUTER_USE_INTENT_COUNT = "openburnbar.e2e.computerUseIntentCount"
        const val EXTRA_E2E_COMPUTER_USE_INTENT_INTERVAL_MILLIS = "openburnbar.e2e.computerUseIntentIntervalMillis"
        const val EXTRA_E2E_COMPUTER_USE_SEND_PANIC = "openburnbar.e2e.computerUseSendPanic"
        const val EXTRA_E2E_COMPUTER_USE_REPLAY_COUNT = "openburnbar.e2e.computerUseReplayCount"
        const val EXTRA_E2E_COMPUTER_USE_TAMPER_COUNT = "openburnbar.e2e.computerUseTamperCount"
        const val EXTRA_E2E_COMPUTER_USE_TAMPER_TIMESTAMP_STEP_MILLIS = "openburnbar.e2e.computerUseTamperTimestampStepMillis"
        const val EXTRA_E2E_COMPUTER_USE_APPROVAL_PROOF = "openburnbar.e2e.computerUseApprovalProof"
        private const val ANDROID_HERMES_IROH_E2E_TIMEOUT_MILLIS = 600_000L
    }
}
