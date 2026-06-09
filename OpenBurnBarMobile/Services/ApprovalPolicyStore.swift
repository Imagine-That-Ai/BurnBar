@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import Foundation
import Observation
import OpenBurnBarCore

// MARK: - Approval Policy Store (Hermes Square §6.9)
//
// Owns the user's list of `ApprovalPolicy` rules. Persists locally to
// UserDefaults (for cold start) **and** mirrors to Firestore at
// `users/{uid}/approval_policies/{class}` so policies sync across devices
// — the WeChat "yes always" pattern needs cross-device durability, not
// device-local memory.
//
// Local store is the authoritative read path. Cloud writes are best-effort;
// failures don't block the user's decision. On cold start we hydrate
// local from cloud once auth resolves.

@MainActor
@Observable
final class ApprovalPolicyStore {
    static let shared = ApprovalPolicyStore()

    private(set) var policies: [ApprovalPolicy] = []
    private(set) var lastCloudError: String?

    private static let userDefaultsKey = "square.approvalPolicies.v1"
    private let firestoreProvider: () -> Firestore
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var cloudListener: ListenerRegistration?

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
        self.policies = Self.load()
        attachAuthListener()
    }

    deinit {
        // Read both main-actor-isolated properties in a single hop, then
        // call into Firebase from this nonisolated context (Firebase removes
        // listeners thread-safely).
        let snapshot: (handle: AuthStateDidChangeListenerHandle?, listener: ListenerRegistration?) =
            MainActor.assumeIsolated {
                (authHandle, cloudListener)
            }
        snapshot.listener?.remove()
        if let handle = snapshot.handle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    // MARK: Public API

    /// Add a new policy. Replaces any existing policy with the same class
    /// hash (`id`). Persists locally + best-effort to Firestore.
    func record(_ policy: ApprovalPolicy) {
        if let idx = policies.firstIndex(where: { $0.id == policy.id }) {
            policies[idx] = policy
        } else {
            policies.append(policy)
        }
        save()
        Task { await cloudUpsert(policy) }
    }

    func remove(id: String) {
        policies.removeAll { $0.id == id }
        save()
        Task { await cloudDelete(id: id) }
    }

    /// Find a policy that matches `ask`. Bumps the matched policy's
    /// `matchCount` on hit.
    @discardableResult
    func resolve(_ ask: ApprovalAskClassifier) -> ApprovalPolicy? {
        guard let policy = ask.resolve(against: policies) else { return nil }
        if let idx = policies.firstIndex(where: { $0.id == policy.id }) {
            var bumped = policies[idx]
            bumped.matchCount += 1
            policies[idx] = bumped
            save()
            Task { await cloudUpsert(bumped) }
        }
        return policy
    }

    // MARK: Local persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(policies) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    private static func load() -> [ApprovalPolicy] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ApprovalPolicy].self, from: data)) ?? []
    }

    // MARK: Cloud mirror

    private func attachAuthListener() {
        guard FirebaseApp.app() != nil else { return }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.restartCloudListener(uid: user?.uid)
            }
        }
        restartCloudListener(uid: Auth.auth().currentUser?.uid)
    }

    private func restartCloudListener(uid: String?) {
        cloudListener?.remove()
        cloudListener = nil
        guard let uid else { return }
        cloudListener = firestoreProvider()
            .collection("users").document(uid)
            .collection("approval_policies")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.lastCloudError = error.localizedDescription
                        return
                    }
                    // Synchronous local-keychain read of the vault key for the
                    // snapshot callback (which cannot await). `nil` when the key
                    // isn't escrowed onto this device yet — sealed fields then
                    // stay hidden (decode returns `nil` for them, no leak).
                    let vaultKey = self.cachedVaultKey(uid: uid)
                    let docs = snapshot?.documents ?? []
                    let cloudPolicies = docs.compactMap { doc in
                        Self.decode(documentID: doc.documentID, data: doc.data(), vaultKey: vaultKey, uid: uid)
                    }
                    self.mergeCloudPolicies(cloudPolicies)
                }
            }
    }

    private func mergeCloudPolicies(_ cloud: [ApprovalPolicy]) {
        // Union-merge by `id` (the in-memory class hash, recomputed by the
        // `ApprovalPolicy` initializer from the decoded discriminators — the
        // cloud document no longer carries a plaintext `id`). Race-safe: if the
        // user creates a local policy in the brief window before the first cloud
        // snapshot lands, we preserve it AND queue an upload so it reaches
        // Firestore the next tick. For overlapping IDs, we take the cloud row but
        // keep the **higher** matchCount — the local instance may have
        // auto-resolved asks the cloud copy hasn't seen yet.
        let cloudByID = Dictionary(uniqueKeysWithValues: cloud.map { ($0.id, $0) })
        let localByID = Dictionary(uniqueKeysWithValues: policies.map { ($0.id, $0) })
        let allIDs = Set(cloudByID.keys).union(localByID.keys)

        var merged: [ApprovalPolicy] = []
        var localOnlyForUpload: [ApprovalPolicy] = []

        for id in allIDs {
            switch (cloudByID[id], localByID[id]) {
            case let (cloudPolicy?, localPolicy?):
                // Both sides have it. Cloud row wins for the descriptive
                // fields (so remote edits propagate), but matchCount unions
                // (max) so we don't lose local resolution counters.
                var merged_ = cloudPolicy
                if localPolicy.matchCount > merged_.matchCount {
                    merged_ = ApprovalPolicy(
                        missionKind: cloudPolicy.missionKind,
                        toolName: cloudPolicy.toolName,
                        fileGlob: cloudPolicy.fileGlob,
                        runtimeID: cloudPolicy.runtimeID,
                        targetProject: cloudPolicy.targetProject,
                        decision: cloudPolicy.decision,
                        displayLabel: cloudPolicy.displayLabel,
                        createdAt: cloudPolicy.createdAt,
                        expiresAt: cloudPolicy.expiresAt,
                        matchCount: localPolicy.matchCount
                    )
                }
                merged.append(merged_)
            case let (cloudPolicy?, nil):
                merged.append(cloudPolicy)
            case let (nil, localPolicy?):
                // Local-only — the user recorded it before the cloud
                // listener fired. Keep AND schedule an upload.
                merged.append(localPolicy)
                localOnlyForUpload.append(localPolicy)
            case (nil, nil):
                continue
            }
        }

        policies = merged.sorted { $0.createdAt > $1.createdAt }
        save()
        for stranded in localOnlyForUpload {
            Task { await cloudUpsert(stranded) }
        }
    }

    private func cloudUpsert(_ policy: ApprovalPolicy) async {
        guard FirebaseApp.app() != nil, let uid = Auth.auth().currentUser?.uid else { return }
        let vaultKey: Data
        do {
            vaultKey = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid).keyData
        } catch {
            lastCloudError = error.localizedDescription
            return
        }
        let payload: [String: Any]
        let docID: String
        do {
            docID = try Self.opaqueCloudDocumentID(forClassHash: policy.id, vaultKey: vaultKey)
            payload = try Self.encode(policy, uid: uid, documentID: docID, vaultKey: vaultKey)
        } catch {
            lastCloudError = error.localizedDescription
            return
        }
        let collection = firestoreProvider()
            .collection("users").document(uid)
            .collection("approval_policies")
        do {
            try await collection.document(docID).setData(payload, merge: false)
            // Client-side migration: drop any legacy doc keyed by the cleartext
            // class hash (which baked `glob=`/`project=` into the document name).
            let legacyDocID = Self.legacyCleartextDocumentID(policy.id)
            if legacyDocID != docID {
                try? await collection.document(legacyDocID).delete()
            }
        } catch {
            lastCloudError = error.localizedDescription
        }
    }

    private func cloudDelete(id: String) async {
        guard FirebaseApp.app() != nil, let uid = Auth.auth().currentUser?.uid else { return }
        let vaultKey = try? await MobileCloudVaultKeyAccess.keyForReading(uid: uid)?.keyData
        let collection = firestoreProvider()
            .collection("users").document(uid)
            .collection("approval_policies")
        do {
            // Delete the opaque keyed doc (current scheme) when the key is
            // available, plus the legacy cleartext-ID doc for pre-migration peers.
            if let vaultKey,
               let docID = try? Self.opaqueCloudDocumentID(forClassHash: id, vaultKey: vaultKey) {
                try await collection.document(docID).delete()
            }
            let legacyDocID = Self.legacyCleartextDocumentID(id)
            try await collection.document(legacyDocID).delete()
        } catch {
            lastCloudError = error.localizedDescription
        }
    }

    /// Legacy Firestore document ID derived directly from the cleartext class
    /// hash. Retained only so the migration path can delete pre-seal documents;
    /// new writes use `opaqueCloudDocumentID`.
    static func legacyCleartextDocumentID(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    /// Synchronous local-keychain read of the Cloud Vault key for use inside the
    /// snapshot-listener callback (which cannot await). Returns `nil` if the key
    /// is not present locally yet; callers then fall back to any legacy plaintext
    /// field. Mirrors `BudgetRulesStore.cachedVaultKey()`.
    private func cachedVaultKey(uid: String) -> Data? {
        try? CloudVaultKeyStore().loadKey(uid: uid)
    }

    /// Opaque, deterministic Firestore document ID for a policy. Replaces the
    /// cleartext class hash (which leaked `glob=<fileGlob>` / `project=<targetProject>`
    /// in the document name itself) with a keyed HMAC trapdoor so the server and
    /// any raw Firestore reader learn nothing about the policy class.
    ///
    /// Reuses the existing `CloudVaultCrypto.tokenHashes` search trapdoor. The
    /// class hash is first collapsed to a single canonical alphanumeric term
    /// (mirroring `CloudVaultCrypto.projectKeyHash`) so the multi-token splitter
    /// can't reduce it to the hash of just the first token — `tokenHashes(...).first`
    /// then HMACs the whole class identity to a stable 32-hex bucket. Same class
    /// + same vault key always yield the same ID (upsert idempotency); a different
    /// vault key yields a different ID. No new crypto is introduced.
    static func opaqueCloudDocumentID(forClassHash classHash: String, vaultKey: Data) throws -> String {
        let term = CloudVaultCrypto.normalizedTokens(from: classHash).joined()
        guard term.isEmpty == false,
              let hash = try CloudVaultCrypto.tokenHashes(for: term, keyData: vaultKey, limit: 1).first else {
            throw CloudVaultProjectSealError.encodingFailed
        }
        return "ap_" + hash
    }

    // MARK: Codec

    /// Encodes a policy into a Firestore dictionary with the private fields
    /// sealed. `displayLabel`, `targetProject`, and `fileGlob` are written as
    /// `CloudVaultSealedText` envelopes (`sealedDisplayLabel` / `sealedTargetProject`
    /// / `sealedFileGlob`); their plaintext counterparts are dropped entirely. The
    /// top-level `id` (the cleartext class hash) is also dropped — it lived only
    /// to name the document, which is now the opaque keyed hash. Opaque match
    /// trapdoors `projectKeyHash` / `fileGlobHash` let the client bucket policies
    /// without decrypting; the server never reads any of them.
    static func encode(_ policy: ApprovalPolicy, uid: String, documentID: String, vaultKey: Data) throws -> [String: Any] {
        func seal(_ value: String, field: String) throws -> [String: Any] {
            try CloudVaultCrypto.dictionary(CloudVaultCrypto.sealText(
                value,
                keyData: vaultKey,
                aadContext: CloudVaultAADContext(
                    uid: uid,
                    collection: "approval_policies",
                    docID: documentID,
                    field: field
                )
            ))
        }
        var dict: [String: Any] = [
            "decision": policy.decision.rawValue,
            "createdAt": ISO8601DateFormatter().string(from: policy.createdAt),
            "matchCount": policy.matchCount,
            "schemaVersion": 2,
            "sealedDisplayLabel": try seal(policy.displayLabel, field: "sealedDisplayLabel")
        ]
        if let v = policy.missionKind { dict["missionKind"] = v }
        if let v = policy.toolName { dict["toolName"] = v }
        if let v = policy.runtimeID { dict["runtimeID"] = v }
        if let v = policy.fileGlob {
            dict["sealedFileGlob"] = try seal(v, field: "sealedFileGlob")
            if let fileGlobHash = CloudVaultCrypto.projectKeyHash(for: v, keyData: vaultKey) {
                dict["fileGlobHash"] = fileGlobHash
            }
        }
        if let v = policy.targetProject {
            dict["sealedTargetProject"] = try seal(v, field: "sealedTargetProject")
            if let projectKeyHash = CloudVaultCrypto.projectKeyHash(for: v, keyData: vaultKey) {
                dict["projectKeyHash"] = projectKeyHash
            }
        }
        if let v = policy.expiresAt {
            dict["expiresAt"] = ISO8601DateFormatter().string(from: v)
        }
        return dict
    }

    /// Decodes a policy from a Firestore document. Opens the sealed private
    /// fields with `openSealedProjectName` (which keeps a LEGACY plaintext
    /// fallback so pre-migration documents still render, and returns `nil` —
    /// never the legacy value — when a field is sealed but the vault key is
    /// absent on this device). The `id` is recomputed by the `ApprovalPolicy`
    /// initializer from the decoded discriminators, so the in-memory class hash
    /// used for matching is unchanged even though the cloud no longer stores it.
    static func decode(documentID: String, data: [String: Any], vaultKey: Data?, uid: String? = nil) -> ApprovalPolicy? {
        guard
            let label = openSealedPolicyField(
                from: data,
                documentID: documentID,
                sealedField: "sealedDisplayLabel",
                legacyField: "displayLabel",
                keyData: vaultKey,
                uid: uid
            ),
            let decisionRaw = data["decision"] as? String,
            let decision = ApprovalPolicy.Decision(rawValue: decisionRaw)
        else { return nil }
        let fileGlob = openSealedPolicyField(
            from: data,
            documentID: documentID,
            sealedField: "sealedFileGlob",
            legacyField: "fileGlob",
            keyData: vaultKey,
            uid: uid
        )
        let targetProject = openSealedPolicyField(
            from: data,
            documentID: documentID,
            sealedField: "sealedTargetProject",
            legacyField: "targetProject",
            keyData: vaultKey,
            uid: uid
        )
        let createdAt = (data["createdAt"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let expiresAt = (data["expiresAt"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        return ApprovalPolicy(
            missionKind: data["missionKind"] as? String,
            toolName: data["toolName"] as? String,
            fileGlob: fileGlob,
            runtimeID: data["runtimeID"] as? String,
            targetProject: targetProject,
            decision: decision,
            displayLabel: label,
            createdAt: createdAt,
            expiresAt: expiresAt,
            matchCount: (data["matchCount"] as? Int) ?? 0
        )
    }

    private static func openSealedPolicyField(
        from data: [String: Any],
        documentID: String,
        sealedField: String,
        legacyField: String,
        keyData: Data?,
        uid: String?
    ) -> String? {
        if let envelope = CloudVaultCrypto.decodeSealedText(from: data[sealedField]) {
            guard let keyData else { return nil }
            if let uid = uid ?? data["uid"] as? String {
                if let context = try? CloudVaultAADContext(
                    uid: uid,
                    collection: "approval_policies",
                    docID: documentID,
                    field: sealedField
                ),
                   let plaintext = try? CloudVaultCrypto.openText(envelope, keyData: keyData, aadContext: context) {
                    return plaintext
                }
            }
            if (envelope.schemaVersion ?? 1) < 2,
               let plaintext = try? CloudVaultCrypto.openText(envelope, keyData: keyData) {
                return plaintext
            }
            return nil
        }
        return data[legacyField] as? String
    }
}
