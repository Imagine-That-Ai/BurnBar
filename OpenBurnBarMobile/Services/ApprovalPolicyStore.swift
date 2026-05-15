import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
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
                    let docs = snapshot?.documents ?? []
                    let cloudPolicies = docs.compactMap { doc in
                        Self.decode(documentID: doc.documentID, data: doc.data())
                    }
                    self.mergeCloudPolicies(cloudPolicies)
                }
            }
    }

    private func mergeCloudPolicies(_ cloud: [ApprovalPolicy]) {
        // Union-merge by `id` (class hash). Race-safe: if the user creates a
        // local policy in the brief window before the first cloud snapshot
        // lands, we preserve it AND queue an upload so it reaches Firestore
        // the next tick. For overlapping IDs, we take the cloud row but keep
        // the **higher** matchCount — the local instance may have auto-resolved
        // asks the cloud copy hasn't seen yet.
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
        let payload = Self.encode(policy)
        do {
            try await firestoreProvider()
                .collection("users").document(uid)
                .collection("approval_policies").document(safeDocumentID(policy.id))
                .setData(payload, merge: false)
        } catch {
            lastCloudError = error.localizedDescription
        }
    }

    private func cloudDelete(id: String) async {
        guard FirebaseApp.app() != nil, let uid = Auth.auth().currentUser?.uid else { return }
        do {
            try await firestoreProvider()
                .collection("users").document(uid)
                .collection("approval_policies").document(safeDocumentID(id))
                .delete()
        } catch {
            lastCloudError = error.localizedDescription
        }
    }

    /// Firestore document IDs cannot contain `/`. Our class-hash format
    /// uses `|` separators which is safe, but defensive escape anyway.
    private func safeDocumentID(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    // MARK: Codec

    private static func encode(_ policy: ApprovalPolicy) -> [String: Any] {
        var dict: [String: Any] = [
            "id": policy.id,
            "displayLabel": policy.displayLabel,
            "decision": policy.decision.rawValue,
            "createdAt": ISO8601DateFormatter().string(from: policy.createdAt),
            "matchCount": policy.matchCount,
            "schemaVersion": 1
        ]
        if let v = policy.missionKind { dict["missionKind"] = v }
        if let v = policy.toolName { dict["toolName"] = v }
        if let v = policy.fileGlob { dict["fileGlob"] = v }
        if let v = policy.runtimeID { dict["runtimeID"] = v }
        if let v = policy.targetProject { dict["targetProject"] = v }
        if let v = policy.expiresAt {
            dict["expiresAt"] = ISO8601DateFormatter().string(from: v)
        }
        return dict
    }

    private static func decode(documentID: String, data: [String: Any]) -> ApprovalPolicy? {
        guard
            let label = data["displayLabel"] as? String,
            let decisionRaw = data["decision"] as? String,
            let decision = ApprovalPolicy.Decision(rawValue: decisionRaw)
        else { return nil }
        let createdAt = (data["createdAt"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let expiresAt = (data["expiresAt"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        return ApprovalPolicy(
            missionKind: data["missionKind"] as? String,
            toolName: data["toolName"] as? String,
            fileGlob: data["fileGlob"] as? String,
            runtimeID: data["runtimeID"] as? String,
            targetProject: data["targetProject"] as? String,
            decision: decision,
            displayLabel: label,
            createdAt: createdAt,
            expiresAt: expiresAt,
            matchCount: (data["matchCount"] as? Int) ?? 0
        )
    }
}
