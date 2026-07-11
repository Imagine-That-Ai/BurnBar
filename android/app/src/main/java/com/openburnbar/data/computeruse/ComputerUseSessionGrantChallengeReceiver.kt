package com.openburnbar.data.computeruse

import androidx.fragment.app.FragmentActivity
import com.openburnbar.irohrelay.HermesRealtimeRelayComputerUseSessionGrantChallenge
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** The authenticated, exact iroh stream on which a Linux challenge arrived. */
class ComputerUseSessionGrantRoute(
    val uid: String,
    val connectionId: String,
    val authenticatedRemoteNodeId: String,
    val streamToken: String,
    private val nowMillis: () -> Long = { System.currentTimeMillis() },
    private val live: suspend () -> Boolean,
    private val frameSink: suspend (HermesRealtimeRelayFrame) -> Unit,
) {
    sealed class RouteError(message: String) : RuntimeException(message) {
        object InvalidBinding : RouteError("The session grant route binding is invalid.")

        object NoLongerLive : RouteError("The exact iroh stream carrying the challenge is no longer live.")

        object Expired : RouteError("The session grant challenge expired before its response was delivered.")
    }

    fun validate() {
        if (uid.isBlank() || connectionId.isBlank() || authenticatedRemoteNodeId.isBlank() || streamToken.isBlank()) {
            throw RouteError.InvalidBinding
        }
    }

    suspend fun requireLive() {
        if (!live()) throw RouteError.NoLongerLive
    }

    /** Sends only on this route, bounded by challenge expiry and never through a replacement stream. */
    suspend fun send(frame: HermesRealtimeRelayFrame, expiresAtMillis: Long) {
        if (frame.uid != uid || frame.connectionId != connectionId) throw RouteError.InvalidBinding
        val remainingMillis = expiresAtMillis - nowMillis()
        if (remainingMillis <= 0L) throw RouteError.Expired
        requireLive()
        val sent =
            withTimeoutOrNull(remainingMillis) {
                // Recheck after all signing/attestation work and immediately before the actual write.
                if (nowMillis() >= expiresAtMillis) throw RouteError.Expired
                requireLive()
                frameSink(frame)
                true
            }
        if (sent != true) throw RouteError.Expired
    }
}

/** Keeps the challenge's desktop device id distinct from the route's authenticated QUIC NodeId. */
data class ComputerUseSessionGrantChallengeDelivery(
    val challenge: HermesRealtimeRelayComputerUseSessionGrantChallenge,
    val route: ComputerUseSessionGrantRoute,
)

/**
 * Process-scoped receiver for Linux session-grant challenges arriving on either live iroh stream.
 * A challenge remains pending while the app is backgrounded, but no later than its signed expiry.
 */
class ComputerUseSessionGrantChallengeReceiver(
    private val scope: CoroutineScope,
    private val nowMillis: () -> Long = { System.currentTimeMillis() },
    private val foregroundActivityProvider: suspend (challengeId: String, expiresAtMillis: Long) -> FragmentActivity?,
    private val grantHandler: suspend (FragmentActivity, ComputerUseSessionGrantChallengeDelivery) -> Unit,
    private val failureHandler: (HermesRealtimeRelayComputerUseSessionGrantChallenge, Throwable) -> Unit = { _, _ -> },
) {
    sealed class ReceiverError(message: String) : RuntimeException(message) {
        object CapacityExceeded : ReceiverError("Another session grant challenge is already awaiting user interaction.")
    }

    private val state = Any()
    private val inFlight = mutableSetOf<String>()
    private val completedExpirations = linkedMapOf<String, Long>()

    /** Returns true only when this delivery starts a new exact-route grant attempt. */
    fun ingest(delivery: ComputerUseSessionGrantChallengeDelivery): Boolean {
        val challenge = delivery.challenge
        val receivedAtMillis = nowMillis()
        try {
            ComputerUseSessionGrantChallengeValidator.validate(challenge, nowMillis = receivedAtMillis)
            delivery.route.validate()
        } catch (error: Throwable) {
            failureHandler(challenge, error)
            return false
        }

        val expiresAtMillis = AgentCapabilityGrantRequest.unixMillisFromSwiftReferenceSeconds(challenge.expiresAt)
        val admissionError = synchronized(state) {
            completedExpirations.entries.removeAll { (_, expiry) -> expiry <= receivedAtMillis }
            if (challenge.challengeId in inFlight || challenge.challengeId in completedExpirations) return false
            if (scope.coroutineContext[Job]?.isActive == false) return false
            if (inFlight.size >= MAXIMUM_IN_FLIGHT_CHALLENGES) {
                ReceiverError.CapacityExceeded
            } else {
                inFlight += challenge.challengeId
                null
            }
        }
        if (admissionError != null) {
            failureHandler(challenge, admissionError)
            return false
        }

        scope.launch {
            try {
                val activity = foregroundActivityProvider(challenge.challengeId, expiresAtMillis)
                    ?: throw ComputerUseSessionGrantRoute.RouteError.Expired
                ComputerUseSessionGrantChallengeValidator.validate(challenge, nowMillis = nowMillis())
                delivery.route.validate()
                delivery.route.requireLive()
                // Once user-facing grant handling begins, this signed challenge is terminal.
                // A denial, cancellation, or downstream failure must not allow the host to
                // replay the same challenge and repeatedly trigger biometric prompts.
                markTerminal(challenge.challengeId, expiresAtMillis)
                grantHandler(activity, delivery)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                failureHandler(challenge, error)
            } finally {
                synchronized(state) { inFlight -= challenge.challengeId }
            }
        }
        return true
    }

    private fun markTerminal(challengeId: String, expiresAtMillis: Long) {
        synchronized(state) {
            completedExpirations[challengeId] = expiresAtMillis
            while (completedExpirations.size > MAXIMUM_COMPLETED_CHALLENGES) {
                completedExpirations.entries.iterator().run {
                    next()
                    remove()
                }
            }
        }
    }

    private companion object {
        const val MAXIMUM_IN_FLIGHT_CHALLENGES = 1
        const val MAXIMUM_COMPLETED_CHALLENGES = 128
    }
}
