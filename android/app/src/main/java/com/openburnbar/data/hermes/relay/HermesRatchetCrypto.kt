
package com.openburnbar.data.hermes.relay

import java.io.ByteArrayOutputStream
import java.security.AlgorithmParameters
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPrivateKeySpec
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

enum class HermesRatchetError {
    INVALID_BASE64,
    INVALID_KEY_LENGTH,
    INVALID_PUBLIC_KEY,
    INVALID_PRIVATE_KEY,
    MISSING_SENDING_CHAIN,
    MISSING_RECEIVING_CHAIN,
    TOO_MANY_SKIPPED_KEYS,
    SKIPPED_KEY_LIMIT_EXCEEDED,
    INVALID_ENVELOPE,
    AUTHENTICATION_FAILED,
}

class HermesRatchetException(
    val error: HermesRatchetError,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

enum class HermesRatchetRole(val wireName: String) {
    INITIATOR("initiator"),
    RESPONDER("responder"),
}

data class HermesRatchetKeyPair(
    val privateKeyBase64: String,
    val publicKeyBase64: String,
)

data class HermesRatchetHeader(
    val version: Int = HermesRatchetCrypto.VERSION,
    val algorithm: String = HermesRatchetCrypto.ALGORITHM,
    val sessionID: String,
    val senderDeviceID: String,
    val receiverDeviceID: String,
    val ratchetPublicKeyBase64: String,
    val previousChainLength: Int,
    val messageNumber: Int,
    val epoch: Int,
)

data class HermesRatchetEnvelope(
    val header: HermesRatchetHeader,
    val ciphertextBase64: String,
)

data class HermesRatchetSessionState(
    var role: HermesRatchetRole,
    var sessionID: String,
    var localDeviceID: String,
    var remoteDeviceID: String,
    var rootKeyBase64: String,
    var sendingChainKeyBase64: String? = null,
    var receivingChainKeyBase64: String? = null,
    var sendingRatchetPrivateKeyBase64: String,
    var remoteRatchetPublicKeyBase64: String? = null,
    var sendMessageNumber: Int = 0,
    var receiveMessageNumber: Int = 0,
    var previousSendingChainLength: Int = 0,
    var epoch: Int = 0,
    var maxSkip: Int = HermesRatchetCrypto.DEFAULT_MAX_SKIP,
    var skippedMessageKeys: MutableMap<String, String> = mutableMapOf(),
)

object HermesRatchetCrypto {
    const val VERSION = 1
    const val ALGORITHM = "OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM"
    const val DEFAULT_MAX_SKIP = 64

    internal const val AAD_DOMAIN = "OpenBurnBar-HermesRatchet-v1-AAD"
    internal const val ROOT_INFO = "OpenBurnBar-HermesRatchet-v1-root"
    internal const val CHAIN_LABEL = "OpenBurnBar-HermesRatchet-v1-chain"
    internal const val MESSAGE_LABEL = "OpenBurnBar-HermesRatchet-v1-message"

    private const val AES_KEY_BYTES = 32
    private const val GCM_IV_BYTES = 12
    private const val GCM_TAG_BITS = 128
    private const val HKDF_ROOT_OUTPUT_BYTES = 64
    private const val P256_PRIVATE_BYTES = 32
    private const val P256_PUBLIC_BYTES = 65
    private const val P256_CURVE_NAME = "secp256r1"
    private const val BYTE_MASK = 0xffL

    private val secureRandom = SecureRandom()

    fun generateKeyPair(): HermesRatchetKeyPair {
        val pair = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val publicKey = pair.public as? java.security.interfaces.ECPublicKey
            ?: error("Hermes ratchet generated keypair must use an EC public key")
        return HermesRatchetKeyPair(
            privateKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(encodeRawPrivateKey(pair.private)),
            publicKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(HermesRelayCryptoEc.encodeUncompressedPublicKey(publicKey)),
        )
    }

    fun randomRootKey(): ByteArray = ByteArray(AES_KEY_BYTES).also(secureRandom::nextBytes)

    fun initiatorState(
        sessionID: String,
        localDeviceID: String,
        remoteDeviceID: String,
        sharedSecret: ByteArray,
        remoteInitialRatchetPublicKeyBase64: String,
        localInitialRatchetKeyPair: HermesRatchetKeyPair = generateKeyPair(),
        maxSkip: Int = DEFAULT_MAX_SKIP,
    ): HermesRatchetSessionState {
        validateSymmetricKey(sharedSecret, "sharedSecret")
        val localPrivateKey = privateKeyFromBase64(localInitialRatchetKeyPair.privateKeyBase64)
        val remotePublicKey = publicKeyFromBase64(remoteInitialRatchetPublicKeyBase64)
        val derived = rootKDF(sharedSecret, HermesRelayCryptoEc.ecdh(localPrivateKey, remotePublicKey))
        return HermesRatchetSessionState(
            role = HermesRatchetRole.INITIATOR,
            sessionID = sessionID,
            localDeviceID = localDeviceID,
            remoteDeviceID = remoteDeviceID,
            rootKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(derived.rootKey),
            sendingChainKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(derived.chainKey),
            sendingRatchetPrivateKeyBase64 = localInitialRatchetKeyPair.privateKeyBase64,
            remoteRatchetPublicKeyBase64 = remoteInitialRatchetPublicKeyBase64,
            maxSkip = maxSkip,
        )
    }

    fun responderState(
        sessionID: String,
        localDeviceID: String,
        remoteDeviceID: String,
        sharedSecret: ByteArray,
        localInitialRatchetKeyPair: HermesRatchetKeyPair,
        maxSkip: Int = DEFAULT_MAX_SKIP,
    ): HermesRatchetSessionState {
        validateSymmetricKey(sharedSecret, "sharedSecret")
        privateKeyFromBase64(localInitialRatchetKeyPair.privateKeyBase64)
        return HermesRatchetSessionState(
            role = HermesRatchetRole.RESPONDER,
            sessionID = sessionID,
            localDeviceID = localDeviceID,
            remoteDeviceID = remoteDeviceID,
            rootKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(sharedSecret),
            sendingRatchetPrivateKeyBase64 = localInitialRatchetKeyPair.privateKeyBase64,
            maxSkip = maxSkip,
        )
    }

    fun encrypt(plaintext: ByteArray, state: HermesRatchetSessionState, associatedData: ByteArray = ByteArray(0)): HermesRatchetEnvelope {
        val sendingChainKeyBase64 =
            state.sendingChainKeyBase64
                ?: throw HermesRatchetException(HermesRatchetError.MISSING_SENDING_CHAIN, "missing sending chain")
        val derived = chainKDF(symmetricKeyData(sendingChainKeyBase64, "sendingChainKey"))
        val privateKey = privateKeyFromBase64(state.sendingRatchetPrivateKeyBase64)
        val header =
            HermesRatchetHeader(
                sessionID = state.sessionID,
                senderDeviceID = state.localDeviceID,
                receiverDeviceID = state.remoteDeviceID,
                ratchetPublicKeyBase64 =
                HermesRelayCryptoSupport.base64NoWrap(
                    HermesRelayCryptoEc.publicKeyX963FromPrivateKey(privateKey),
                ),
                previousChainLength = state.previousSendingChainLength,
                messageNumber = state.sendMessageNumber,
                epoch = state.epoch,
            )
        val ciphertext = seal(plaintext, derived.messageKey, envelopeAAD(header, associatedData))
        state.sendingChainKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(derived.chainKey)
        state.sendMessageNumber += 1
        return HermesRatchetEnvelope(header, HermesRelayCryptoSupport.base64NoWrap(ciphertext))
    }

    fun decrypt(envelope: HermesRatchetEnvelope, state: HermesRatchetSessionState, associatedData: ByteArray = ByteArray(0)): ByteArray {
        validateHeader(envelope.header, state)
        val skippedKeyID = skippedKeyID(envelope.header.ratchetPublicKeyBase64, envelope.header.messageNumber)
        state.skippedMessageKeys.remove(skippedKeyID)?.let { keyBase64 ->
            return open(envelope, symmetricKeyData(keyBase64, "skippedMessageKey"), associatedData)
        }

        if (state.remoteRatchetPublicKeyBase64 != envelope.header.ratchetPublicKeyBase64) {
            state.remoteRatchetPublicKeyBase64?.let { remote ->
                skipMessageKeys(envelope.header.previousChainLength, remote, state)
            }
            dhRatchet(envelope.header.ratchetPublicKeyBase64, state)
        }

        skipMessageKeys(envelope.header.messageNumber, envelope.header.ratchetPublicKeyBase64, state)
        val receivingChainKeyBase64 =
            state.receivingChainKeyBase64
                ?: throw HermesRatchetException(HermesRatchetError.MISSING_RECEIVING_CHAIN, "missing receiving chain")
        val derived = chainKDF(symmetricKeyData(receivingChainKeyBase64, "receivingChainKey"))
        val plaintext = open(envelope, derived.messageKey, associatedData)
        state.receivingChainKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(derived.chainKey)
        state.receiveMessageNumber += 1
        return plaintext
    }

    internal fun envelopeAAD(header: HermesRatchetHeader, associatedData: ByteArray): ByteArray = ByteArrayOutputStream().apply {
        write(AAD_DOMAIN.toByteArray(Charsets.UTF_8))
        appendPart(associatedData)
        appendPart(header.algorithm.toByteArray(Charsets.UTF_8))
        appendPart(header.sessionID.toByteArray(Charsets.UTF_8))
        appendPart(header.senderDeviceID.toByteArray(Charsets.UTF_8))
        appendPart(header.receiverDeviceID.toByteArray(Charsets.UTF_8))
        appendPart(header.ratchetPublicKeyBase64.toByteArray(Charsets.UTF_8))
        appendUInt64(header.version)
        appendUInt64(header.previousChainLength)
        appendUInt64(header.messageNumber)
        appendUInt64(header.epoch)
    }.toByteArray()

    private fun dhRatchet(remoteRatchetPublicKeyBase64: String, state: HermesRatchetSessionState) {
        val currentPrivateKey = privateKeyFromBase64(state.sendingRatchetPrivateKeyBase64)
        val remotePublicKey = publicKeyFromBase64(remoteRatchetPublicKeyBase64)
        val rootKey = symmetricKeyData(state.rootKeyBase64, "rootKey")
        val receiveDerived = rootKDF(rootKey, HermesRelayCryptoEc.ecdh(currentPrivateKey, remotePublicKey))
        val nextPair = HermesRelayCryptoEc.generateEphemeralKeyPair()
        val sendDerived = rootKDF(receiveDerived.rootKey, HermesRelayCryptoEc.ecdh(nextPair.private, remotePublicKey))
        state.previousSendingChainLength = state.sendMessageNumber
        state.sendMessageNumber = 0
        state.receiveMessageNumber = 0
        state.epoch += 1
        state.remoteRatchetPublicKeyBase64 = remoteRatchetPublicKeyBase64
        state.rootKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(sendDerived.rootKey)
        state.receivingChainKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(receiveDerived.chainKey)
        state.sendingChainKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(sendDerived.chainKey)
        state.sendingRatchetPrivateKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(encodeRawPrivateKey(nextPair.private))
    }

    private fun skipMessageKeys(untilMessageNumber: Int, remoteRatchetPublicKeyBase64: String, state: HermesRatchetSessionState) {
        if (untilMessageNumber < state.receiveMessageNumber) return
        validateSkipWindow(untilMessageNumber, state)
        var receivingChainKey = receivingChainKeyForSkip(untilMessageNumber, state) ?: return
        while (state.receiveMessageNumber < untilMessageNumber) {
            val derived = chainKDF(receivingChainKey)
            val key = skippedKeyID(remoteRatchetPublicKeyBase64, state.receiveMessageNumber)
            validateSkippedKeyCapacity(state)
            state.skippedMessageKeys[key] = HermesRelayCryptoSupport.base64NoWrap(derived.messageKey)
            receivingChainKey = derived.chainKey
            state.receiveMessageNumber += 1
        }
        state.receivingChainKeyBase64 = HermesRelayCryptoSupport.base64NoWrap(receivingChainKey)
    }

    private fun validateSkipWindow(untilMessageNumber: Int, state: HermesRatchetSessionState) {
        if (untilMessageNumber - state.receiveMessageNumber > state.maxSkip) {
            throw HermesRatchetException(HermesRatchetError.TOO_MANY_SKIPPED_KEYS, "too many skipped keys")
        }
    }

    private fun receivingChainKeyForSkip(untilMessageNumber: Int, state: HermesRatchetSessionState): ByteArray? =
        state.receivingChainKeyBase64?.let { symmetricKeyData(it, "receivingChainKey") }
            ?: if (untilMessageNumber == state.receiveMessageNumber) null else missingReceivingChain()

    private fun missingReceivingChain(): Nothing = throw HermesRatchetException(HermesRatchetError.MISSING_RECEIVING_CHAIN, "missing receiving chain")

    private fun validateSkippedKeyCapacity(state: HermesRatchetSessionState) {
        if (state.skippedMessageKeys.size >= state.maxSkip) {
            throw HermesRatchetException(
                HermesRatchetError.SKIPPED_KEY_LIMIT_EXCEEDED,
                "skipped message key limit exceeded",
            )
        }
    }

    private fun open(envelope: HermesRatchetEnvelope, messageKey: ByteArray, associatedData: ByteArray): ByteArray {
        val combined =
            decodeBase64(envelope.ciphertextBase64, "ciphertext").also {
                if (it.size <= GCM_IV_BYTES) {
                    throw HermesRatchetException(HermesRatchetError.INVALID_ENVELOPE, "ciphertext too short")
                }
            }
        return try {
            val nonce = combined.copyOfRange(0, GCM_IV_BYTES)
            val body = combined.copyOfRange(GCM_IV_BYTES, combined.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(messageKey, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
            cipher.updateAAD(envelopeAAD(envelope.header, associatedData))
            cipher.doFinal(body)
        } catch (error: GeneralSecurityException) {
            throw HermesRatchetException(HermesRatchetError.AUTHENTICATION_FAILED, "ratchet authentication failed", error)
        }
    }

    private fun validateHeader(header: HermesRatchetHeader, state: HermesRatchetSessionState) {
        val valid =
            header.version == VERSION &&
                header.algorithm == ALGORITHM &&
                header.sessionID == state.sessionID &&
                header.receiverDeviceID == state.localDeviceID &&
                header.senderDeviceID == state.remoteDeviceID &&
                header.messageNumber >= 0 &&
                header.previousChainLength >= 0 &&
                header.epoch >= 0
        if (!valid) {
            throw HermesRatchetException(HermesRatchetError.INVALID_ENVELOPE, "invalid ratchet envelope header")
        }
        publicKeyFromBase64(header.ratchetPublicKeyBase64)
    }

    private fun rootKDF(rootKey: ByteArray, dhOutput: ByteArray): RootDerivation {
        val prk = HermesRelayCryptoHkdf.hkdfExtract(salt = rootKey, ikm = dhOutput)
        val output = HermesRelayCryptoHkdf.hkdfExpand(
            prk = prk,
            info = ROOT_INFO.toByteArray(Charsets.UTF_8),
            length = HKDF_ROOT_OUTPUT_BYTES,
        )
        return RootDerivation(output.copyOfRange(0, AES_KEY_BYTES), output.copyOfRange(AES_KEY_BYTES, output.size))
    }

    private fun chainKDF(chainKey: ByteArray): ChainDerivation {
        val next = hmacSha256(chainKey, CHAIN_LABEL.toByteArray(Charsets.UTF_8))
        val message = hmacSha256(chainKey, MESSAGE_LABEL.toByteArray(Charsets.UTF_8))
        return ChainDerivation(next, message)
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private fun seal(plaintext: ByteArray, keyData: ByteArray, aad: ByteArray): ByteArray {
        validateSymmetricKey(keyData, "messageKey")
        val nonce = ByteArray(GCM_IV_BYTES).also(secureRandom::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(keyData, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return nonce + cipher.doFinal(plaintext)
    }

    private fun privateKeyFromBase64(base64: String): java.security.PrivateKey = mapInvalidPrivateKey {
        decodeRawPrivateKey(decodedKeyBytes(base64, "privateKey", P256_PRIVATE_BYTES))
    }

    private fun publicKeyFromBase64(base64: String): java.security.PublicKey = mapInvalidPublicKey {
        HermesRelayCryptoEc.decodeUncompressedPublicKey(decodedKeyBytes(base64, "publicKey", P256_PUBLIC_BYTES))
    }

    private fun decodedKeyBytes(base64: String, label: String, expectedBytes: Int): ByteArray {
        val raw = decodeBase64(base64, label)
        if (raw.size != expectedBytes) {
            throw HermesRatchetException(HermesRatchetError.INVALID_KEY_LENGTH, "$label must be $expectedBytes bytes")
        }
        return raw
    }

    private inline fun <T> mapInvalidPrivateKey(block: () -> T): T = try {
        block()
    } catch (error: IllegalArgumentException) {
        invalidPrivateKey(error)
    } catch (error: GeneralSecurityException) {
        invalidPrivateKey(error)
    }

    private inline fun <T> mapInvalidPublicKey(block: () -> T): T = try {
        block()
    } catch (error: IllegalArgumentException) {
        invalidPublicKey(error)
    } catch (error: GeneralSecurityException) {
        invalidPublicKey(error)
    }

    private fun invalidPrivateKey(error: Throwable): Nothing =
        throw HermesRatchetException(HermesRatchetError.INVALID_PRIVATE_KEY, "invalid private key", error)

    private fun invalidPublicKey(error: Throwable): Nothing = throw HermesRatchetException(HermesRatchetError.INVALID_PUBLIC_KEY, "invalid public key", error)

    private fun encodeRawPrivateKey(privateKey: java.security.PrivateKey): ByteArray {
        val ecPrivate =
            privateKey as? java.security.interfaces.ECPrivateKey
                ?: error("Hermes ratchet keypair must use an EC private key")
        return HermesRelayCryptoHkdf.leftPadTo(ecPrivate.s.toByteArray(), P256_PRIVATE_BYTES)
    }

    private fun decodeRawPrivateKey(rawScalar: ByteArray): java.security.PrivateKey {
        require(rawScalar.size == P256_PRIVATE_BYTES) { "Expected 32-byte P-256 private scalar" }
        val params = p256ParameterSpec()
        val scalar = java.math.BigInteger(1, rawScalar)
        require(scalar.signum() > 0 && scalar < params.order) { "Invalid P-256 private scalar" }
        return KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(scalar, params))
    }

    private fun p256ParameterSpec(): ECParameterSpec {
        val parameters = AlgorithmParameters.getInstance("EC")
        parameters.init(ECGenParameterSpec(P256_CURVE_NAME))
        return parameters.getParameterSpec(ECParameterSpec::class.java)
    }

    private fun symmetricKeyData(base64: String, label: String): ByteArray = decodeBase64(base64, label).also { validateSymmetricKey(it, label) }

    private fun validateSymmetricKey(data: ByteArray, label: String) {
        if (data.size != AES_KEY_BYTES) {
            throw HermesRatchetException(HermesRatchetError.INVALID_KEY_LENGTH, "$label must be 32 bytes")
        }
    }

    private fun decodeBase64(base64: String, label: String): ByteArray = try {
        HermesRelayCryptoSupport.base64Decode(base64)
    } catch (error: IllegalArgumentException) {
        throw HermesRatchetException(HermesRatchetError.INVALID_BASE64, "invalid base64: $label", error)
    }

    private fun skippedKeyID(ratchetPublicKeyBase64: String, messageNumber: Int): String = "$ratchetPublicKeyBase64:$messageNumber"

    private fun ByteArrayOutputStream.appendPart(part: ByteArray) {
        appendUInt64(part.size)
        write(part)
    }

    private fun ByteArrayOutputStream.appendUInt64(value: Int) {
        require(value >= 0) { "UInt64 ratchet field cannot be negative" }
        val longValue = value.toLong()
        for (shift in 56 downTo 0 step 8) {
            write((longValue ushr shift and BYTE_MASK).toInt())
        }
    }

    private data class RootDerivation(val rootKey: ByteArray, val chainKey: ByteArray)

    private data class ChainDerivation(val chainKey: ByteArray, val messageKey: ByteArray)
}
