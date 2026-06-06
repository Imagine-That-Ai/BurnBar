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
    fun signalEnvelopeMapIfEnabled(
        domainID: String,
        uid: String,
        collection: String,
        docId: String,
        field: String = "signalEnvelope",
        plaintext: ByteArray,
        localIdentity: AndroidSignalIdentityKeypair,
        otherRecipients: List<CloudVaultSignalRecipient>,
    ): Map<String, Any>? {
        if (!signalSealingIsEnabled(domainID)) return null
        val binding = CloudVaultSignalBinding(uid = uid, collection = collection, docId = docId, field = field)
        val recipients = dedupeRecipients(localIdentity.asRecipient(), otherRecipients)
        val envelope = CloudVaultCrypto.sealSignalPayload(plaintext, recipients, binding)
        return CloudVaultCrypto.signalEnvelopeMap(envelope)
    }

    /**
     * Signal-first open with a relocation guard. Returns null when `field` is absent (so
     * the caller falls through to the legacy AES-GCM opener). Throws if an envelope is
     * present but invalid, relocated (binding mismatch), or the local identity is missing.
     */
    fun openSignalPayloadIfPresent(
        data: Map<String, Any?>,
        uid: String,
        collection: String,
        docId: String,
        field: String = "signalEnvelope",
        bindingField: String? = null,
        localIdentity: AndroidSignalIdentityKeypair?,
    ): ByteArray? {
        val raw = data[field] as? Map<*, *> ?: return null
        val envelope =
            CloudVaultCrypto.signalEnvelopeFromMap(raw)
                ?: throw IllegalStateException("Signal envelope is invalid.")
        val expected =
            CloudVaultSignalBinding(uid = uid, collection = collection, docId = docId, field = bindingField ?: field)
        require(envelope.binding == expected) { "Signal envelope binding does not match the Firestore path." }
        val identity = localIdentity ?: throw IllegalStateException("Signal identity is unavailable.")
        return CloudVaultCrypto.openSignalPayload(
            envelope,
            recipientIdentityKeyId = identity.identityKeyId,
            recipientIdentityPrivateKey = identity.privateKeyData,
            expectedBinding = expected,
        )
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
            val deviceId = deviceDoc.getString("deviceId")?.trim().takeUnless { it.isNullOrEmpty() } ?: deviceDoc.id
            // Fail-CLOSED (iOS parity, MobileCloudVaultSignalPayloads.swift:125-130): a trusted
            // device with no keyVersion must abort the whole seal, NOT be silently dropped — a
            // silently-excluded device could never open the resulting envelope. All throws here
            // use IllegalStateException so producer catch blocks treat them uniformly.
            val keyVersion =
                (deviceDoc.getLong("keyVersion")
                    ?: throw IllegalStateException("Trusted device $deviceId has no keyVersion; cannot resolve its Signal identity.")).toInt()
            val identityKeyId = AndroidSignalIdentityKeypair.identityKeyId(deviceId, keyVersion)
            if (identityKeyId == localIdentity.identityKeyId) continue
            val identityDoc =
                userRef.collection("signal_identity_public_keys").document(identityKeyId).get().await()
            check(identityDoc.exists()) { "Trusted device $identityKeyId has no Signal identity public key." }
            val publicKeyB64 = identityDoc.getString("publicKeyData")
            check(
                identityDoc.getString("deviceId") == deviceId &&
                    identityDoc.getString("identityKeyId") == identityKeyId &&
                    identityDoc.getLong("keyVersion")?.toInt() == keyVersion &&
                    identityDoc.getString("algorithm") == CloudVaultCrypto.SIGNAL_AT_REST_ENCRYPTION &&
                    publicKeyB64 != null,
            ) { "Trusted device $identityKeyId has an invalid Signal identity public key." }
            byId[identityKeyId] =
                CloudVaultSignalRecipient(
                    recipientKind = "device",
                    recipientIdentityKeyId = identityKeyId,
                    publicKeyData = CloudVaultCryptoSupport.decodeBase64(requireNotNull(publicKeyB64)),
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
