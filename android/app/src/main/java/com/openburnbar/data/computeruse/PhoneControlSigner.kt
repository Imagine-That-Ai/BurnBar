package com.openburnbar.data.computeruse

import com.google.crypto.tink.subtle.Ed25519Sign.KeyPair
import com.openburnbar.irohrelay.HermesRealtimeRelayAgentGrantRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockCredentialEnvelope
import com.openburnbar.irohrelay.HermesRealtimeRelayRemoteUnlockSession
import java.security.SecureRandom

private const val ED25519_SEED_BYTES = 32

/**
 * Android mirror of `ComputerUsePhoneControlSigner`.
 *
 * Signed bytes are:
 *
 *   UTF8(intentHashHex) || u64BE(counter) || i64BE(timestampMillis)
 *
 * `intentHashBlake3` keeps the plan's field name, but v1 uses SHA-256
 * to match the Swift implementation.
 */
object PhoneControlSigner {
    private val random = SecureRandom()

    fun newPrivateKeySeed(): ByteArray = ByteArray(ED25519_SEED_BYTES).also { random.nextBytes(it) }

    fun publicKey(privateKeySeed: ByteArray): ByteArray {
        require(privateKeySeed.size == ED25519_SEED_BYTES) { "Ed25519 private key seed must be 32 bytes" }
        return KeyPair.newKeyPairFromSeed(privateKeySeed).publicKey
    }

    fun canonicalIntentHashHex(intent: PhoneControlIntent): String = PhoneControlSignerCanonical.intentHashHex(intent)

    fun canonicalAgentGrantRequestHashHex(request: HermesRealtimeRelayAgentGrantRequest): String = PhoneControlSignerCanonical.agentGrantRequestHashHex(request)

    fun canonicalClipboardRequestHashHex(request: PhoneControlClipboardRequest): String = PhoneControlSignerCanonical.clipboardRequestHashHex(request)

    fun canonicalRemoteUnlockSessionHashHex(session: HermesRealtimeRelayRemoteUnlockSession): String =
        PhoneControlSignerCanonical.remoteUnlockSessionHashHex(session)

    fun canonicalRemoteUnlockCredentialHashHex(credential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope): String =
        PhoneControlSignerCanonical.remoteUnlockCredentialHashHex(credential)

    fun canonicalAgentContextTargetHashHex(target: PhoneControlAgentContextTarget): String = PhoneControlSignerCanonical.agentContextTargetHashHex(target)

    fun canonicalSystemPermissionRequestHashHex(request: PhoneControlSystemPermissionRequest): String =
        PhoneControlSignerCanonical.systemPermissionRequestHashHex(request)
}
