import Foundation
import OpenBurnBarCore
import SwiftUI
import UIKit

/// Observable façade over `BudgetRulesStore` for the iOS budget UI. Settings views bind
/// to this; `BudgetGate` reads through it; Hermes / MCP write through it.
///
/// Pattern mirrors the macOS `BudgetSettings` (`@Observable @MainActor final class`) but
/// is backed by Firestore via `BudgetRulesStore` rather than SQLite. The in-memory `rules`
/// cache is kept fresh by a Firestore snapshot listener started on `init`.
@Observable
@MainActor
final class BudgetSettings {
    private let store: BudgetRulesStore

    /// Stable device identifier used as `sourceDeviceID` on every write. Falls back to a
    /// random UUID when `identifierForVendor` is nil (e.g. in Simulator edge cases).
    private let deviceID: String

    /// In-memory cache of every enabled rule. Refreshed via Firestore listener and after
    /// every write operation.
    private(set) var rules: [BudgetRule] = []

    /// Creates a new `BudgetSettings` backed by the given `BudgetRulesStore`.
    /// Immediately starts a Firestore listener for live rule updates and kicks off
    /// the legacy AppStorage migration check.
    init(store: BudgetRulesStore) {
        self.store = store
        self.deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

        store.startListening { [weak self] rules in
            self?.rules = rules
        }

        Task { [weak self] in
            await self?.migrateAppStorageBudgetIfNeeded()
        }
    }

    deinit {
        Task { @MainActor [store] in
            store.stopListening()
        }
    }

    // MARK: - Refresh

    /// Re-fetches every enabled rule from Firestore. Call after manual edits or when the
    /// listener may have been interrupted.
    func refresh() async {
        do {
            rules = try await store.fetchAllRules(includeDisabled: false)
        } catch {
            // Keep stale cache rather than clearing on transient failure.
        }
    }

    // MARK: - Writes (UI / Hermes / MCP entry points)

    /// Upsert a rule with audit metadata stamps. Records a `ruleCreated` or `ruleUpdated`
    /// event in the audit log, then refreshes the local cache.
    @discardableResult
    func upsertRule(_ rule: BudgetRule, source: String = "settings_ui") async -> BudgetRule {
        var stamped = rule
        stamped.updatedAt = Date()
        stamped.syncedAt = nil
        stamped.sourceDeviceID = stamped.sourceDeviceID ?? deviceID

        do {
            let kind: BudgetEventKind = rules.contains(where: { $0.id == stamped.id })
                ? .ruleUpdated : .ruleCreated
            try await store.upsertRule(stamped)
            try await store.recordEvent(BudgetEvent(
                ruleID: stamped.id,
                kind: kind,
                source: source,
                amountAtEvent: 0,
                limitAtEvent: stamped.amountUSD,
                detailJSON: encodeDetail(["label": stamped.displayLabel, "period": stamped.period.rawValue])
            ))
            await refresh()
        } catch {
            // Surface via signpost / debug-log if a metrics hook is present.
        }
        return stamped
    }

    /// Deletes a rule by ID, recording a `ruleDeleted` audit event.
    func deleteRule(id: String, source: String = "settings_ui") async {
        guard let existing = rules.first(where: { $0.id == id }) else { return }
        do {
            try await store.deleteRule(id: id)
            try await store.recordEvent(BudgetEvent(
                ruleID: id,
                kind: .ruleDeleted,
                source: source,
                amountAtEvent: 0,
                limitAtEvent: existing.amountUSD,
                detailJSON: encodeDetail(["label": existing.displayLabel])
            ))
            await refresh()
        } catch {
            // Best-effort delete; refresh state regardless.
            await refresh()
        }
    }

    /// Pauses a rule until the given date, recording a `pause` audit event.
    func pauseRule(id: String, until resumeAt: Date, source: String = "settings_ui") async {
        guard var rule = rules.first(where: { $0.id == id }) else { return }
        rule.pausedUntil = resumeAt
        await upsertRule(rule, source: source)
        try? await store.recordEvent(BudgetEvent(
            ruleID: id,
            kind: .pause,
            source: source,
            amountAtEvent: 0,
            limitAtEvent: rule.amountUSD,
            detailJSON: encodeDetail(["pausedUntil": ISO8601DateFormatter().string(from: resumeAt)])
        ))
    }

    /// Resumes a paused rule, recording a `resume` audit event.
    func resumeRule(id: String, source: String = "settings_ui") async {
        guard var rule = rules.first(where: { $0.id == id }) else { return }
        rule.pausedUntil = nil
        await upsertRule(rule, source: source)
        try? await store.recordEvent(BudgetEvent(
            ruleID: id,
            kind: .resume,
            source: source,
            amountAtEvent: 0,
            limitAtEvent: rule.amountUSD
        ))
    }

    // MARK: - Reads (filtered from in-memory cache)

    /// Every credential-scope rule for the given `(providerID, accountID)` pair.
    func rules(forCredential providerID: String, accountID: String?) -> [BudgetRule] {
        rules.filter {
            guard $0.scope == .credential, $0.providerID == providerID else { return false }
            if let accountID {
                return $0.accountID == accountID
            }
            return $0.accountID == nil || $0.accountID?.isEmpty == true
        }
    }

    /// Every project-scope rule for the given free-text project name.
    func rules(forProject projectName: String) -> [BudgetRule] {
        rules.filter { $0.scope == .project && $0.projectName == projectName }
    }

    /// The most permissive global rule (the largest amount). Used by `BudgetGate` when
    /// no credential- or project-scope rule matches a request.
    var primaryGlobalRule: BudgetRule? {
        rules
            .filter { $0.scope == .global }
            .max(by: { $0.amountUSD < $1.amountUSD })
    }

    var globalRules: [BudgetRule] { rules.filter { $0.scope == .global } }
    var credentialRules: [BudgetRule] { rules.filter { $0.scope == .credential } }
    var projectRules: [BudgetRule] { rules.filter { $0.scope == .project } }
    var organizationRules: [BudgetRule] { rules.filter { $0.scope == .organization } }

    /// Recent audit events. Wraps the store so views don't need to know about Firestore.
    func recentEvents(forRule ruleID: String? = nil, limit: Int = 100) async -> [BudgetEvent] {
        (try? await store.recentEvents(forRule: ruleID, limit: limit)) ?? []
    }

    // MARK: - Legacy migration

    /// Converts the legacy `UserDefaults` `dailyBudget` value (a single `Double` set by the
    /// old AppStorage-based budget UI) into a proper `BudgetRule` on first launch after the
    /// budgeting port ships. Runs exactly once per device — clears the key on success.
    private func migrateAppStorageBudgetIfNeeded() async {
        let key = "dailyBudget"
        let legacyAmount = UserDefaults.standard.double(forKey: key)
        guard legacyAmount > 0 else { return }

        // Only create the rule if there's no existing global rule
        guard primaryGlobalRule == nil else {
            // Already have a rule — just clear the legacy key
            UserDefaults.standard.removeObject(forKey: key)
            return
        }

        let migrated = BudgetRule(
            scope: .global,
            label: "Daily budget (migrated)",
            amountUSD: legacyAmount,
            period: .day,
            behavior: .warnOnly,
            sourceDeviceID: deviceID
        )
        await upsertRule(migrated, source: "legacy_migration")
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Helpers

    private func encodeDetail(_ detail: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(detail) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
