// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import OpenBurnBarUsageModels

// MARK: - BudgetRulesStoring

/// CRUD contract shared by the GRDB (macOS) and Firestore (iOS) budget rule stores.
/// Both twins implemented this surface identically; the backends keep their extra
/// platform seams (macOS: scoped fetches + `markEventSynced` for CloudSync; iOS:
/// the Firestore snapshot listener + DEBUG mock mode).
public protocol BudgetRulesStoring {
    func upsertRule(_ rule: BudgetRule) async throws
    func deleteRule(id: String) async throws
    func fetchAllRules(includeDisabled: Bool) async throws -> [BudgetRule]
    func fetchRule(id: String) async throws -> BudgetRule?
    func recordEvent(_ event: BudgetEvent) async throws
    func recentEvents(forRule ruleID: String?, limit: Int) async throws -> [BudgetEvent]
}

// MARK: - BudgetRuleFallbackIDs

/// JSON coding for `BudgetRule.fallbackCredentialIDs`, which both backends persist as
/// an encoded string column/field. Empty lists encode to `nil` (no column write).
public enum BudgetRuleFallbackIDs {
    /// Throws on encode failure so the GRDB backend (which historically propagated the
    /// throw and failed the upsert) keeps its exact behavior; the Firestore backend
    /// wraps this in `try?` as it always has.
    public static func encode(_ ids: [String]) throws -> String? {
        guard !ids.isEmpty else { return nil }
        let data = try JSONEncoder().encode(ids)
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ json: String?) -> [String] {
        guard let json,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { // try?-ok(decode fallback empty)
            return []
        }
        return decoded
    }
}

// MARK: - BudgetEventDetail

/// Audit-event `detailJSON` encoding shared by both `BudgetSettings` facades.
public enum BudgetEventDetail {
    public static func encode(_ detail: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(detail) else { return nil } // try?-ok(JSON encode guard-nil)
        return String(data: data, encoding: .utf8)
    }
}
