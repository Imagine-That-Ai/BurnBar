package com.openburnbar.data.computeruse

import android.content.Context
import com.google.crypto.tink.subtle.Ed25519Sign
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.hermes.relay.HermesRelayKeyStore
import com.openburnbar.irohrelay.IrohEndpointIdentity
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

data class IrohControllerRouteChallenge(
    val challengeId: String,
    val canonicalPayloadBase64: String,
    val signatureAlgorithm: String,
    val proofKind: IrohControllerRouteProofKind,
    val requiresAuthorityProof: Boolean,
    val registrationGeneration: Long,
    val issuedAtMillis: Long,
    val expiresAtMillis: Long,
)

enum class IrohControllerRouteProofKind(val wireValue: String) {
    BOOTSTRAP("bootstrap"),
    TRANSPORT_RENEWAL("transport-renewal"),
    ;

    companion object {
        fun fromWireValue(raw: String): IrohControllerRouteProofKind = entries.firstOrNull { it.wireValue == raw }
            ?: throw IllegalArgumentException("Controller-route challenge has an unsupported proof kind.")
    }
}

data class IrohControllerRouteRegistration(
    val connectionId: String,
    val sourceDeviceId: String,
    val transportNodeId: String,
    val authorityPeerNodeId: String,
    val generation: Long,
    val expiresAtMillis: Long,
)

data class IrohControllerRouteRevocation(
    val connectionId: String,
    val sourceDeviceId: String,
    val generation: Long,
)

interface IrohControllerRouteCallables {
    suspend fun publishPhoneControlAuthority(expectedUid: String, authority: PhoneControlAuthorityDoc)

    suspend fun issueIrohControllerRouteChallenge(
        expectedUid: String,
        sourceDeviceId: String,
        connectionId: String,
        authorityPeerNodeId: String,
        transportNodeId: String,
    ): IrohControllerRouteChallenge

    suspend fun registerIrohControllerRoute(
        expectedUid: String,
        challengeId: String,
        transportSignatureBase64: String,
        authoritySignatureBase64: String?,
    ): IrohControllerRouteRegistration

    suspend fun revokeIrohControllerRoute(expectedUid: String, sourceDeviceId: String, connectionId: String): IrohControllerRouteRevocation
}

fun interface IrohControllerRouteRegistering {
    suspend fun ensureRegistered(uid: String, connectionId: String, endpointIdentity: IrohEndpointIdentity): IrohControllerRouteRegistration
}

/**
 * Publishes the Android controller's authenticated iroh route before any stream is dialed.
 *
 * The iroh Ed25519 seed is deliberately independent from the phone-control authority identity.
 * The latter may be a non-exportable StrongBox/TEE P-256 key; it authorizes control intents, but
 * only the iroh seed can prove possession of the QUIC endpoint's NodeId.
 */
class IrohControllerRouteRegistrar(
    private val callables: IrohControllerRouteCallables,
    private val transportSeedProvider: () -> ByteArray,
    private val sourceDeviceIdProvider: () -> String,
    private val authorityIdentityProvider: () -> PhoneControlSigningIdentity,
    private val registrationAllowedProvider: () -> Boolean = { true },
    private val currentUidProvider: () -> String? = { null },
    private val promptBoundP256SigningAvailableProvider: () -> Boolean = { false },
    private val nowMillis: () -> Long = { System.currentTimeMillis() },
    private val renewalWindowMillis: Long = DEFAULT_RENEWAL_WINDOW_MILLIS,
    private val renewalRetryMillis: Long = DEFAULT_RENEWAL_RETRY_MILLIS,
    private val renewalScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) : IrohControllerRouteRegistering {
    private val lock = Mutex()
    private val cached = mutableMapOf<RouteKey, IrohControllerRouteRegistration>()
    private val inFlight = mutableMapOf<RouteKey, CompletableDeferred<IrohControllerRouteRegistration>>()
    private val renewalJobs = mutableMapOf<RouteKey, Job>()
    private val activeKeys = mutableMapOf<RouteScope, RouteKey>()
    private val registrationLocks = mutableMapOf<RouteScope, ScopeRegistrationLock>()
    private val invalidatingScopes = mutableSetOf<RouteScope>()
    private val invalidationLock = Mutex()
    private var lifecycleEpoch = 0L
    private var isInvalidating = false
    private var authTransitionDepth = 0

    override suspend fun ensureRegistered(uid: String, connectionId: String, endpointIdentity: IrohEndpointIdentity): IrohControllerRouteRegistration =
        ensureRegistered(
            uid = uid,
            connectionId = connectionId,
            endpointIdentity = endpointIdentity,
            allowAuthorityProof = true,
        )

    private suspend fun ensureRegistered(
        uid: String,
        connectionId: String,
        endpointIdentity: IrohEndpointIdentity,
        allowAuthorityProof: Boolean,
    ): IrohControllerRouteRegistration {
        val inputs = registrationInputs(uid, connectionId, endpointIdentity)
        return when (val decision = claimRegistration(inputs)) {
            is RegistrationDecision.Cached -> {
                requireActive(inputs.routeScope, inputs.key, decision.lifecycleEpoch)
                decision.result
            }
            is RegistrationDecision.Await -> {
                val result = decision.result.await()
                requireActive(inputs.routeScope, inputs.key, decision.lifecycleEpoch)
                result
            }
            is RegistrationDecision.Own -> registerOwned(inputs, decision, allowAuthorityProof)
        }
    }

    private fun registrationInputs(uid: String, connectionId: String, endpointIdentity: IrohEndpointIdentity): RegistrationInputs {
        val normalizedUid = uid.trim().also { require(it.isNotEmpty()) { "uid is required to register an iroh controller route" } }
        val normalizedConnectionId = connectionId.trim().also {
            require(it.isNotEmpty()) { "connectionId is required to register an iroh controller route" }
        }
        val transportSeed = transportSeedProvider().copyOf()
        require(transportSeed.size == ED25519_KEY_BYTES) { "Iroh transport seed must be 32 bytes." }
        val transportPublicKey = Ed25519Sign.KeyPair.newKeyPairFromSeed(transportSeed).publicKey
        val canonicalTransportNodeId = canonicalTransportNodeId(endpointIdentity, transportPublicKey)
        val sourceDeviceId = sourceDeviceIdProvider().trim().also {
            require(it.isNotEmpty()) { "The trusted escrow device identity is required to register an iroh controller route." }
        }
        val authorityIdentity = authorityIdentityProvider()
        val authorityPeerNodeId = PhoneControlAuthorityDocumentFactory.peerNodeId(authorityIdentity)
        val key = RouteKey(
            uid = normalizedUid,
            connectionId = normalizedConnectionId,
            sourceDeviceId = sourceDeviceId,
            transportNodeId = canonicalTransportNodeId,
            authorityPeerNodeId = authorityPeerNodeId,
        )
        val routeScope = RouteScope(normalizedUid, normalizedConnectionId, sourceDeviceId)
        return RegistrationInputs(
            endpointIdentity = endpointIdentity,
            transportSeed = transportSeed,
            authorityIdentity = authorityIdentity,
            key = key,
            routeScope = routeScope,
        )
    }

    private suspend fun claimRegistration(inputs: RegistrationInputs): RegistrationDecision = lock.withLock {
        val key = inputs.key
        val routeScope = inputs.routeScope
        val registrationIsBlocked =
            !registrationAllowedProvider() ||
                currentUidProvider() != key.uid ||
                isInvalidating ||
                authTransitionDepth > 0
        if (registrationIsBlocked) throw RouteInvalidatedException()
        val registrationLock = registrationLocks.getOrPut(routeScope) { ScopeRegistrationLock() }
        val previousKey = activeKeys.put(routeScope, key)
        if (previousKey != null && previousKey != key) {
            cached.remove(previousKey)
            renewalJobs.remove(previousKey)?.cancel(RouteSupersededException())
            inFlight.remove(previousKey)?.cancel(RouteSupersededException())
        }
        cached[key]
            ?.takeIf { it.expiresAtMillis > nowMillis() + renewalWindowMillis }
            ?.let { return@withLock RegistrationDecision.Cached(it, lifecycleEpoch) }
        inFlight[key]?.let { return@withLock RegistrationDecision.Await(it, lifecycleEpoch) }
        val deferred = CompletableDeferred<IrohControllerRouteRegistration>()
        inFlight[key] = deferred
        registrationLock.owners += 1
        RegistrationDecision.Own(deferred, registrationLock, lifecycleEpoch)
    }

    private suspend fun registerOwned(
        inputs: RegistrationInputs,
        ownership: RegistrationDecision.Own,
        allowAuthorityProof: Boolean,
    ): IrohControllerRouteRegistration {
        val key = inputs.key
        val routeScope = inputs.routeScope
        val owner = ownership.result
        val attempt = runCatching {
            val registration = ownership.registrationLock.mutex.withLock {
                register(
                    routeScope,
                    key,
                    inputs.transportSeed,
                    inputs.authorityIdentity,
                    ownership.lifecycleEpoch,
                    allowAuthorityProof,
                )
            }
            cacheOwnedRegistration(inputs, ownership, registration)
            owner.complete(registration)
            scheduleProactiveRenewal(routeScope, key, inputs.endpointIdentity, ownership.lifecycleEpoch)
            registration
        }
        try {
            if (attempt.isFailure) {
                val error = checkNotNull(attempt.exceptionOrNull())
                lock.withLock {
                    if (inFlight[key] === owner) inFlight.remove(key)
                }
                owner.completeExceptionally(error)
            }
            return attempt.getOrThrow()
        } finally {
            releaseRegistrationLock(routeScope, ownership.registrationLock)
        }
    }

    private suspend fun cacheOwnedRegistration(
        inputs: RegistrationInputs,
        ownership: RegistrationDecision.Own,
        registration: IrohControllerRouteRegistration,
    ) {
        val stillActive = lock.withLock {
            if (inFlight[inputs.key] === ownership.result) inFlight.remove(inputs.key)
            val ownsCurrentLifecycle =
                registrationAllowedProvider() &&
                    currentUidProvider() == inputs.key.uid &&
                    lifecycleEpoch == ownership.lifecycleEpoch &&
                    activeKeys[inputs.routeScope] == inputs.key
            if (ownsCurrentLifecycle) cached[inputs.key] = registration
            ownsCurrentLifecycle
        }
        if (!stillActive) throw RouteSupersededException()
        requireActive(inputs.routeScope, inputs.key, ownership.lifecycleEpoch)
    }

    /**
     * Stops all owned renewals and durably tombstones every active route before auth is cleared.
     * The per-scope mutex also orders revocation after any callable already in progress; the
     * server's generation CAS then makes either ordering fail closed.
     */
    suspend fun invalidateAll(revokeRemote: Boolean = true): List<IrohControllerRouteRevocation> = invalidationLock.withLock {
        val invalidations = lock.withLock {
            isInvalidating = true
            lifecycleEpoch += 1
            renewalJobs.values.forEach { it.cancel(RouteInvalidatedException()) }
            renewalJobs.clear()
            inFlight.values.forEach { it.cancel(RouteInvalidatedException()) }
            inFlight.clear()
            cached.clear()

            activeKeys.map { (scope, key) ->
                invalidatingScopes += scope
                val registrationLock = registrationLocks.getOrPut(scope) { ScopeRegistrationLock() }
                RouteInvalidation(scope, key, registrationLock)
            }.also {
                activeKeys.clear()
            }
        }

        try {
            val revoked = mutableListOf<IrohControllerRouteRevocation>()
            var firstFailure: Throwable? = null
            for (invalidation in invalidations) {
                try {
                    val attempt = runCatching {
                        invalidation.registrationLock.mutex.withLock {
                            if (revokeRemote) {
                                callables.revokeIrohControllerRoute(
                                    expectedUid = invalidation.key.uid,
                                    sourceDeviceId = invalidation.key.sourceDeviceId,
                                    connectionId = invalidation.key.connectionId,
                                )
                            } else {
                                null
                            }
                        }
                    }
                    attempt.getOrNull()?.let(revoked::add)
                    attempt.exceptionOrNull()?.let { error ->
                        if (firstFailure == null) firstFailure = error
                    }
                } finally {
                    lock.withLock {
                        invalidatingScopes.remove(invalidation.scope)
                        removeUnusedRegistrationLock(invalidation.scope, invalidation.registrationLock)
                    }
                }
            }
            firstFailure?.let { throw it }
            revoked
        } finally {
            lock.withLock { isInvalidating = false }
        }
    }

    /**
     * Holds registration closed across coordinator teardown, remote revoke, and Firebase auth clear.
     * Invalidating only during the revoke callable leaves a post-revoke window where a reconnect can
     * publish a successor route with the still-current credential.
     */
    suspend fun beginAuthTransition() {
        lock.withLock {
            authTransitionDepth += 1
            lifecycleEpoch += 1
            renewalJobs.values.forEach { it.cancel(RouteInvalidatedException()) }
            renewalJobs.clear()
            inFlight.values.forEach { it.cancel(RouteInvalidatedException()) }
            inFlight.clear()
            cached.clear()
        }
    }

    suspend fun endAuthTransition() {
        lock.withLock {
            check(authTransitionDepth > 0) { "Controller-route auth transition is not active." }
            authTransitionDepth -= 1
        }
    }

    private suspend fun scheduleProactiveRenewal(routeScope: RouteScope, key: RouteKey, endpointIdentity: IrohEndpointIdentity, expectedLifecycleEpoch: Long) {
        lock.withLock {
            if (lifecycleEpoch != expectedLifecycleEpoch || activeKeys[routeScope] != key) return
            if (renewalJobs[key]?.isActive == true) return
            renewalJobs[key] = renewalScope.launch {
                var renewalSucceeded = false
                try {
                    renewalSucceeded = runRenewalLoop(routeScope, key, endpointIdentity, expectedLifecycleEpoch)
                } finally {
                    finishRenewal(routeScope, key, endpointIdentity, expectedLifecycleEpoch, renewalSucceeded)
                }
            }
        }
    }

    private suspend fun runRenewalLoop(routeScope: RouteScope, key: RouteKey, endpointIdentity: IrohEndpointIdentity, expectedLifecycleEpoch: Long): Boolean {
        while (true) {
            val current = lock.withLock {
                if (activeKeys[routeScope] == key) cached[key] else null
            } ?: return false
            val waitMillis = current.expiresAtMillis - renewalWindowMillis - nowMillis()
            if (waitMillis > 0L) delay(waitMillis)
            val attempt = runCatching {
                requireActive(routeScope, key, expectedLifecycleEpoch)
                withContext(NonCancellable) {
                    ensureRegistered(
                        uid = key.uid,
                        connectionId = key.connectionId,
                        endpointIdentity = endpointIdentity,
                        allowAuthorityProof = false,
                    )
                }
            }
            val error = attempt.exceptionOrNull()
            if (error is CancellationException) throw error
            attempt.getOrNull()?.let { renewed ->
                if (!renewed.matches(key)) lock.withLock { cached.remove(key) }
                return renewed.matches(key)
            }
            if (!waitForRenewalRetry(key, current)) return false
        }
    }

    private suspend fun waitForRenewalRetry(key: RouteKey, current: IrohControllerRouteRegistration): Boolean {
        val remaining = current.expiresAtMillis - nowMillis()
        if (remaining <= 0L) {
            lock.withLock {
                cached[key]?.takeIf { it.generation == current.generation }?.let { cached.remove(key) }
            }
            return false
        }
        delay(minOf(renewalRetryMillis, remaining))
        return true
    }

    private suspend fun finishRenewal(
        routeScope: RouteScope,
        key: RouteKey,
        endpointIdentity: IrohEndpointIdentity,
        expectedLifecycleEpoch: Long,
        renewalSucceeded: Boolean,
    ) {
        val thisJob = currentCoroutineContext()[Job]
        val stillOwnsScope = lock.withLock {
            if (renewalJobs[key] === thisJob) renewalJobs.remove(key)
            lifecycleEpoch == expectedLifecycleEpoch && activeKeys[routeScope] == key
        }
        if (renewalSucceeded && stillOwnsScope) {
            scheduleProactiveRenewal(routeScope, key, endpointIdentity, expectedLifecycleEpoch)
        }
    }

    private suspend fun register(
        routeScope: RouteScope,
        key: RouteKey,
        transportSeed: ByteArray,
        authorityIdentity: PhoneControlSigningIdentity,
        expectedLifecycleEpoch: Long,
        allowAuthorityProof: Boolean,
    ): IrohControllerRouteRegistration {
        requireActive(routeScope, key, expectedLifecycleEpoch)
        val authority = PhoneControlAuthorityDocumentFactory.document(
            connectionId = key.connectionId,
            deviceId = key.sourceDeviceId,
            identity = authorityIdentity,
            publishedAtMillis = nowMillis(),
        )
        check(authority.peerNodeId == key.authorityPeerNodeId) { "Phone-control authority changed during route registration." }
        callables.publishPhoneControlAuthority(expectedUid = key.uid, authority = authority)
        requireActive(routeScope, key, expectedLifecycleEpoch)

        val challenge = callables.issueIrohControllerRouteChallenge(
            expectedUid = key.uid,
            sourceDeviceId = key.sourceDeviceId,
            connectionId = key.connectionId,
            authorityPeerNodeId = key.authorityPeerNodeId,
            transportNodeId = key.transportNodeId,
        )
        requireActive(routeScope, key, expectedLifecycleEpoch)
        val canonicalPayload = validateControllerRouteChallenge(
            challenge = challenge,
            expected = key,
            nowMillis = nowMillis(),
        )
        val authoritySignatureBase64 = signControllerRouteAuthorityProof(
            challenge = challenge,
            authorityIdentity = authorityIdentity,
            canonicalPayload = canonicalPayload,
            allowAuthorityProof = allowAuthorityProof,
            promptBoundP256SigningAvailableProvider = promptBoundP256SigningAvailableProvider,
        )
        val transportSignature = Ed25519Sign(transportSeed).sign(canonicalPayload)
        requireActive(routeScope, key, expectedLifecycleEpoch)
        val registration = callables.registerIrohControllerRoute(
            expectedUid = key.uid,
            challengeId = challenge.challengeId,
            transportSignatureBase64 = Base64.getEncoder().encodeToString(transportSignature),
            authoritySignatureBase64 = authoritySignatureBase64,
        )
        requireActive(routeScope, key, expectedLifecycleEpoch)
        validateControllerRouteRegistration(
            registration = registration,
            expected = key,
            challenge = challenge,
            completionMillis = nowMillis(),
            maximumLeaseMillis = MAX_ACCEPTED_LEASE_MILLIS,
        )
        return registration
    }

    private suspend fun requireActive(routeScope: RouteScope, key: RouteKey, expectedLifecycleEpoch: Long) {
        val registrationIsBlocked = !registrationAllowedProvider() || currentUidProvider() != key.uid
        val routeIsInactive = lock.withLock {
            lifecycleEpoch != expectedLifecycleEpoch ||
                routeScope in invalidatingScopes ||
                activeKeys[routeScope] != key
        }
        if (registrationIsBlocked || routeIsInactive) {
            throw RouteSupersededException()
        }
    }

    private suspend fun releaseRegistrationLock(routeScope: RouteScope, registrationLock: ScopeRegistrationLock) {
        lock.withLock {
            registrationLock.owners -= 1
            removeUnusedRegistrationLock(routeScope, registrationLock)
        }
    }

    private fun removeUnusedRegistrationLock(routeScope: RouteScope, registrationLock: ScopeRegistrationLock) {
        if (
            registrationLock.owners == 0 &&
            routeScope !in invalidatingScopes &&
            activeKeys[routeScope] == null &&
            registrationLocks[routeScope] === registrationLock
        ) {
            registrationLocks.remove(routeScope)
        }
    }

    private fun canonicalTransportNodeId(identity: IrohEndpointIdentity, derivedPublicKey: ByteArray): String {
        require(identity.rawPublicKey.size == ED25519_KEY_BYTES) { "Iroh endpoint public key must be 32 bytes." }
        val decodedNodeId = IrohTransportNodeId.decode(identity.nodeId)
        require(decodedNodeId.contentEquals(identity.rawPublicKey)) { "Iroh endpoint NodeId does not match its public key." }
        require(derivedPublicKey.contentEquals(identity.rawPublicKey)) { "Iroh endpoint public key does not match the persisted transport seed." }
        return identity.rawPublicKey.joinToString("") { "%02x".format(it) }
    }

    private data class RegistrationInputs(
        val endpointIdentity: IrohEndpointIdentity,
        val transportSeed: ByteArray,
        val authorityIdentity: PhoneControlSigningIdentity,
        val key: RouteKey,
        val routeScope: RouteScope,
    )
    internal data class RouteKey(
        val uid: String,
        val connectionId: String,
        val sourceDeviceId: String,
        val transportNodeId: String,
        val authorityPeerNodeId: String,
    )

    private data class RouteScope(
        val uid: String,
        val connectionId: String,
        val sourceDeviceId: String,
    )

    private sealed interface RegistrationDecision {
        data class Cached(
            val result: IrohControllerRouteRegistration,
            val lifecycleEpoch: Long,
        ) : RegistrationDecision

        data class Await(
            val result: CompletableDeferred<IrohControllerRouteRegistration>,
            val lifecycleEpoch: Long,
        ) : RegistrationDecision

        data class Own(
            val result: CompletableDeferred<IrohControllerRouteRegistration>,
            val registrationLock: ScopeRegistrationLock,
            val lifecycleEpoch: Long,
        ) : RegistrationDecision
    }

    private class ScopeRegistrationLock(
        val mutex: Mutex = Mutex(),
        var owners: Int = 0,
    )

    private data class RouteInvalidation(
        val scope: RouteScope,
        val key: RouteKey,
        val registrationLock: ScopeRegistrationLock,
    )

    private class RouteSupersededException : CancellationException("Iroh controller route was superseded by a new endpoint identity.")

    internal class RouteInvalidatedException : CancellationException("Iroh controller routes were invalidated.")

    internal class PromptBoundP256SigningUnavailableException : IllegalStateException(
        "StrongBox/TEE controller-route signing requires a BiometricPrompt CryptoObject and is not enabled.",
    )

    internal class AuthorityProofRequiredException : IllegalStateException(
        "Background controller-route renewal cannot satisfy a bootstrap authority proof.",
    )

    companion object {
        internal const val DEFAULT_RENEWAL_WINDOW_MILLIS = 2 * 60 * 1000L
        internal const val DEFAULT_RENEWAL_RETRY_MILLIS = 15 * 1000L
        internal const val MAX_ACCEPTED_LEASE_MILLIS = 15 * 60 * 1000L
        private const val ED25519_KEY_BYTES = 32
    }
}

private const val IROH_ROUTE_SIGNATURE_ALGORITHM = "ed25519"

private fun validateControllerRouteChallenge(
    challenge: IrohControllerRouteChallenge,
    expected: IrohControllerRouteRegistrar.RouteKey,
    nowMillis: Long,
): ByteArray {
    require(challenge.signatureAlgorithm == IROH_ROUTE_SIGNATURE_ALGORITHM) {
        "Controller-route challenge requires an unsupported signature algorithm."
    }
    require(challenge.requiresAuthorityProof == (challenge.proofKind == IrohControllerRouteProofKind.BOOTSTRAP)) {
        "Controller-route challenge authority-proof policy is inconsistent."
    }
    require(challenge.registrationGeneration > 0L) { "Controller-route challenge has an invalid generation." }
    require(challenge.expiresAtMillis > nowMillis) { "Controller-route challenge expired before it could be signed." }
    val canonicalPayload = decodeControllerRouteCanonicalPayload(challenge.canonicalPayloadBase64)
    IrohControllerRouteProofPayload.requireMatches(canonicalPayload, expected, challenge)
    return canonicalPayload
}

private fun signControllerRouteAuthorityProof(
    challenge: IrohControllerRouteChallenge,
    authorityIdentity: PhoneControlSigningIdentity,
    canonicalPayload: ByteArray,
    allowAuthorityProof: Boolean,
    promptBoundP256SigningAvailableProvider: () -> Boolean,
): String? = when (challenge.proofKind) {
    IrohControllerRouteProofKind.TRANSPORT_RENEWAL -> null
    IrohControllerRouteProofKind.BOOTSTRAP -> {
        if (!allowAuthorityProof) throw IrohControllerRouteRegistrar.AuthorityProofRequiredException()
        if (
            authorityIdentity is PhoneControlSigningIdentity.SecureEnclaveP256 &&
            !promptBoundP256SigningAvailableProvider()
        ) {
            throw IrohControllerRouteRegistrar.PromptBoundP256SigningUnavailableException()
        }
        authorityIdentity.signatureBase64(canonicalPayload)
    }
}

private fun validateControllerRouteRegistration(
    registration: IrohControllerRouteRegistration,
    expected: IrohControllerRouteRegistrar.RouteKey,
    challenge: IrohControllerRouteChallenge,
    completionMillis: Long,
    maximumLeaseMillis: Long,
) {
    require(registration.connectionId == expected.connectionId) { "Registered route returned a different connectionId." }
    require(registration.sourceDeviceId == expected.sourceDeviceId) { "Registered route returned a different sourceDeviceId." }
    require(registration.transportNodeId == expected.transportNodeId) { "Registered route returned a different transportNodeId." }
    require(registration.authorityPeerNodeId == expected.authorityPeerNodeId) {
        "Registered route returned a different authorityPeerNodeId."
    }
    require(registration.generation == challenge.registrationGeneration) { "Registered route returned a different generation." }
    require(registration.expiresAtMillis > completionMillis) { "Registered route is already expired." }
    require(registration.expiresAtMillis - completionMillis <= maximumLeaseMillis) {
        "Registered route lease exceeds the supported maximum."
    }
}

private fun decodeControllerRouteCanonicalPayload(encoded: String): ByteArray {
    require(encoded.isNotBlank()) { "Controller-route challenge did not include canonical payload bytes." }
    val decoded = runCatching { Base64.getDecoder().decode(encoded) }
        .getOrElse { throw IllegalArgumentException("Controller-route challenge payload is not canonical base64.", it) }
    require(Base64.getEncoder().encodeToString(decoded) == encoded) {
        "Controller-route challenge payload is not canonical base64."
    }
    return decoded
}

private fun IrohControllerRouteRegistration.matches(key: IrohControllerRouteRegistrar.RouteKey): Boolean = sourceDeviceId == key.sourceDeviceId &&
    transportNodeId == key.transportNodeId &&
    authorityPeerNodeId == key.authorityPeerNodeId

/** One process-wide cache so Hermes chat and retained Mercury control share the same route lease. */
object IrohControllerRouteRegistrarProvider {
    @Volatile private var instance: IrohControllerRouteRegistrar? = null
    private val activeAuthTransitionGates = AtomicInteger()

    internal class AuthTransitionGateToken {
        internal val released = AtomicBoolean(false)
    }

    internal fun holdAuthTransitionGate(): AuthTransitionGateToken {
        activeAuthTransitionGates.incrementAndGet()
        return AuthTransitionGateToken()
    }

    internal fun releaseAuthTransitionGate(token: AuthTransitionGateToken) {
        if (!token.released.compareAndSet(false, true)) return
        check(activeAuthTransitionGates.decrementAndGet() >= 0) { "Controller-route auth transition gate underflow." }
    }

    fun fromContext(context: Context): IrohControllerRouteRegistrar {
        instance?.let { return it }
        return synchronized(this) {
            instance ?: run {
                val applicationContext = context.applicationContext
                val relayKeys = HermesRelayKeyStore(applicationContext)
                val phoneControlKeys = PhoneControlSigningKeyStore(applicationContext)
                IrohControllerRouteRegistrar(
                    callables = ComputerUseSecurityCallableClient(),
                    transportSeedProvider = { relayKeys.irohSecretKeyMaterial().raw },
                    sourceDeviceIdProvider = { AndroidCloudVaultDeviceKeypair.loadOrCreate().deviceId },
                    authorityIdentityProvider = { phoneControlKeys.signingIdentity() },
                    registrationAllowedProvider = { activeAuthTransitionGates.get() == 0 },
                    currentUidProvider = { com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid },
                ).also { instance = it }
            }
        }
    }

    /** Avoids constructing Firebase/key stores during sign-out when no route was ever opened. */
    suspend fun invalidateAllIfCreated(revokeRemote: Boolean = true): List<IrohControllerRouteRevocation> = instance?.invalidateAll(revokeRemote).orEmpty()
}

private object IrohTransportNodeId {
    private const val BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"
    private const val KEY_BYTES = 32
    private const val HEX_NODE_ID_LENGTH = KEY_BYTES * 2
    private const val HEX_CHARACTERS_PER_BYTE = 2
    private const val BASE32_NODE_ID_LENGTH = 52
    private const val BASE32_BITS_PER_CHARACTER = 5
    private const val BITS_PER_BYTE = 8
    private const val BYTE_MASK = 255

    fun decode(raw: String): ByteArray {
        val nodeId = raw.trim()
        if (nodeId.length == HEX_NODE_ID_LENGTH && nodeId.all { it in '0'..'9' || it in 'a'..'f' }) {
            return ByteArray(KEY_BYTES) { index ->
                val start = index * HEX_CHARACTERS_PER_BYTE
                nodeId.substring(start, start + HEX_CHARACTERS_PER_BYTE).toInt(radix = 16).toByte()
            }
        }
        require(nodeId.length == BASE32_NODE_ID_LENGTH && nodeId.all { it in BASE32_ALPHABET }) {
            "Iroh endpoint NodeId must be canonical lowercase hex or base32."
        }
        val bytes = ArrayList<Byte>(KEY_BYTES)
        var accumulator = 0
        var bitCount = 0
        for (character in nodeId) {
            accumulator = (accumulator shl BASE32_BITS_PER_CHARACTER) or BASE32_ALPHABET.indexOf(character)
            bitCount += BASE32_BITS_PER_CHARACTER
            while (bitCount >= BITS_PER_BYTE) {
                bitCount -= BITS_PER_BYTE
                bytes += ((accumulator shr bitCount) and BYTE_MASK).toByte()
                accumulator = accumulator and ((1 shl bitCount) - 1)
            }
        }
        require(bytes.size == KEY_BYTES && accumulator == 0) { "Iroh endpoint NodeId has non-canonical base32 padding." }
        return bytes.toByteArray()
    }
}

private object IrohControllerRouteProofPayload {
    private const val CHALLENGE_NONCE_SEGMENT_INDEX = 5
    private val prefix = "OpenBurnBar-IrohControllerRoute-v2\n".toByteArray(Charsets.UTF_8)

    fun requireMatches(payload: ByteArray, expected: IrohControllerRouteRegistrar.RouteKey, challenge: IrohControllerRouteChallenge) {
        require(payload.size > prefix.size && payload.copyOfRange(0, prefix.size).contentEquals(prefix)) {
            "Controller-route challenge payload has the wrong domain."
        }
        val segments = parseSegments(payload, prefix.size)
        val expectedSegments = listOf(
            "version", "2",
            "challengeId", challenge.challengeId,
            "challengeNonce", segments.getOrNull(CHALLENGE_NONCE_SEGMENT_INDEX).orEmpty(),
            "proofKind", challenge.proofKind.wireValue,
            "uid", expected.uid,
            "connectionId", expected.connectionId,
            "sourceDeviceId", expected.sourceDeviceId,
            "transportNodeId", expected.transportNodeId,
            "authorityPeerNodeId", expected.authorityPeerNodeId,
            "registrationGeneration", challenge.registrationGeneration.toString(),
            "issuedAtMillis", challenge.issuedAtMillis.toString(),
            "expiresAtMillis", challenge.expiresAtMillis.toString(),
        )
        require(segments.size == expectedSegments.size && segments == expectedSegments) {
            "Controller-route challenge payload is not bound to this endpoint and controller."
        }
        require(segments[CHALLENGE_NONCE_SEGMENT_INDEX].isNotBlank()) { "Controller-route challenge nonce is empty." }
    }

    private fun parseSegments(payload: ByteArray, initialOffset: Int): List<String> {
        val result = mutableListOf<String>()
        var offset = initialOffset
        while (offset < payload.size) {
            val colon = payload.indexOf(':'.code.toByte(), startIndex = offset)
            require(colon > offset) { "Controller-route challenge contains malformed framing." }
            val lengthText = payload.copyOfRange(offset, colon).toString(Charsets.US_ASCII)
            require(lengthText == "0" || (lengthText.firstOrNull() in '1'..'9' && lengthText.all(Char::isDigit))) {
                "Controller-route challenge contains a non-canonical frame length."
            }
            val length = lengthText.toIntOrNull() ?: throw IllegalArgumentException("Controller-route challenge frame is too large.")
            val valueStart = colon + 1
            val valueEnd = valueStart + length
            require(valueEnd < payload.size && payload[valueEnd] == '\n'.code.toByte()) {
                "Controller-route challenge contains a truncated frame."
            }
            val decoder = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            val value = runCatching { decoder.decode(ByteBuffer.wrap(payload, valueStart, length)).toString() }
                .getOrElse { throw IllegalArgumentException("Controller-route challenge contains invalid UTF-8.", it) }
            result += value
            offset = valueEnd + 1
        }
        return result
    }

    private fun ByteArray.indexOf(value: Byte, startIndex: Int): Int {
        for (index in startIndex until size) if (this[index] == value) return index
        return -1
    }
}
