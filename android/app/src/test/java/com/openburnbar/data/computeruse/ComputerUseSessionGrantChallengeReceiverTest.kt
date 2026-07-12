package com.openburnbar.data.computeruse

import androidx.fragment.app.FragmentActivity
import com.openburnbar.irohrelay.HermesRealtimeRelaySessionGrantChallenge
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType
import io.mockk.mockk
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ComputerUseSessionGrantChallengeReceiverTest {
    private val foregroundActivity = mockk<FragmentActivity>()

    @Test
    fun `valid challenge is delivered once and completed duplicates are ignored`() = runTest {
        val delivered = mutableListOf<String>()
        val receiver = receiver(scope = this, grantHandler = { _, delivery -> delivered += delivery.challenge.challengeId })

        assertTrue(receiver.ingest(delivery()))
        advanceUntilIdle()
        assertFalse(receiver.ingest(delivery()))
        assertEquals(listOf("challenge-00000001"), delivered)
    }

    @Test
    fun `in flight duplicate is ignored across concurrent stream deliveries`() = runTest {
        val release = CompletableDeferred<Unit>()
        var deliveryCount = 0
        val receiver =
            receiver(
                scope = this,
                grantHandler = { _, _ ->
                    deliveryCount += 1
                    release.await()
                },
            )

        assertTrue(receiver.ingest(delivery()))
        runCurrent()
        assertFalse(receiver.ingest(delivery(route = route(token = "replacement"))))
        release.complete(Unit)
        advanceUntilIdle()
        assertEquals(1, deliveryCount)
    }

    @Test
    fun `unique challenge flood is rejected while one user interaction is active`() = runTest {
        val release = CompletableDeferred<Unit>()
        val handled = mutableListOf<String>()
        val failures = mutableListOf<Pair<String, Throwable>>()
        val receiver =
            receiver(
                scope = this,
                grantHandler = { _, delivery ->
                    handled += delivery.challenge.challengeId
                    release.await()
                },
                failureHandler = { challenge, error -> failures += challenge.challengeId to error },
            )

        assertTrue(receiver.ingest(delivery(challengeId = "challenge-00000001")))
        runCurrent()
        repeat(64) { index ->
            assertFalse(receiver.ingest(delivery(challengeId = "challenge-${(index + 2).toString().padStart(8, '0')}")))
        }

        assertEquals(listOf("challenge-00000001"), handled)
        assertEquals(64, failures.size)
        assertTrue(failures.all { (_, error) -> error is ComputerUseSessionGrantChallengeReceiver.ReceiverError.CapacityExceeded })

        release.complete(Unit)
        advanceUntilIdle()
        assertTrue(receiver.ingest(delivery(challengeId = "challenge-00000066")))
        advanceUntilIdle()
        assertEquals(listOf("challenge-00000001", "challenge-00000066"), handled)
    }

    @Test
    fun `failed user interaction is terminal for the signed challenge`() = runTest {
        var attempts = 0
        val failures = mutableListOf<Throwable>()
        val receiver =
            receiver(
                scope = this,
                grantHandler = { _, _ ->
                    attempts += 1
                    if (attempts == 1) error("offline")
                },
                failureHandler = { _, error -> failures += error },
            )

        assertTrue(receiver.ingest(delivery()))
        advanceUntilIdle()
        assertFalse(receiver.ingest(delivery(route = route(token = "retry"))))
        advanceUntilIdle()

        assertEquals(1, attempts)
        assertEquals("offline", failures.single().message)
    }

    @Test
    fun `cancelled user interaction is terminal for the signed challenge`() = runTest {
        val receiver =
            receiver(
                scope = this,
                grantHandler = { _, _ -> throw CancellationException("user denied") },
            )

        assertTrue(receiver.ingest(delivery()))
        advanceUntilIdle()
        assertFalse(receiver.ingest(delivery(route = route(token = "replayed"))))
    }

    @Test
    fun `missing authenticated route identity is rejected before foreground recovery`() = runTest {
        var foregroundRequests = 0
        val failures = mutableListOf<Throwable>()
        val receiver =
            receiver(
                scope = this,
                foregroundActivityProvider = { _, _ ->
                    foregroundRequests += 1
                    foregroundActivity
                },
                failureHandler = { _, error -> failures += error },
            )

        assertFalse(receiver.ingest(delivery(route = route(remoteNodeId = ""))))
        assertEquals(0, foregroundRequests)
        assertTrue(failures.single() is ComputerUseSessionGrantRoute.RouteError.InvalidBinding)
    }

    @Test
    fun `background challenge resumes on its original authenticated route`() = runTest {
        val foreground = CompletableDeferred<FragmentActivity?>()
        val sentTokens = mutableListOf<String>()
        val exactRoute = route(token = "original-route", sentTokens = sentTokens)
        val receiver =
            receiver(
                scope = this,
                foregroundActivityProvider = { _, _ -> foreground.await() },
                grantHandler = { _, routed ->
                    routed.route.send(responseFrame(), expiresAtMillis = expiresAtMillis())
                },
            )

        assertTrue(receiver.ingest(delivery(route = exactRoute)))
        runCurrent()
        assertTrue(sentTokens.isEmpty())

        foreground.complete(foregroundActivity)
        advanceUntilIdle()
        assertEquals(listOf("original-route"), sentTokens)
    }

    @Test
    fun `route rotation cannot redirect an in flight response`() = runTest {
        val foreground = CompletableDeferred<FragmentActivity?>()
        var originalLive = true
        val sentTokens = mutableListOf<String>()
        val failures = mutableListOf<Throwable>()
        val original = route(token = "original", live = { originalLive }, sentTokens = sentTokens)
        val replacement = route(token = "replacement", sentTokens = sentTokens)
        val receiver =
            receiver(
                scope = this,
                foregroundActivityProvider = { _, _ -> foreground.await() },
                grantHandler = { _, routed ->
                    routed.route.send(responseFrame(), expiresAtMillis = expiresAtMillis())
                },
                failureHandler = { _, error -> failures += error },
            )

        assertTrue(receiver.ingest(delivery(route = original)))
        runCurrent()
        originalLive = false
        assertFalse(receiver.ingest(delivery(route = replacement)))
        foreground.complete(foregroundActivity)
        advanceUntilIdle()

        assertTrue(sentTokens.isEmpty())
        assertTrue(failures.single() is ComputerUseSessionGrantRoute.RouteError.NoLongerLive)

        assertTrue(receiver.ingest(delivery(route = replacement)))
        advanceUntilIdle()
        assertEquals(listOf("replacement"), sentTokens)
    }

    @Test
    fun `exact route rejects a frame rebound to a rotated connection`() = runTest {
        val sentTokens = mutableListOf<String>()
        val error =
            runCatching {
                route(sentTokens = sentTokens).send(
                    HermesRealtimeRelayFrame(
                        type = HermesRealtimeRelayFrameType.CONTROL_AGENT_GRANT_REQUEST,
                        uid = "uid-1",
                        connectionId = "conn-rotated",
                    ),
                    expiresAtMillis = expiresAtMillis(),
                )
            }.exceptionOrNull()

        assertTrue(error is ComputerUseSessionGrantRoute.RouteError.InvalidBinding)
        assertTrue(sentTokens.isEmpty())
    }

    @Test
    fun `expiry cancels a stalled exact stream write`() = runTest {
        val neverCompletes = CompletableDeferred<Unit>()
        val failures = mutableListOf<Throwable>()
        val stalled =
            route(
                token = "stalled",
                frameSink = { neverCompletes.await() },
            )
        val receiver =
            receiver(
                scope = this,
                grantHandler = { _, routed ->
                    routed.route.send(responseFrame(), expiresAtMillis = unixMillis(800_000_101.0))
                },
                failureHandler = { _, error -> failures += error },
            )

        assertTrue(receiver.ingest(delivery(route = stalled)))
        advanceUntilIdle()
        assertTrue(failures.single() is ComputerUseSessionGrantRoute.RouteError.Expired)
    }

    @Test
    fun `expired challenge never requests foreground activity`() = runTest {
        var foregroundRequests = 0
        val failures = mutableListOf<Throwable>()
        val receiver =
            receiver(
                scope = this,
                nowMillis = { unixMillis(800_000_301.0) },
                foregroundActivityProvider = { _, _ ->
                    foregroundRequests += 1
                    foregroundActivity
                },
                failureHandler = { _, error -> failures += error },
            )

        assertFalse(receiver.ingest(delivery()))
        assertEquals(0, foregroundRequests)
        assertTrue(failures.single() is ComputerUseSessionGrantChallengeValidator.ValidationError.Expired)
    }

    private fun receiver(
        scope: kotlinx.coroutines.CoroutineScope,
        nowMillis: () -> Long = { unixMillis(800_000_100.0) },
        foregroundActivityProvider: suspend (String, Long) -> FragmentActivity? = { _, _ -> foregroundActivity },
        grantHandler: suspend (FragmentActivity, ComputerUseSessionGrantChallengeDelivery) -> Unit = { _, _ -> },
        failureHandler: (HermesRealtimeRelaySessionGrantChallenge, Throwable) -> Unit = { _, _ -> },
    ) = ComputerUseSessionGrantChallengeReceiver(
        scope = scope,
        nowMillis = nowMillis,
        foregroundActivityProvider = foregroundActivityProvider,
        grantHandler = grantHandler,
        failureHandler = failureHandler,
    )

    private fun delivery(route: ComputerUseSessionGrantRoute = route(), challengeId: String = "challenge-00000001") =
        ComputerUseSessionGrantChallengeDelivery(challenge = challenge(challengeId), route = route)

    private fun route(
        token: String = "route-1",
        remoteNodeId: String = "linux-host-1",
        live: suspend () -> Boolean = { true },
        sentTokens: MutableList<String>? = null,
        frameSink: (suspend (HermesRealtimeRelayFrame) -> Unit)? = null,
    ) = ComputerUseSessionGrantRoute(
        uid = "uid-1",
        connectionId = "conn-1",
        authenticatedRemoteNodeId = remoteNodeId,
        streamToken = token,
        nowMillis = { unixMillis(800_000_100.0) },
        live = live,
        frameSink = frameSink ?: {
            sentTokens?.add(token)
            Unit
        },
    )

    private fun responseFrame() = HermesRealtimeRelayFrame(
        type = HermesRealtimeRelayFrameType.CONTROL_AGENT_GRANT_REQUEST,
        uid = "uid-1",
        connectionId = "conn-1",
    )

    private fun challenge(challengeId: String = "challenge-00000001"): HermesRealtimeRelaySessionGrantChallenge {
        val unsigned =
            HermesRealtimeRelaySessionGrantChallenge(
                version = 1,
                challengeId = challengeId,
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

    private fun expiresAtMillis(): Long = unixMillis(800_000_300.0)

    private fun unixMillis(swiftReferenceSeconds: Double): Long = AgentCapabilityGrantRequest.unixMillisFromSwiftReferenceSeconds(swiftReferenceSeconds)
}
