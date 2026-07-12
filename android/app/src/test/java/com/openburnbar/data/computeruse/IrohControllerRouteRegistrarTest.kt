package com.openburnbar.data.computeruse

import com.google.crypto.tink.subtle.Ed25519Sign
import com.google.crypto.tink.subtle.Ed25519Verify
import com.openburnbar.irohrelay.IrohEndpointIdentity
import java.security.KeyPairGenerator
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class IrohControllerRouteRegistrarTest {
    private val transportSeed = ByteArray(32) { index -> (index + 1).toByte() }
    private val transportPublicKey = Ed25519Sign.KeyPair.newKeyPairFromSeed(transportSeed).publicKey
    private val transportNodeId = transportPublicKey.joinToString("") { "%02x".format(it) }
    private val endpointIdentity = IrohEndpointIdentity(
        nodeId = transportNodeId,
        rawPublicKey = transportPublicKey,
    )
    private val authorityIdentity = PhoneControlSigningIdentity.Ed25519(ByteArray(32) { index -> (index + 41).toByte() })

    @Test
    fun `signs exact decoded challenge bytes with iroh seed and escrow identity`() = runTest {
        var now = 10_000L
        val callables = FakeCallables(nowMillis = { now })
        val registrar = registrar(callables, nowMillis = { now }, renewalScope = backgroundScope)

        val route = registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)

        assertEquals(listOf("publish", "issue", "register"), callables.events)
        assertEquals("android-escrow-device", callables.publishedAuthority?.deviceId)
        assertEquals("android-escrow-device", route.sourceDeviceId)
        assertEquals(transportNodeId, route.transportNodeId)
        assertArrayEquals(callables.lastCanonicalPayload, Base64.getDecoder().decode(callables.lastCanonicalPayloadBase64))
        Ed25519Verify(transportPublicKey).verify(
            Base64.getDecoder().decode(callables.lastTransportSignatureBase64),
            callables.lastCanonicalPayload,
        )
        Ed25519Verify(authorityIdentity.publicKeyRepresentation).verify(
            Base64.getDecoder().decode(requireNotNull(callables.lastAuthoritySignatureBase64)),
            callables.lastCanonicalPayload,
        )
    }

    @Test
    fun `rejects endpoint public key mismatch before any callable`() = runTest {
        val callables = FakeCallables(nowMillis = { 10_000L })
        val registrar = registrar(callables, nowMillis = { 10_000L }, renewalScope = backgroundScope)
        val mismatched = endpointIdentity.copy(rawPublicKey = ByteArray(32) { 7 })

        val error = runCatching { registrar.ensureRegistered("uid-1", "connection-1", mismatched) }.exceptionOrNull()

        assertTrue(error is IllegalArgumentException)
        assertTrue(callables.events.isEmpty())
    }

    @Test
    fun `accepts canonical legacy base32 endpoint identity but registers normalized hex`() = runTest {
        val callables = FakeCallables(nowMillis = { 15_000L })
        val registrar = registrar(callables, nowMillis = { 15_000L }, renewalScope = backgroundScope)
        val legacyIdentity = endpointIdentity.copy(nodeId = base32(transportPublicKey))

        val registration = registrar.ensureRegistered("uid-1", "connection-1", legacyIdentity)

        assertEquals(transportNodeId, registration.transportNodeId)
        assertEquals(listOf(transportNodeId), callables.issuedTransportNodeIds)
    }

    @Test
    fun `single flights concurrent registration and caches until renewal window`() = runTest {
        var now = 20_000L
        val issueGate = CompletableDeferred<Unit>()
        val callables = FakeCallables(nowMillis = { now }, issueGate = issueGate)
        val registrar = registrar(callables, nowMillis = { now }, renewalScope = backgroundScope)

        val first = async { registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity) }
        runCurrent()
        val second = async { registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity) }
        runCurrent()
        assertEquals(1, callables.issueCalls)
        issueGate.complete(Unit)
        assertEquals(first.await(), second.await())
        assertEquals(1, callables.issueCalls)

        now += 479_999L
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        assertEquals(1, callables.issueCalls)
        now += 1L
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        assertEquals(2, callables.issueCalls)
    }

    @Test
    fun `proactively renews a long lived route before expiry without another dial`() = runTest {
        var now = 30_000L
        val callables = FakeCallables(nowMillis = { now })
        val registrar = registrar(
            callables = callables,
            nowMillis = { now },
            renewalScope = backgroundScope,
        )
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        runCurrent()
        assertEquals(1, callables.issueCalls)

        now += 480_000L
        advanceTimeBy(480_000L)
        runCurrent()

        assertEquals(2, callables.issueCalls)
        assertEquals(1L, callables.lastRegistration?.generation)
        assertEquals(listOf(true, false), callables.authoritySignaturePresence)
    }

    @Test
    fun `replacing endpoint ownership cancels the stale route renewal`() = runTest {
        var now = 35_000L
        var activeSeed = transportSeed
        val callables = FakeCallables(nowMillis = { now })
        val registrar = registrar(
            callables = callables,
            nowMillis = { now },
            transportSeedProvider = { activeSeed },
            renewalScope = backgroundScope,
        )
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)

        activeSeed = ByteArray(32) { index -> (index + 91).toByte() }
        val replacementPublicKey = Ed25519Sign.KeyPair.newKeyPairFromSeed(activeSeed).publicKey
        val replacementNodeId = replacementPublicKey.joinToString("") { "%02x".format(it) }
        registrar.ensureRegistered(
            "uid-1",
            "connection-1",
            IrohEndpointIdentity(nodeId = replacementNodeId, rawPublicKey = replacementPublicKey),
        )
        runCurrent()

        now += 480_000L
        advanceTimeBy(480_000L)
        runCurrent()

        assertEquals(listOf(transportNodeId, replacementNodeId, replacementNodeId), callables.issuedTransportNodeIds)
    }

    @Test
    fun `failed proactive renewal expires the cache instead of serving a stale route`() = runTest {
        var now = 37_000L
        val callables = FakeCallables(nowMillis = { now })
        val registrar = registrar(
            callables = callables,
            nowMillis = { now },
            renewalScope = backgroundScope,
        )
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        callables.failIssue = true

        now += 600_001L
        advanceTimeBy(480_000L)
        runCurrent()
        assertEquals(2, callables.issueCalls)

        callables.failIssue = false
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        assertEquals(3, callables.issueCalls)
    }

    @Test
    fun `invalidation tombstones the active route and prevents post signout renewal`() = runTest {
        var now = 39_000L
        val callables = FakeCallables(nowMillis = { now })
        val registrar = registrar(
            callables = callables,
            nowMillis = { now },
            renewalScope = backgroundScope,
        )
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        runCurrent()

        val revocations = registrar.invalidateAll(revokeRemote = true)
        now += 600_000L
        advanceTimeBy(600_000L)
        runCurrent()

        assertEquals(
            listOf(IrohControllerRouteRevocation("connection-1", "android-escrow-device", 2L)),
            revocations,
        )
        assertEquals(listOf("connection-1" to "android-escrow-device"), callables.revokedRoutes)
        assertEquals(1, callables.issueCalls)
        assertEquals(listOf("publish", "issue", "register", "revoke"), callables.events)
    }

    @Test
    fun `registration is rejected while durable revocation is in progress`() = runTest {
        val revokeStarted = CompletableDeferred<Unit>()
        val revokeGate = CompletableDeferred<Unit>()
        val callables = FakeCallables(
            nowMillis = { 40_000L },
            revokeStarted = revokeStarted,
            revokeGate = revokeGate,
        )
        val registrar = registrar(callables, nowMillis = { 40_000L }, renewalScope = backgroundScope)
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)

        val invalidation = async { registrar.invalidateAll(revokeRemote = true) }
        revokeStarted.await()

        val error = runCatching {
            registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        }.exceptionOrNull()
        assertTrue(error is IrohControllerRouteRegistrar.RouteInvalidatedException)
        assertEquals(1, callables.issueCalls)

        revokeGate.complete(Unit)
        invalidation.await()
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        assertEquals(2, callables.issueCalls)
    }

    @Test
    fun `auth transition gate stays closed after revoke until credential clear completes`() = runTest {
        val callables = FakeCallables(nowMillis = { 40_500L })
        val registrar = registrar(callables, nowMillis = { 40_500L }, renewalScope = backgroundScope)
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)

        registrar.beginAuthTransition()
        registrar.invalidateAll(revokeRemote = true)
        val error = runCatching {
            registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        }.exceptionOrNull()

        assertTrue(error is IrohControllerRouteRegistrar.RouteInvalidatedException)
        assertEquals(1, callables.issueCalls)

        registrar.endAuthTransition()
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        assertEquals(2, callables.issueCalls)
    }

    @Test
    fun `process auth gate rejects a new registration before local teardown starts`() = runTest {
        var registrationAllowed = false
        val callables = FakeCallables(nowMillis = { 40_750L })
        val registrar = registrar(
            callables = callables,
            nowMillis = { 40_750L },
            renewalScope = backgroundScope,
            registrationAllowedProvider = { registrationAllowed },
        )

        val error = runCatching {
            registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        }.exceptionOrNull()
        assertTrue(error is IrohControllerRouteRegistrar.RouteInvalidatedException)
        assertEquals(0, callables.issueCalls)

        registrationAllowed = true
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        assertEquals(1, callables.issueCalls)
    }

    @Test
    fun `account replacement during registration prevents route commit under the new user`() = runTest {
        var currentUid: String? = "uid-1"
        val issueGate = CompletableDeferred<Unit>()
        val callables = FakeCallables(nowMillis = { 40_900L }, issueGate = issueGate)
        val registrar = registrar(
            callables = callables,
            nowMillis = { 40_900L },
            renewalScope = backgroundScope,
            currentUidProvider = { currentUid },
        )

        val registration = async {
            registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        }
        runCurrent()
        assertEquals(listOf("publish", "issue"), callables.events)

        currentUid = "uid-2"
        issueGate.complete(Unit)
        val error = runCatching { registration.await() }.exceptionOrNull()

        assertTrue(error is CancellationException)
        assertEquals(listOf("publish", "issue"), callables.events)
        assertEquals(null, callables.lastRegistration)
    }

    @Test
    fun `rejects a server lease beyond the supported maximum`() = runTest {
        val now = 41_000L
        val callables = FakeCallables(
            nowMillis = { now },
            registrationLeaseMillis = IrohControllerRouteRegistrar.MAX_ACCEPTED_LEASE_MILLIS + 1L,
        )
        val registrar = registrar(callables, nowMillis = { now }, renewalScope = backgroundScope)

        val error = runCatching {
            registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        }.exceptionOrNull()

        assertTrue(error is IllegalArgumentException)
        assertTrue(error?.message?.contains("lease exceeds") == true)
        assertEquals(listOf("publish", "issue", "register"), callables.events)
    }

    @Test
    fun `p256 authority proof stays separate from the iroh transport proof`() = runTest {
        val p256 = secureEnclaveP256Identity()
        val callables = FakeCallables(nowMillis = { 40_000L })
        val registrar = registrar(
            callables = callables,
            nowMillis = { 40_000L },
            authorityIdentity = p256,
            promptBoundP256SigningAvailableProvider = { true },
            renewalScope = backgroundScope,
        )

        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)

        assertEquals("se-p256", callables.publishedAuthority?.keyKind)
        assertTrue(callables.publishedAuthority?.peerNodeId?.startsWith("android-se-") == true)
        assertNotEquals(
            callables.publishedAuthority?.publicKeyBase64,
            Base64.getEncoder().encodeToString(transportPublicKey),
        )
        Ed25519Verify(transportPublicKey).verify(
            Base64.getDecoder().decode(callables.lastTransportSignatureBase64),
            callables.lastCanonicalPayload,
        )
        assertTrue(
            PhoneControlP256.verifySignature(
                p256.publicKey,
                Base64.getDecoder().decode(requireNotNull(callables.lastAuthoritySignatureBase64)),
                callables.lastCanonicalPayload,
            ),
        )
    }

    @Test
    fun `p256 authority renews autonomously with transport proof only`() = runTest {
        var now = 45_000L
        var promptAvailabilityChecks = 0
        val p256 = secureEnclaveP256Identity()
        val callables = FakeCallables(nowMillis = { now })
        val registrar = registrar(
            callables = callables,
            nowMillis = { now },
            authorityIdentity = p256,
            promptBoundP256SigningAvailableProvider = {
                promptAvailabilityChecks += 1
                true
            },
            renewalScope = backgroundScope,
        )
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)

        now += 480_000L
        advanceTimeBy(480_000L)
        runCurrent()
        assertEquals(2, callables.issueCalls)
        assertEquals(2, callables.registerCalls)
        assertEquals(listOf(true, false), callables.authoritySignaturePresence)
        assertEquals(1, promptAvailabilityChecks)
        assertEquals(1L, callables.lastRegistration?.generation)
        Ed25519Verify(transportPublicKey).verify(
            Base64.getDecoder().decode(callables.lastTransportSignatureBase64),
            callables.lastCanonicalPayload,
        )
    }

    @Test
    fun `background renewal rejects an unexpected bootstrap before signing or registration`() = runTest {
        var now = 46_000L
        var promptAvailabilityChecks = 0
        val p256 = secureEnclaveP256Identity()
        val callables = FakeCallables(nowMillis = { now })
        val registrar = registrar(
            callables = callables,
            nowMillis = { now },
            authorityIdentity = p256,
            promptBoundP256SigningAvailableProvider = {
                promptAvailabilityChecks += 1
                true
            },
            renewalScope = backgroundScope,
        )
        registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        callables.invalidateServerRoute()

        advanceTimeBy(479_999L)
        now += 480_000L
        advanceTimeBy(1L)
        runCurrent()

        assertEquals(2, callables.issueCalls)
        assertEquals(1, callables.registerCalls)
        assertEquals(listOf(true), callables.authoritySignaturePresence)
        assertEquals(1, promptAvailabilityChecks)
    }

    @Test
    fun `p256 route registration rejects without a prompt bound signer`() = runTest {
        val p256 = secureEnclaveP256Identity()
        val callables = FakeCallables(nowMillis = { 47_000L })
        val registrar = registrar(
            callables = callables,
            nowMillis = { 47_000L },
            authorityIdentity = p256,
            renewalScope = backgroundScope,
        )

        val error = runCatching {
            registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity)
        }.exceptionOrNull()

        assertTrue(error is IrohControllerRouteRegistrar.PromptBoundP256SigningUnavailableException)
        assertTrue(error?.message?.contains("BiometricPrompt CryptoObject") == true)
        assertEquals(listOf("publish", "issue"), callables.events)
        assertEquals(0, callables.registerCalls)
    }

    private fun secureEnclaveP256Identity(): PhoneControlSigningIdentity.SecureEnclaveP256 {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        val keyPair = generator.generateKeyPair()
        val publicKey = when (val candidate = keyPair.public) {
            is ECPublicKey -> candidate
            else -> error("Expected generated EC key pair to expose an ECPublicKey, got ${candidate.algorithm}")
        }
        return PhoneControlSigningIdentity.SecureEnclaveP256(
            privateKey = keyPair.private,
            publicKey = publicKey,
        )
    }

    @Test
    fun `rejects a server payload rebound to another endpoint`() = runTest {
        val callables = FakeCallables(
            nowMillis = { 50_000L },
            payloadTransportNodeId = "00".repeat(32),
        )
        val registrar = registrar(callables, nowMillis = { 50_000L }, renewalScope = backgroundScope)

        val error = runCatching { registrar.ensureRegistered("uid-1", "connection-1", endpointIdentity) }.exceptionOrNull()

        assertTrue(error is IllegalArgumentException)
        assertEquals(listOf("publish", "issue"), callables.events)
    }

    private fun registrar(
        callables: FakeCallables,
        nowMillis: () -> Long,
        authorityIdentity: PhoneControlSigningIdentity = this.authorityIdentity,
        transportSeedProvider: () -> ByteArray = { transportSeed },
        renewalScope: kotlinx.coroutines.CoroutineScope,
        registrationAllowedProvider: () -> Boolean = { true },
        currentUidProvider: () -> String? = { "uid-1" },
        promptBoundP256SigningAvailableProvider: () -> Boolean = { false },
    ): IrohControllerRouteRegistrar = IrohControllerRouteRegistrar(
        callables = callables,
        transportSeedProvider = transportSeedProvider,
        sourceDeviceIdProvider = { "android-escrow-device" },
        authorityIdentityProvider = { authorityIdentity },
        registrationAllowedProvider = registrationAllowedProvider,
        currentUidProvider = currentUidProvider,
        promptBoundP256SigningAvailableProvider = promptBoundP256SigningAvailableProvider,
        nowMillis = nowMillis,
        renewalScope = renewalScope,
    )

    private fun base32(bytes: ByteArray): String {
        val alphabet = "abcdefghijklmnopqrstuvwxyz234567"
        val output = StringBuilder()
        var accumulator = 0
        var bitCount = 0
        for (byte in bytes) {
            accumulator = (accumulator shl 8) or (byte.toInt() and 0xff)
            bitCount += 8
            while (bitCount >= 5) {
                bitCount -= 5
                output.append(alphabet[(accumulator shr bitCount) and 31])
                accumulator = accumulator and ((1 shl bitCount) - 1)
            }
        }
        if (bitCount > 0) output.append(alphabet[(accumulator shl (5 - bitCount)) and 31])
        return output.toString()
    }

    private class FakeCallables(
        private val nowMillis: () -> Long,
        private val issueGate: CompletableDeferred<Unit>? = null,
        private val payloadTransportNodeId: String? = null,
        private val registrationLeaseMillis: Long = 600_000L,
        private val revokeStarted: CompletableDeferred<Unit>? = null,
        private val revokeGate: CompletableDeferred<Unit>? = null,
    ) : IrohControllerRouteCallables {
        val events = mutableListOf<String>()
        var publishedAuthority: PhoneControlAuthorityDoc? = null
        var issueCalls = 0
        var registerCalls = 0
        var lastCanonicalPayload = ByteArray(0)
        var lastCanonicalPayloadBase64 = ""
        var lastTransportSignatureBase64 = ""
        var lastAuthoritySignatureBase64: String? = null
        var lastRegistration: IrohControllerRouteRegistration? = null
        val authoritySignaturePresence = mutableListOf<Boolean>()
        val issuedTransportNodeIds = mutableListOf<String>()
        val revokedRoutes = mutableListOf<Pair<String, String>>()
        var failIssue = false
        private var serverRouteActive = false
        private var serverGeneration = 0L
        private var serverConnectionId = ""
        private var serverSourceDeviceId = ""
        private var serverTransportNodeId = ""
        private var serverAuthorityPeerNodeId = ""
        private var lastChallengeId = ""
        private var lastChallengeGeneration = 0L
        private var lastChallengeProofKind = IrohControllerRouteProofKind.BOOTSTRAP
        private var lastConnectionId = ""
        private var lastSourceDeviceId = ""
        private var lastTransportNodeId = ""
        private var lastAuthorityPeerNodeId = ""

        override suspend fun publishPhoneControlAuthority(expectedUid: String, authority: PhoneControlAuthorityDoc) {
            assertEquals("uid-1", expectedUid)
            events += "publish"
            publishedAuthority = authority
        }

        override suspend fun issueIrohControllerRouteChallenge(
            expectedUid: String,
            sourceDeviceId: String,
            connectionId: String,
            authorityPeerNodeId: String,
            transportNodeId: String,
        ): IrohControllerRouteChallenge {
            assertEquals("uid-1", expectedUid)
            events += "issue"
            issueCalls += 1
            issuedTransportNodeIds += transportNodeId
            if (failIssue) error("simulated route renewal failure")
            issueGate?.await()
            val issuedAt = nowMillis()
            val expiresAt = issuedAt + 60_000L
            val challengeId = "challenge-$issueCalls"
            val isSameActiveRoute = serverRouteActive &&
                serverConnectionId == connectionId &&
                serverSourceDeviceId == sourceDeviceId &&
                serverTransportNodeId == transportNodeId &&
                serverAuthorityPeerNodeId == authorityPeerNodeId
            val proofKind = if (isSameActiveRoute) {
                IrohControllerRouteProofKind.TRANSPORT_RENEWAL
            } else {
                IrohControllerRouteProofKind.BOOTSTRAP
            }
            val generation = if (isSameActiveRoute) serverGeneration else serverGeneration + 1L
            lastChallengeId = challengeId
            lastChallengeGeneration = generation
            lastChallengeProofKind = proofKind
            lastConnectionId = connectionId
            lastSourceDeviceId = sourceDeviceId
            lastTransportNodeId = transportNodeId
            lastAuthorityPeerNodeId = authorityPeerNodeId
            lastCanonicalPayload = canonicalPayload(
                challengeId = challengeId,
                proofKind = proofKind,
                uid = "uid-1",
                connectionId = connectionId,
                sourceDeviceId = sourceDeviceId,
                transportNodeId = payloadTransportNodeId ?: transportNodeId,
                authorityPeerNodeId = authorityPeerNodeId,
                generation = generation,
                issuedAtMillis = issuedAt,
                expiresAtMillis = expiresAt,
            )
            lastCanonicalPayloadBase64 = Base64.getEncoder().encodeToString(lastCanonicalPayload)
            return IrohControllerRouteChallenge(
                challengeId = challengeId,
                canonicalPayloadBase64 = lastCanonicalPayloadBase64,
                signatureAlgorithm = "ed25519",
                proofKind = proofKind,
                requiresAuthorityProof = proofKind == IrohControllerRouteProofKind.BOOTSTRAP,
                registrationGeneration = generation,
                issuedAtMillis = issuedAt,
                expiresAtMillis = expiresAt,
            )
        }

        override suspend fun registerIrohControllerRoute(
            expectedUid: String,
            challengeId: String,
            transportSignatureBase64: String,
            authoritySignatureBase64: String?,
        ): IrohControllerRouteRegistration {
            assertEquals("uid-1", expectedUid)
            events += "register"
            registerCalls += 1
            assertEquals(lastChallengeId, challengeId)
            assertEquals(
                lastChallengeProofKind == IrohControllerRouteProofKind.BOOTSTRAP,
                authoritySignatureBase64 != null,
            )
            lastTransportSignatureBase64 = transportSignatureBase64
            lastAuthoritySignatureBase64 = authoritySignatureBase64
            authoritySignaturePresence += authoritySignatureBase64 != null
            serverRouteActive = true
            serverGeneration = lastChallengeGeneration
            serverConnectionId = lastConnectionId
            serverSourceDeviceId = lastSourceDeviceId
            serverTransportNodeId = lastTransportNodeId
            serverAuthorityPeerNodeId = lastAuthorityPeerNodeId
            val registration = IrohControllerRouteRegistration(
                connectionId = lastConnectionId,
                sourceDeviceId = lastSourceDeviceId,
                transportNodeId = lastTransportNodeId,
                authorityPeerNodeId = lastAuthorityPeerNodeId,
                generation = lastChallengeGeneration,
                expiresAtMillis = nowMillis() + registrationLeaseMillis,
            )
            lastRegistration = registration
            return registration
        }

        override suspend fun revokeIrohControllerRoute(expectedUid: String, sourceDeviceId: String, connectionId: String): IrohControllerRouteRevocation {
            assertEquals("uid-1", expectedUid)
            events += "revoke"
            revokedRoutes += connectionId to sourceDeviceId
            serverRouteActive = false
            serverGeneration += 1L
            revokeStarted?.complete(Unit)
            revokeGate?.await()
            return IrohControllerRouteRevocation(
                connectionId = connectionId,
                sourceDeviceId = sourceDeviceId,
                generation = serverGeneration,
            )
        }

        fun invalidateServerRoute() {
            serverRouteActive = false
        }

        private fun canonicalPayload(
            challengeId: String,
            proofKind: IrohControllerRouteProofKind,
            uid: String,
            connectionId: String,
            sourceDeviceId: String,
            transportNodeId: String,
            authorityPeerNodeId: String,
            generation: Long,
            issuedAtMillis: Long,
            expiresAtMillis: Long,
        ): ByteArray {
            val segments = listOf(
                "version", "2",
                "challengeId", challengeId,
                "challengeNonce", "server-nonce-$challengeId",
                "proofKind", proofKind.wireValue,
                "uid", uid,
                "connectionId", connectionId,
                "sourceDeviceId", sourceDeviceId,
                "transportNodeId", transportNodeId,
                "authorityPeerNodeId", authorityPeerNodeId,
                "registrationGeneration", generation.toString(),
                "issuedAtMillis", issuedAtMillis.toString(),
                "expiresAtMillis", expiresAtMillis.toString(),
            )
            return buildString {
                append("OpenBurnBar-IrohControllerRoute-v2\n")
                segments.forEach { segment ->
                    append(segment.toByteArray(Charsets.UTF_8).size)
                    append(':')
                    append(segment)
                    append('\n')
                }
            }.toByteArray(Charsets.UTF_8)
        }
    }
}
