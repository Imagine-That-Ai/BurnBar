package com.openburnbar.data.computeruse

import com.google.crypto.tink.subtle.Ed25519Verify
import com.openburnbar.irohrelay.HermesRealtimeRelayAuthorityEnvelope
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import kotlinx.serialization.json.Json
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

private const val ED25519_SEED_BYTES = 32
private const val RAW_SIGNATURE_BYTES = 64
private const val X963_PUBLIC_KEY_BYTES = 65
private const val X963_PREFIX = 0x04.toByte()
private const val NOW_MILLIS = 1_700_000_000_123L

/**
 * F2 — Kotlin mirror of the Swift `PhoneControlAuthoritySigningKeyTests`
 * (`OpenBurnBarCore/Tests/OpenBurnBarComputerUseCoreTests`), plus the
 * DER↔raw codec edge cases and the frozen cross-language `android-se`
 * peerNodeId vector.
 *
 * ⚠️ ECDSA P-256 is non-deterministic — every P-256 assertion verifies a
 * signature, never asserts signature byte equality.
 */
class PhoneControlSigningIdentityTest {
    private val privateSeed = ByteArray(ED25519_SEED_BYTES) { index -> (index + 1).toByte() }

    private fun softwareP256Identity(): PhoneControlSigningIdentity.SecureEnclaveP256 {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"))
        val pair = generator.generateKeyPair()
        return PhoneControlSigningIdentity.SecureEnclaveP256(pair.private, pair.public as? ECPublicKey ?: error("expected EC public key"))
    }

    private fun tapIntent() = PhoneControlIntent(
        kind = PhoneControlIntentKind.TAP,
        normalizedX = 0.25,
        normalizedY = 0.75,
        clientIntentId = "intent-1",
    )

    // MARK: - Legacy byte identity

    @Test
    fun ed25519IdentityEnvelopeIsByteIdenticalToLegacySeedPath() {
        // Ed25519 (RFC 8032) signing is deterministic, so the identity path
        // must produce the exact envelope the pre-F2 seed path produced —
        // including a null keyKind so the wire JSON gains no new field.
        val viaSeed =
            PhoneControlSignerSign.sign(
                intent = tapIntent(),
                peerNodeId = "android-phone-1",
                counter = 7,
                timestampMillis = NOW_MILLIS,
                privateKeySeed = privateSeed,
            )
        val viaIdentity =
            PhoneControlSignerSign.sign(
                intent = tapIntent(),
                peerNodeId = "android-phone-1",
                counter = 7,
                timestampMillis = NOW_MILLIS,
                identity = PhoneControlSigningIdentity.Ed25519(privateSeed),
            )

        assertEquals(viaSeed, viaIdentity)
        assertNull(viaIdentity.keyKind)
        assertNull(viaIdentity.attestationHashBlake3)
    }

    @Test
    fun legacyEnvelopeCanonicalHashUnchangedFrozenVector() {
        // Frozen with python3 hashlib over the canonical JSON
        // {"clientIntentId":"intent-1","kind":"tap","normalizedX":0.25,"normalizedY":0.75}
        // — proves the F2 model fields never reach canonicalization.
        val frozen = "c4239accfcdace4fcd49b1c36bd08d94f5bb75e78edc886ca87637652964af90"
        assertEquals(frozen, PhoneControlSigner.canonicalIntentHashHex(tapIntent()))

        val signed =
            PhoneControlSignerSign.sign(
                intent = tapIntent(),
                peerNodeId = "android-phone-1",
                counter = 1,
                timestampMillis = NOW_MILLIS,
                identity = PhoneControlSigningIdentity.Ed25519(privateSeed),
            )
        assertEquals(frozen, signed.intentHashBlake3)
    }

    // MARK: - P-256 signing + verify path

    @Test
    fun p256SignedEnvelopeVerifiesThroughVerifyPath() {
        val identity = softwareP256Identity()
        val authority =
            PhoneControlSignerSign.sign(
                intent = tapIntent(),
                peerNodeId = "android-se-test",
                counter = 42,
                timestampMillis = NOW_MILLIS,
                identity = identity,
            )

        assertEquals(PhoneControlSigningKeyKind.SECURE_ENCLAVE_P256.wireValue, authority.keyKind)
        // The wire signature is the fixed-size raw r‖s form.
        assertEquals(RAW_SIGNATURE_BYTES, Base64.getDecoder().decode(authority.signatureEd25519).size)

        PhoneControlSignerVerify.verify(
            intent = tapIntent(),
            authority = authority,
            publicKey = identity.publicKeyRepresentation,
            lastSeenCounter = 41,
            nowMillis = NOW_MILLIS,
        )
    }

    @Test
    fun p256SignatureFailsClosedAsEd25519AlgorithmConfusion() {
        val identity = softwareP256Identity()
        val authority =
            PhoneControlSignerSign.sign(
                intent = tapIntent(),
                peerNodeId = "android-se-test",
                counter = 42,
                timestampMillis = NOW_MILLIS,
                identity = identity,
            )

        // Stripped keyKind ⇒ verifier resolves legacy Ed25519 and the raw
        // ECDSA signature must not verify under any Ed25519 key.
        assertThrows(PhoneControlVerifyError.InvalidSignature::class.java) {
            PhoneControlSignerVerify.verify(
                intent = tapIntent(),
                authority = authority.copy(keyKind = null),
                publicKey = PhoneControlSigner.publicKey(privateSeed),
                lastSeenCounter = 41,
                nowMillis = NOW_MILLIS,
            )
        }
        // An Ed25519-sized key under the se-p256 kind fails the key check.
        assertThrows(PhoneControlVerifyError.InvalidPublicKey::class.java) {
            PhoneControlSignerVerify.verify(
                intent = tapIntent(),
                authority = authority,
                publicKey = PhoneControlSigner.publicKey(privateSeed),
                lastSeenCounter = 41,
                nowMillis = NOW_MILLIS,
            )
        }
        // An unknown keyKind fails closed before any state is consumed.
        assertThrows(PhoneControlVerifyError.InvalidSignature::class.java) {
            PhoneControlSignerVerify.verify(
                intent = tapIntent(),
                authority = authority.copy(keyKind = "rsa-4096"),
                publicKey = identity.publicKeyRepresentation,
                lastSeenCounter = 41,
                nowMillis = NOW_MILLIS,
            )
        }
    }

    @Test
    fun p256TamperedIntentFailsBeforeSignatureCheck() {
        val identity = softwareP256Identity()
        val authority =
            PhoneControlSignerSign.sign(
                intent = tapIntent(),
                peerNodeId = "android-se-test",
                counter = 5,
                timestampMillis = NOW_MILLIS,
                identity = identity,
            )

        assertThrows(PhoneControlVerifyError.IntentHashMismatch::class.java) {
            PhoneControlSignerVerify.verify(
                intent = tapIntent().copy(normalizedX = 0.5),
                authority = authority,
                publicKey = identity.publicKeyRepresentation,
                lastSeenCounter = 4,
                nowMillis = NOW_MILLIS,
            )
        }
    }

    @Test
    fun p256ForeignKeyIsRejected() {
        val identity = softwareP256Identity()
        val other = softwareP256Identity()
        val authority =
            PhoneControlSignerSign.sign(
                intent = tapIntent(),
                peerNodeId = "android-se-test",
                counter = 6,
                timestampMillis = NOW_MILLIS,
                identity = identity,
            )

        assertThrows(PhoneControlVerifyError.InvalidSignature::class.java) {
            PhoneControlSignerVerify.verify(
                intent = tapIntent(),
                authority = authority,
                publicKey = other.publicKeyRepresentation,
                lastSeenCounter = 5,
                nowMillis = NOW_MILLIS,
            )
        }
    }

    // MARK: - Public key shapes + peerNodeId derivations

    @Test
    fun publicKeyRepresentationShapes() {
        val ed = PhoneControlSigningIdentity.Ed25519(privateSeed)
        assertEquals(PhoneControlSigningKeyKind.ED25519, ed.kind)
        assertNull(ed.wireKeyKind)
        assertEquals(ED25519_SEED_BYTES, ed.publicKeyRepresentation.size)

        val se = softwareP256Identity()
        assertEquals(PhoneControlSigningKeyKind.SECURE_ENCLAVE_P256, se.kind)
        assertEquals(PhoneControlSigningKeyKind.SECURE_ENCLAVE_P256.wireValue, se.wireKeyKind)
        assertEquals(X963_PUBLIC_KEY_BYTES, se.publicKeyRepresentation.size)
        assertEquals(X963_PREFIX, se.publicKeyRepresentation.first())
    }

    @Test
    fun peerNodeIdDerivationMatchesFrozenCrossLanguageVector() {
        // Frozen with python3 hashlib: sha256(x963)[:24] over the secp256r1
        // generator point. Swift (`PhoneControlPeerNodeIdDerivation`), the
        // server (`requireDerivedPhoneControlPeerNodeId`), and this Kotlin
        // mirror must all derive the identical id from these exact bytes.
        val x963Hex =
            "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" +
                "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
        val expectedPeerNodeId = "android-se-698bea63dc44a344663ff142"

        val x963 = x963Hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val publicKey = PhoneControlP256.publicKeyFromRepresentation(x963)
        checkNotNull(publicKey) { "frozen x963 vector must decode to a P-256 point" }
        // The X9.63 encoder must reproduce the exact frozen bytes.
        assertArrayEquals(x963, PhoneControlP256.x963Representation(publicKey))

        val identity =
            PhoneControlSigningIdentity.SecureEnclaveP256(
                privateKey = softwareP256Identity().privateKey,
                publicKey = publicKey,
            )
        assertEquals(expectedPeerNodeId, PhoneControlAuthorityDocumentFactory.peerNodeId(identity))
    }

    @Test
    fun ed25519PeerNodeIdDerivationIsUnchanged() {
        val identity = PhoneControlSigningIdentity.Ed25519(privateSeed)
        assertEquals(
            PhoneControlAuthorityDocumentFactory.peerNodeId(PhoneControlSigner.publicKey(privateSeed)),
            PhoneControlAuthorityDocumentFactory.peerNodeId(identity),
        )
        // Frozen legacy vector from PhoneControlAuthorityPublisherTest.
        assertEquals("android-phone-65b60673d6ed884bf01c2c22", PhoneControlAuthorityDocumentFactory.peerNodeId(identity))
    }

    // MARK: - DER ↔ raw ECDSA signature codec

    @Test
    fun derToRawConversionRoundTripsJcaSignatures() {
        val identity = softwareP256Identity()
        val payload = PhoneControlSignerPayload.signablePayload("ab".repeat(ED25519_SEED_BYTES), 9, NOW_MILLIS)
        val der =
            Signature.getInstance("SHA256withECDSA").run {
                initSign(identity.privateKey)
                update(payload)
                sign()
            }

        val raw = PhoneControlP256.derToRawSignature(der)
        assertEquals(RAW_SIGNATURE_BYTES, raw.size)
        // raw → DER → JCA verifies, and the dual-acceptance helper takes both forms.
        assertTrue(PhoneControlP256.verifySignature(identity.publicKey, raw, payload))
        assertTrue(PhoneControlP256.verifySignature(identity.publicKey, PhoneControlP256.rawToDerSignature(raw), payload))
        assertFalse(PhoneControlP256.verifySignature(identity.publicKey, raw, payload + 1.toByte()))
    }

    @Test
    fun derToRawHandlesHighBitAndLeadingZeroComponents() {
        // r = 0x80 needs a 0x00 sign pad in DER; s = 0x01 strips 31 raw
        // leading-zero bytes down to a 1-byte DER integer.
        val rawR = ByteArray(ED25519_SEED_BYTES).also { it[ED25519_SEED_BYTES - 1] = 0x80.toByte() }
        val rawS = ByteArray(ED25519_SEED_BYTES).also { it[ED25519_SEED_BYTES - 1] = 0x01 }
        val raw = rawR + rawS

        val der = PhoneControlP256.rawToDerSignature(raw)
        // SEQUENCE(7) { INTEGER(2) 00 80, INTEGER(1) 01 }
        val expectedDer =
            byteArrayOf(
                0x30, 0x07,
                0x02, 0x02, 0x00, 0x80.toByte(),
                0x02, 0x01, 0x01,
            )
        assertArrayEquals(expectedDer, der)
        assertArrayEquals(raw, PhoneControlP256.derToRawSignature(der))
    }

    @Test
    fun derToRawHandlesMaximalComponents() {
        // Both components with every bit set: DER needs the 0x00 sign pad on
        // each component, producing two 33-byte integers.
        val raw = ByteArray(RAW_SIGNATURE_BYTES) { 0xFF.toByte() }
        val der = PhoneControlP256.rawToDerSignature(raw)
        assertEquals(0x30.toByte(), der[0])
        assertArrayEquals(raw, PhoneControlP256.derToRawSignature(der))
    }

    @Test
    fun rawToDerRejectsWrongSizedSignatures() {
        assertThrows(IllegalArgumentException::class.java) {
            PhoneControlP256.rawToDerSignature(ByteArray(ED25519_SEED_BYTES))
        }
        assertThrows(IllegalArgumentException::class.java) {
            PhoneControlP256.derToRawSignature(byteArrayOf(0x02, 0x01, 0x01))
        }
    }

    // MARK: - Local auth proof

    @Test
    fun localAuthProofRoundTripsForBothKinds() {
        val identities =
            listOf(
                PhoneControlSigningIdentity.Ed25519(privateSeed),
                softwareP256Identity(),
            )
        for (identity in identities) {
            val proof =
                PhoneControlSignerSign.signLocalAuthProof(
                    deviceId = "device-1",
                    signedIntentHash = "ABCDEF",
                    authenticatedAtMillis = NOW_MILLIS,
                    expiresAtSwiftReferenceSeconds = 721_692_860.0,
                    identity = identity,
                )
            val payload =
                PhoneControlSignerPayload.localAuthProofPayload(
                    proofId = proof.proofId,
                    deviceId = proof.deviceId,
                    signedIntentHash = proof.signedIntentHash,
                    authenticatedAtSwiftReferenceSeconds = proof.authenticatedAt,
                    expiresAtSwiftReferenceSeconds = proof.expiresAt,
                )
            val signature = Base64.getDecoder().decode(proof.signatureEd25519)
            val verified =
                when (identity) {
                    is PhoneControlSigningIdentity.Ed25519 ->
                        runCatching {
                            Ed25519Verify(PhoneControlSigner.publicKey(privateSeed)).verify(signature, payload)
                            true
                        }.getOrDefault(false)
                    is PhoneControlSigningIdentity.SecureEnclaveP256 ->
                        PhoneControlP256.verifySignature(identity.publicKey, signature, payload)
                }
            assertTrue("local-auth proof must verify for ${identity.kind.wireValue}", verified)
        }
    }

    // MARK: - Wire keyKind parsing + envelope JSON

    @Test
    fun keyKindWireParsingMatchesServerSemantics() {
        // Mirrors `parsePhoneControlSigningKeyKind` (computerUseSecurity.ts).
        assertEquals(PhoneControlSigningKeyKind.ED25519, PhoneControlSigningKeyKind.fromWire(null))
        assertEquals(PhoneControlSigningKeyKind.ED25519, PhoneControlSigningKeyKind.fromWire(""))
        assertEquals(PhoneControlSigningKeyKind.ED25519, PhoneControlSigningKeyKind.fromWire("ed25519"))
        assertEquals(PhoneControlSigningKeyKind.SECURE_ENCLAVE_P256, PhoneControlSigningKeyKind.fromWire("se-p256"))
        assertNull(PhoneControlSigningKeyKind.fromWire("rsa-4096"))
    }

    @Test
    fun relayEnvelopeJsonOmitsKeyKindForLegacyAndRoundTripsForSe() {
        // Same encoder posture as the relay codec (`HermesRealtimeRelayJson`):
        // defaults and nulls are dropped, unknown keys tolerated.
        val json =
            Json {
                ignoreUnknownKeys = true
                encodeDefaults = false
                explicitNulls = false
            }
        val legacy =
            HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId = "android-phone-1",
                counter = 1,
                timestamp = 721_692_800.123,
                intentHashBlake3 = "ab".repeat(ED25519_SEED_BYTES),
                signatureEd25519 = "c2ln",
            )
        val legacyJson = json.encodeToString(HermesRealtimeRelayAuthorityEnvelope.serializer(), legacy)
        assertFalse(legacyJson.contains("keyKind"))
        assertFalse(legacyJson.contains("attestationHashBlake3"))

        val se = legacy.copy(keyKind = "se-p256")
        val seJson = json.encodeToString(HermesRealtimeRelayAuthorityEnvelope.serializer(), se)
        assertTrue(seJson.contains("\"keyKind\":\"se-p256\""))
        assertEquals(se, json.decodeFromString(HermesRealtimeRelayAuthorityEnvelope.serializer(), seJson))
        // A legacy decoder posture (unknown keys ignored) still reads the
        // legacy fields from an SE envelope.
        assertEquals(legacy, json.decodeFromString(HermesRealtimeRelayAuthorityEnvelope.serializer(), legacyJson))
    }

    @Test
    fun bigIntegerMathSanityForX963Codec() {
        // A coordinate with leading zero bytes must round-trip through the
        // fixed-length X9.63 encoder (BigInteger drops leading zeros).
        val identity = softwareP256Identity()
        val x963 = identity.publicKeyRepresentation
        val decoded = PhoneControlP256.publicKeyFromRepresentation(x963)
        checkNotNull(decoded)
        assertArrayEquals(x963, PhoneControlP256.x963Representation(decoded))
        assertEquals(BigInteger(1, x963.copyOfRange(1, 33)), decoded.w.affineX)
        // Compact 64-byte (X‖Y) form also normalizes, mirroring Swift.
        val compact = x963.copyOfRange(1, X963_PUBLIC_KEY_BYTES)
        val fromCompact = PhoneControlP256.publicKeyFromRepresentation(compact)
        checkNotNull(fromCompact)
        assertArrayEquals(x963, PhoneControlP256.x963Representation(fromCompact))
    }
}
