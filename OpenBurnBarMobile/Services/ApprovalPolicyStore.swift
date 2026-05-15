import Foundation
import Observation
import OpenBurnBarCore

// MARK: - Approval Policy Store (Hermes Square §6.9)
//
// Owns the user's list of `ApprovalPolicy` rules and persists them to
// UserDefaults (Firestore sync hooks in Phase D). The mission console
// host calls `resolve(...)` before surfacing an approval ask — if a
// policy matches, the host auto-responds without bothering the user.

@MainActor
@Observable
final class ApprovalPolicyStore {
    static let shared = ApprovalPolicyStore()

    private(set) var policies: [ApprovalPolicy] = []

    private static let userDefaultsKey = "square.approvalPolicies.v1"

    init() {
        self.policies = Self.load()
    }

    /// Add a new policy. Replaces any existing policy with the same class
    /// hash (`id`).
    func record(_ policy: ApprovalPolicy) {
        if let idx = policies.firstIndex(where: { $0.id == policy.id }) {
            policies[idx] = policy
        } else {
            policies.append(policy)
        }
        save()
    }

    func remove(id: String) {
        policies.removeAll { $0.id == id }
        save()
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
        }
        return policy
    }

    /// Persist to UserDefaults via JSON. Cloud sync deferred.
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
}
