
package com.openburnbar.data.computeruse

import android.content.Context
import android.content.SharedPreferences
import androidx.fragment.app.FragmentActivity
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.BurnBarApplication
import com.openburnbar.irohrelay.HermesRealtimeRelayComputerUseSessionGrantChallenge
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fail-closed entry-gate tests for [AgentCapabilityGrantController]: every
 * grant surface must reject a signed-out user before touching biometrics,
 * device trust, Firestore, or the phone-control sender — and the surfaced
 * errors carry the exact user-facing copy the sheets render.
 */
class AgentCapabilityGrantControllerTest {
    private fun signedOutController(): AgentCapabilityGrantController {
        val context = mockk<Context>()
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), any()) } returns mockk<SharedPreferences>(relaxed = true)
        val auth = mockk<FirebaseAuth>()
        every { auth.currentUser } returns null
        return AgentCapabilityGrantController(
            context = context,
            auth = auth,
            firestore = mockk<FirebaseFirestore>(relaxed = true),
        )
    }

    @Test
    fun `grant fails closed with NotSignedIn before any side effect`() = runTest {
        val error = runCatching {
            signedOutController().grant(
                activity = mockk<FragmentActivity>(),
                runtime = "claude_code",
                threadId = "thread-1",
                preset = AgentPermissionPreset.LOW,
            )
        }.exceptionOrNull()

        // The activity mock is unstubbed: reaching the biometric prompt (or any
        // later stage) would have thrown a MockKException instead.
        assertTrue("expected NotSignedIn, got $error", error is AgentCapabilityGrantController.GrantError.NotSignedIn)
        assertSame(AgentCapabilityGrantController.GrantError.NotSignedIn, error)
    }

    @Test
    fun `live then queued grant queues when no Mac is paired`() = runTest {
        val queue = RecordingGrantQueue()
        val publisher = RecordingAuthorityPublisher()
        val previousCoordinator = BurnBarApplication.mediaControlCoordinator
        BurnBarApplication.mediaControlCoordinator = null
        try {
            val receipt = signedInController(
                queue = queue,
                publisher = publisher,
            ).grant(
                activity = mockk<FragmentActivity>(),
                runtime = "claude_code",
                threadId = "thread-queued",
                preset = AgentPermissionPreset.LOW,
                deliveryMode = AgentGrantDeliveryMode.LIVE_THEN_QUEUED,
            )

            assertEquals(AgentGrantDecisionStatus.QUEUED, receipt.status)
            assertEquals("Mac was unreachable, so this was queued for 5 minutes.", receipt.message)
            assertEquals("device-1", receipt.sourceDeviceId)
        } finally {
            BurnBarApplication.mediaControlCoordinator = previousCoordinator
        }

        assertEquals(1, queue.payloads.size)
        val payload = queue.payloads.single()
        assertEquals("claude_code", payload["runtime"])
        assertEquals("thread-queued", payload["threadId"])
        assertEquals(AgentGrantDeliveryMode.LIVE_THEN_QUEUED.wireValue, payload["deliveryMode"])
        assertEquals("device-1", payload["sourceDeviceId"])
        assertEquals(1, publisher.agentGrantAuthorities.size)
        assertEquals("agent-grant-queued", publisher.agentGrantAuthorities.single().connectionId)
    }

    @Test
    fun `live only grant does not queue when no Mac is paired`() = runTest {
        val queue = RecordingGrantQueue()
        val previousCoordinator = BurnBarApplication.mediaControlCoordinator
        BurnBarApplication.mediaControlCoordinator = null
        val error =
            try {
                runCatching {
                    signedInController(queue = queue).grant(
                        activity = mockk<FragmentActivity>(),
                        runtime = "claude_code",
                        threadId = "thread-live",
                        preset = AgentPermissionPreset.LOW,
                        deliveryMode = AgentGrantDeliveryMode.LIVE,
                    )
                }.exceptionOrNull()
            } finally {
                BurnBarApplication.mediaControlCoordinator = previousCoordinator
            }

        assertSame(AgentCapabilityGrantController.GrantError.NoPairedMac, error)
        assertTrue(queue.payloads.isEmpty())
    }

    @Test
    fun `system permission relay also requires a signed in user`() = runTest {
        val request = PhoneControlSystemPermissionRequest(
            requestId = "req-1",
            kind = PhoneControlSystemPermissionKind.SCREEN_RECORDING,
            action = PhoneControlSystemPermissionAction.PROMPT,
            requestedAtMillis = 1_700_000_000_000L,
        )

        val error = runCatching { signedOutController().sendSystemPermissionRequest(request) }.exceptionOrNull()

        assertSame(AgentCapabilityGrantController.GrantError.NotSignedIn, error)
    }

    @Test
    fun `session challenge is revalidated after biometric before live delivery`() = runTest {
        val queue = RecordingGrantQueue()
        var now = unixMillis(800_000_100.0)
        val controller =
            signedInController(
                queue = queue,
                localAuthenticator = { _, _ ->
                    now = unixMillis(800_000_301.0)
                    true
                },
                nowMillis = { now },
            )

        val error =
            runCatching {
                controller.grant(
                    activity = mockk<FragmentActivity>(),
                    delivery = challengeDelivery(),
                )
            }.exceptionOrNull()

        assertTrue(error is ComputerUseSessionGrantChallengeValidator.ValidationError.Expired)
        assertTrue(queue.payloads.isEmpty())
    }

    @Test
    fun `session challenge response stays on its authenticated connection route`() = runTest {
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val publisher = RecordingAuthorityPublisher()
        val now = unixMillis(800_000_100.0)
        val controller =
            signedInController(
                publisher = publisher,
                localAuthenticator = { _, _ -> true },
                nowMillis = { now },
            )

        val receipt =
            controller.grant(
                activity = mockk<FragmentActivity>(),
                delivery = challengeDelivery(frameSink = { frames += it }),
            )

        val frame = frames.single()
        assertEquals("uid-1", frame.uid)
        assertEquals("conn-session", frame.connectionId)
        assertEquals("challenge-00000001", frame.control?.agentGrantRequest?.requestId)
        assertEquals("Sent to your Linux host.", receipt.message)
        assertEquals(listOf("conn-session"), publisher.authorities.map { it.connectionId })
        assertEquals(listOf("conn-session"), publisher.agentGrantAuthorities.map { it.connectionId })
    }

    @Test
    fun `low preset session challenge still requires device owner authentication`() = runTest {
        val authenticatedPresets = mutableListOf<AgentPermissionPreset>()
        val frames = mutableListOf<HermesRealtimeRelayFrame>()
        val unsigned =
            challenge().copy(
                preset = AgentPermissionPreset.LOW.wireValue,
                capabilities = AgentPermissionPreset.LOW.capabilities.map { it.wireValue },
                sessionIntentId = "pending",
            )
        val lowChallenge =
            unsigned.copy(sessionIntentId = PhoneControlSigner.canonicalComputerUseSessionIntentId(unsigned))
        val controller =
            signedInController(
                localAuthenticator = { _, preset ->
                    authenticatedPresets += preset
                    true
                },
                nowMillis = { unixMillis(800_000_100.0) },
            )

        controller.grant(
            activity = mockk<FragmentActivity>(),
            delivery = challengeDelivery(challenge = lowChallenge, frameSink = { frames += it }),
        )

        assertEquals(listOf(AgentPermissionPreset.LOW), authenticatedPresets)
        assertEquals("challenge-00000001", frames.single().control?.agentGrantRequest?.requestId)
    }

    private fun challengeDelivery(
        challenge: HermesRealtimeRelayComputerUseSessionGrantChallenge = challenge(),
        frameSink: suspend (HermesRealtimeRelayFrame) -> Unit = {},
    ) = ComputerUseSessionGrantChallengeDelivery(
        challenge = challenge,
        route =
        ComputerUseSessionGrantRoute(
            uid = "uid-1",
            connectionId = "conn-session",
            authenticatedRemoteNodeId = "linux-host-1",
            streamToken = "stream-session",
            nowMillis = { unixMillis(800_000_100.0) },
            live = { true },
            frameSink = frameSink,
        ),
    )

    @Test
    fun `grant errors carry the exact user facing copy`() {
        assertEquals(
            "Sign in before granting desktop permissions.",
            AgentCapabilityGrantController.GrantError.NotSignedIn.message,
        )
        assertEquals(
            "Device authentication did not complete.",
            AgentCapabilityGrantController.GrantError.LocalAuthenticationFailed.message,
        )
        assertEquals(
            "No paired Mac is reachable. The request was queued instead.",
            AgentCapabilityGrantController.GrantError.NoPairedMac.message,
        )
        assertEquals(
            "Approve this Android in Devices & Sync before granting Mac control.",
            AgentCapabilityGrantController.GrantError.DeviceNotTrusted.message,
        )
    }

    private fun signedInController(
        queue: RecordingGrantQueue = RecordingGrantQueue(),
        publisher: RecordingAuthorityPublisher = RecordingAuthorityPublisher(),
        localAuthenticator: suspend (FragmentActivity, AgentPermissionPreset) -> Boolean = { _, _ -> false },
        nowMillis: () -> Long = { System.currentTimeMillis() },
    ): AgentCapabilityGrantController {
        val context = mockk<Context>()
        every { context.applicationContext } returns context
        every { context.getSharedPreferences(any(), any()) } returns mockk<SharedPreferences>(relaxed = true)
        val user = mockk<FirebaseUser>()
        every { user.uid } returns "uid-1"
        val auth = mockk<FirebaseAuth>()
        every { auth.currentUser } returns user
        return AgentCapabilityGrantController(
            context = context,
            auth = auth,
            firestore = mockk<FirebaseFirestore>(relaxed = true),
            counterStore = InMemoryPhoneControlCounterStore(),
            trustRegistrar = StaticTrustRegistrar(deviceId = "device-1"),
            signingKeysOverride = StaticGrantSigningKeys(),
            authorityPublisher = publisher,
            grantQueue = queue,
            localAuthenticator = localAuthenticator,
            nowMillis = nowMillis,
            attestationDigestProvider = { null },
            attestationEnforcer = { null },
        )
    }

    private fun challenge(): HermesRealtimeRelayComputerUseSessionGrantChallenge {
        val unsigned =
            HermesRealtimeRelayComputerUseSessionGrantChallenge(
                version = 1,
                challengeId = "challenge-00000001",
                nonce = "0123456789abcdef0123456789abcdef",
                issuedAt = 800_000_000.0,
                expiresAt = 800_000_300.0,
                sessionIntentId = "pending",
                runtime = "codex",
                threadId = "thread-linux-1",
                preset = AgentPermissionPreset.DESKTOP.wireValue,
                capabilities = AgentPermissionPreset.DESKTOP.capabilities.map { it.wireValue },
                mode = "browser",
                trustMode = "manual",
                scopeRuleIds = listOf("workspace-only"),
                phoneViewerNodeId = "phone-viewer-1",
                macHostNodeId = "linux-host-1",
                actionCap = 50,
                sessionTimeoutSeconds = 1_800,
                clientId = "linux-desktop",
                runId = "run-42",
                runCallId = "call-7",
                runGeneration = 4,
                desktopOwnerAuthorizationMethod = "linux_desktop_owner",
            )
        return unsigned.copy(sessionIntentId = PhoneControlSigner.canonicalComputerUseSessionIntentId(unsigned))
    }

    private fun unixMillis(swiftReferenceSeconds: Double): Long = AgentCapabilityGrantRequest.unixMillisFromSwiftReferenceSeconds(swiftReferenceSeconds)

    private class StaticTrustRegistrar(
        private val deviceId: String,
    ) : AgentCapabilityGrantTrustRegistrar {
        override suspend fun trustedSourceDeviceId(uid: String): String = deviceId
    }

    private class StaticGrantSigningKeys : AgentCapabilityGrantSigningKeys {
        private val identity = PhoneControlSigningIdentity.Ed25519(ByteArray(32) { (it + 1).toByte() })

        override fun signingIdentity(): PhoneControlSigningIdentity = identity

        override fun peerNodeId(identity: PhoneControlSigningIdentity): String = PhoneControlAuthorityDocumentFactory.peerNodeId(identity)
    }

    private class RecordingAuthorityPublisher : AgentCapabilityGrantAuthorityPublishing {
        val authorities = mutableListOf<PhoneControlAuthorityDoc>()
        val agentGrantAuthorities = mutableListOf<PhoneControlAuthorityDoc>()

        override suspend fun publish(uid: String, authority: PhoneControlAuthorityDoc) {
            authorities += authority
        }

        override suspend fun publishAgentGrantAuthority(uid: String, sourceDeviceId: String, authority: PhoneControlAuthorityDoc) {
            agentGrantAuthorities += authority
        }
    }

    private class RecordingGrantQueue : AgentCapabilityGrantQueueing {
        val payloads = mutableListOf<Map<String, Any>>()

        override suspend fun queueAgentCapabilityGrantRequest(payload: Map<String, Any>) {
            payloads += payload
        }
    }
}
