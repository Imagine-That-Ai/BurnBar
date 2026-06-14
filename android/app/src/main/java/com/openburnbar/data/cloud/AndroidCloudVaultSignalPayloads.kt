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
     * Explicit per-user enrollment state of the trusted-sender set. Replaces the previous
     * `trustedSenderPublicKeys.size > 1` readiness heuristic (T-AND-04 / T-CVS-02): a size-based
     * guess could not tell "every trusted device has enrolled its Signal identity" apart from "a
     * single peer happened to resolve" or "a transient Firestore read returned a short set", which
     * on a transient failure left an unknown sender legacy-eligible (a downgrade window). This
     * marker is computed deterministically from the escrow-device read and fails CLOSED when the
     * read does not succeed.
     */
    enum class SenderSetEnrollment {
        /** The escrow-device read succeeded and EVERY trusted peer device has published a Signal
         *  identity that resolved into the set — the set is authoritative, so an unknown sender is
         *  an attack and must fail closed. */
        COMPLETE,

        /** The read succeeded but at least one trusted peer device has not yet published its Signal
         *  identity — a legitimate rollout gap, so an unknown sender stays legacy-eligible. */
        INCOMPLETE,

        /** The escrow-device read failed / was transient — we cannot prove the set is complete OR
         *  trust it as incomplete, so callers FAIL CLOSED (treat as complete) rather than open a
         *  downgrade window on a flaky read. */
        UNAVAILABLE,
    }

    /**
     * Resolved trusted-sender set plus its explicit [enrollment] marker. [senderSetComplete] is the
     * fail-closed signal passed to [SignalAtRestFallbackPolicy.allowsLegacyAtRestFallback]: `true`
     * for both COMPLETE (authoritative) and UNAVAILABLE (flaky read → fail closed), `false` only for
     * a genuine INCOMPLETE rollout gap.
     */
    data class TrustedSenderSet(
        val publicKeys: Map<String, ByteArray>,
        val enrollment: SenderSetEnrollment,
    ) {
        val senderSetComplete: Boolean
            get() = enrollment != SenderSetEnrollment.INCOMPLETE
    }

    /**
     * Best-effort PINNED trusted-sender public keys for READ-time sender-auth verification:
     * local identity + every trusted escrow device's published identity. Mirrors iOS
     * `MobileCloudVaultSignalPayloads.trustedSenderPublicKeys`. Retained for the seal path and any
     * caller that only needs the key map; the READER path uses [resolveTrustedSenderSet] so it also
     * gets the explicit, fail-closed [SenderSetEnrollment] marker instead of a size heuristic.
     */
    suspend fun trustedSenderPublicKeys(
        uid: String,
        firestore: FirebaseFirestore,
        localIdentity: AndroidSignalIdentityKeypair,
    ): Map<String, ByteArray> = resolveTrustedSenderSet(uid, firestore, localIdentity).publicKeys

    /**
     * Resolve the trusted-sender key map AND an explicit per-user [SenderSetEnrollment] marker.
     *
     * The local identity is always pinned. Then the trusted escrow devices are read; for each, its
     * published Signal identity is resolved. The marker is:
     *   * UNAVAILABLE — the escrow-device LIST read threw (transient/offline). Fail closed.
     *   * INCOMPLETE — the list read succeeded but at least one trusted peer device could not be
     *     resolved into a pinned identity (it has not published yet). Rollout gap → legacy-eligible.
     *   * COMPLETE — the list read succeeded and every trusted peer device resolved. Authoritative.
     *
     * Crucially, a transient failure NO LONGER masquerades as a complete-but-small set (the old
     * `size > 1` path treated any short result as not-complete → legacy-eligible); it now fails
     * closed.
     */
    suspend fun resolveTrustedSenderSet(
        uid: String,
        firestore: FirebaseFirestore,
        localIdentity: AndroidSignalIdentityKeypair,
    ): TrustedSenderSet {
        val map = LinkedHashMap<String, ByteArray>()
        map[localIdentity.identityKeyId] = localIdentity.publicKeyData

        // Read the trusted escrow-device LIST first. A failure here is transient/offline — we cannot
        // enumerate the peers at all, so completeness is unprovable ⇒ fail closed (UNAVAILABLE).
        val trustedDevices =
            runCatching {
                firestore.collection("users").document(uid)
                    .collection("escrow_devices").whereEqualTo("trustState", "trusted").get().await()
            }.getOrElse { return TrustedSenderSet(map.toMap(), SenderSetEnrollment.UNAVAILABLE) }

        // Resolve each trusted peer device's PINNED Signal identity individually. A device that
        // cannot be resolved (no/invalid published identity yet) is a genuine rollout gap, NOT a
        // transient failure, so it marks the set INCOMPLETE (legacy-eligible) without failing closed.
        var allPeersResolved = true
        for (deviceDoc in trustedDevices.documents) {
            val verified =
                runCatching {
                    AndroidCloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevice(
                        uid = uid,
                        firestore = firestore,
                        deviceDocument = deviceDoc,
                        localIdentity = localIdentity,
                    )
                }.getOrElse {
                    allPeersResolved = false
                    null
                } ?: continue
            if (verified.signalIdentityKeyId == localIdentity.identityKeyId) continue
            map[verified.signalIdentityKeyId] = verified.signalIdentityPublicKeyData
        }

        val enrollment = if (allPeersResolved) SenderSetEnrollment.COMPLETE else SenderSetEnrollment.INCOMPLETE
        return TrustedSenderSet(map.toMap(), enrollment)
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
