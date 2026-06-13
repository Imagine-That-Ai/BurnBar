package com.openburnbar.data.cloud

import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.data.domains.DataDomains
import kotlinx.coroutines.tasks.await

/**
 * Android counterpart of iOS `MobileCloudVaultSignalPayloads.swift` — produces and
 * opens at-rest Signal `signalEnvelope` payloads for the assistant-chat and CLI-mission
 * write paths.
 *
 * Activation gate: a domain seals with Signal only when its data-domain `sealingScheme`
 * (from the generated DataDomains, sourced from packages/data-domains/registry.json)
 * equals `CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION` ("signal-hpke-identity-seal-v1").
 * The registry is the single source of truth — do NOT assume a hardcoded on/off state
 * here; whether any domain carries the scheme is whatever registry.json declares. When a
 * domain is NOT on the Signal scheme the gate is fail-closed (no envelopes emitted).
 * `signalSealingOverrideProvider` is a TEST-ONLY hook (mirrors the iOS pattern) so the
 * producer path can be exercised under test without changing production behavior.
 *
 * Recipient resolution from Firestore (`atRestRecipients`) is added alongside the
 * producer call-sites (AssistantChatHistoryStore / CLIAgentMissionDispatcher); the
 * pure seal/open below take recipients explicitly so they unit-test without Firestore.
 */
object AndroidCloudVaultSignalPayloads {
    data class SignalEnvelopeMapRequest(
        val domainID: String,
        val uid: String,
        val collection: String,
        val docId: String,
        val field: String = "signalEnvelope",
        val plaintext: ByteArray,
        val localIdentity: AndroidSignalIdentityKeypair,
        val otherRecipients: List<CloudVaultSignalRecipient>,
    )

    /** Test-only deterministic gate override (domainID -> enabled?, null = no override). */
    internal var signalSealingOverrideProvider: ((String) -> Boolean?)? = null

    /**
     * Kill switch (P1-5): the per-domain RUNTIME activation flag, AND-ed with the registry
     * scheme. Defaults to OFF (fail-closed), so a deployed-but-unramped registry flip is
     * inert on Android. Production wires this to Firebase Remote Config
     * (`signal_at_rest_<domainID>_enabled`) from BurnBarApplication once the firebase-config
     * dependency is added — a one-line provider assignment — mirroring how iOS/Mac read RC
     * directly. Kept as an injected provider so the crypto layer has no Firebase coupling and
     * the AND is unit-testable. Returns false until wired => Android stays fail-closed.
     */
    internal var signalAtRestActivationProvider: ((String) -> Boolean)? = null

    fun signalSealingIsEnabled(domainID: String): Boolean {
        signalSealingOverrideProvider?.invoke(domainID)?.let { return it }
        if (DataDomains.domain(domainID)?.sealingScheme != CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION) return false
        return signalAtRestActivationProvider?.invoke(domainID) ?: false
    }

    /**
     * Seal `plaintext` into an at-rest Signal envelope map for `field`, wrapped to the
     * local identity plus `otherRecipients` (every trusted device). Returns null when
     * the domain's Signal gate is OFF (caller keeps the legacy AES-GCM sealed payload).
     */
    fun signalEnvelopeMapIfEnabled(request: SignalEnvelopeMapRequest): Map<String, Any>? {
        if (!signalSealingIsEnabled(request.domainID)) return null
        val binding = CloudVaultSignalBinding(
            uid = request.uid,
            collection = request.collection,
            docId = request.docId,
            field = request.field,
        )
        val recipients = dedupeRecipients(request.localIdentity.asRecipient(), request.otherRecipients)
        // Sender authentication: sign with THIS device's identity private key (mirrors iOS
        // MobileCloudVaultSignalPayloads). A malicious server holds only public keys and cannot forge it.
        val envelope =
            CloudVaultCrypto.sealSignalPayload(
                request.plaintext,
                recipients,
                binding,
                senderIdentityKeyId = request.localIdentity.identityKeyId,
                senderIdentityPrivateKey = request.localIdentity.privateKeyData,
                senderIdentityPublicKey = request.localIdentity.publicKeyData,
            )
        return CloudVaultCrypto.signalEnvelopeMap(envelope)
    }

    /**
     * Signal-first open with a relocation guard and fail-closed sender-auth. Returns null when
     * `field` is absent (so the caller falls through to the legacy AES-GCM opener). Throws if an
     * envelope is present but invalid, relocated (binding mismatch), or the local identity is
     * missing — and a [CloudVaultSignalSenderAuthException] when the sender block is
     * stripped/forged/untrusted, which the caller routes through
     * [SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback] before any legacy decode.
     *
     * `trustedSenderPublicKeys` are PINNED identity public keys (identityKeyId -> public key bytes)
     * used to verify the sender signature. The local identity is always added, so a self-authored
     * doc is fully verified with no extra I/O; pass [trustedSenderPublicKeys] from Firestore for
     * cross-device reads via [trustedSenderPublicKeys].
     */
    fun openSignalPayloadIfPresent(
        data: Map<String, Any?>,
        uid: String,
        collection: String,
        docId: String,
        field: String = "signalEnvelope",
        bindingField: String? = null,
        localIdentity: AndroidSignalIdentityKeypair?,
        trustedSenderPublicKeys: Map<String, ByteArray> = emptyMap(),
    ): ByteArray? {
        val raw = data[field] as? Map<*, *> ?: return null
        val envelope =
            CloudVaultCrypto.signalEnvelopeFromMap(raw)
                ?: error("Signal envelope is invalid.")
        val expected =
            CloudVaultSignalBinding(uid = uid, collection = collection, docId = docId, field = bindingField ?: field)
        require(envelope.binding == expected) { "Signal envelope binding does not match the Firestore path." }
        val identity = localIdentity ?: error("Signal identity is unavailable.")
        val trustedSenders = LinkedHashMap(trustedSenderPublicKeys)
        trustedSenders[identity.identityKeyId] = identity.publicKeyData
        return CloudVaultCrypto.openSignalPayload(
            envelope,
            recipientIdentityKeyId = identity.identityKeyId,
            recipientIdentityPrivateKey = identity.privateKeyData,
            expectedBinding = expected,
            trustedSenderPublicKeys = trustedSenders,
        )
    }

    /**
     * Best-effort PINNED trusted-sender public keys for READ-time sender-auth verification:
     * local identity + every trusted escrow device's published identity. Mirrors iOS
     * `MobileCloudVaultSignalPayloads.trustedSenderPublicKeys`. Never blocks a read — if the full
     * set cannot resolve it returns just the local identity, so cross-device envelopes from
     * unresolved senders fall back to the legacy payload (a readiness gap, classified by
     * [SignalAtRestFallbackPolicy] with `senderSetComplete = false`). After the readiness gate (all
     * trusted devices published) this returns the full set, activating cross-device sender-auth.
     */
    suspend fun trustedSenderPublicKeys(
        uid: String,
        firestore: FirebaseFirestore,
        localIdentity: AndroidSignalIdentityKeypair,
    ): Map<String, ByteArray> {
        val map = LinkedHashMap<String, ByteArray>()
        map[localIdentity.identityKeyId] = localIdentity.publicKeyData
        runCatching { atRestRecipients(uid = uid, firestore = firestore, localIdentity = localIdentity) }
            .getOrNull()
            ?.forEach { recipient -> map[recipient.recipientIdentityKeyId] = recipient.publicKeyData }
        return map
    }

    /**
     * Resolve the OTHER at-rest recipients (every trusted escrow device's published Signal
     * identity, excluding the local one which the sealer adds). Mirrors iOS
     * `MobileCloudVaultSignalPayloads.atRestRecipients`: throws if a trusted device has no
     * (or an invalid) published Signal identity, so a write never silently excludes a device
     * that should be able to read it. Activation must ensure every trusted device has
     * published its Signal identity before the domain gate is flipped on.
     */
    suspend fun atRestRecipients(
        uid: String,
        firestore: FirebaseFirestore,
        localIdentity: AndroidSignalIdentityKeypair,
    ): List<CloudVaultSignalRecipient> {
        val userRef = firestore.collection("users").document(uid)
        val trusted = userRef.collection("escrow_devices").whereEqualTo("trustState", "trusted").get().await()
        val byId = LinkedHashMap<String, CloudVaultSignalRecipient>()
        for (deviceDoc in trusted.documents) {
            val verified =
                AndroidCloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevice(
                    uid = uid,
                    firestore = firestore,
                    deviceDocument = deviceDoc,
                    localIdentity = localIdentity,
                )
            if (verified.signalIdentityKeyId == localIdentity.identityKeyId) continue
            byId[verified.signalIdentityKeyId] =
                CloudVaultSignalRecipient(
                    recipientKind = "device",
                    recipientIdentityKeyId = verified.signalIdentityKeyId,
                    publicKeyData = verified.signalIdentityPublicKeyData,
                )
        }
        return byId.values.sortedBy { it.recipientIdentityKeyId }
    }

    /** Local identity first, then every distinct other recipient, sorted by identityKeyId. */
    private fun dedupeRecipients(
        local: CloudVaultSignalRecipient,
        others: List<CloudVaultSignalRecipient>,
    ): List<CloudVaultSignalRecipient> {
        val byId = LinkedHashMap<String, CloudVaultSignalRecipient>()
        byId[local.recipientIdentityKeyId] = local
        for (recipient in others) byId.putIfAbsent(recipient.recipientIdentityKeyId, recipient)
        return byId.values.sortedBy { it.recipientIdentityKeyId }
    }
}
