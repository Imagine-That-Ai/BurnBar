import Foundation
import OpenBurnBarCore
import SwiftUI

/// Observable façade over `BudgetRulesStore`. The macOS Settings UI binds to this;
/// `BudgetGate` reads through it (Phase 4); Hermes / MCP write through it (Phase 7).
///
/// Pattern mirrors `AlertSettings` (an `@Observable @MainActor final class`) but is backed
/// by SQLite rather than `UserDefaults` because rules need to ride `CloudSyncService` for
/// enterprise multi-seat parity in Phase 8.
@Observable
@MainActor
final class BudgetSettings {
    private let store: BudgetRulesStore
    private let alertSettings: AlertSettings
    private let deviceID: String
    private let migrationDefaultsKey = "budgetSettings.legacyCostAlertThresholdMigrated"

    /// In-memory cache of every enabled rule. Refreshed on `refresh()` and after every write.
    private(set) var rules: [BudgetRule] = []

    init(store: BudgetRulesStore, alertSettings: AlertSettings, deviceID: String) {
        self.store = store
        self.alertSettings = alertSettings
        self.deviceID = deviceID
        loadFromStore()
        migrateLegacyCostAlertThresholdIfNeeded()
    }

    // MARK: - Refresh

    /// Re-reads every enabled rule from SQLite. Call after CloudSync downloads or
    /// after the user re-enables a disabled rule via direct DB edit.
    func refresh() {
        loadFromStore()
    }

    private func loadFromStore() {
        do {
            rules = try store.fetchAllRules(includeDisabled: false)
        } catch {
            rules = []
        }
    }

    // MARK: - Writes (UI / Hermes / MCP entry points)

    @discardableResult
    func upsertRule(_ rule: BudgetRule, source: String = "settings_ui") -> BudgetRule {
        var stamped = rule
        stamped.updatedAt = Date()
        stamped.syncedAt = nil
        stamped.sourceDeviceID = stamped.sourceDeviceID ?? deviceID

        do {
            try store.upsertRule(stamped)
            let kind: BudgetEventKind = rules.contains(where: { $0.id == stamped.id }) ? .ruleUpdated : .ruleCreated
            try store.recordEvent(BudgetEvent(
                ruleID: stamped.id,
                kind: kind,
                source: source,
                amountAtEvent: 0,
                limitAtEvent: stamped.amountUSD,
                detailJSON: encodeDetail(["label": stamped.displayLabel, "period": stamped.period.rawValue])
            ))
            loadFromStore()
        } catch {
            AppLogger.dataStore.silentFailure( // cov:ignore -- nonfatal-log
                "budget_rule_upsert_failed", // cov:ignore -- nonfatal-log
                error: error, // cov:ignore -- nonfatal-log
                context: ["source": source] // cov:ignore -- nonfatal-log
            ) // cov:ignore -- nonfatal-log
        }
        return stamped
    }

    func deleteRule(id: String, source: String = "settings_ui") {
        guard let existing = rules.first(where: { $0.id == id }) else { return }
        do {
            try store.deleteRule(id: id)
            try store.recordEvent(BudgetEvent(
                ruleID: id,
                kind: .ruleDeleted,
                source: source,
                amountAtEvent: 0,
                limitAtEvent: existing.amountUSD,
                detailJSON: encodeDetail(["label": existing.displayLabel])
            ))
            loadFromStore()
        } catch {
            // Best-effort delete; refresh state regardless.
            loadFromStore()
        }
    }

    func pauseRule(id: String, until resumeAt: Date, source: String = "settings_ui") {
        guard var rule = rules.first(where: { $0.id == id }) else { return }
        rule.pausedUntil = resumeAt
        upsertRule(rule, source: source)
        try? store.recordEvent(BudgetEvent(
            ruleID: id,
            kind: .pause,
            source: source,
            amountAtEvent: 0,
            limitAtEvent: rule.amountUSD,
            detailJSON: encodeDetail(["pausedUntil": ISO8601DateFormatter().string(from: resumeAt)])
        ))
    }

    func resumeRule(id: String, source: String = "settings_ui") {
        guard var rule = rules.first(where: { $0.id == id }) else { return }
        rule.pausedUntil = nil
        upsertRule(rule, source: source)
        try? store.recordEvent(BudgetEvent(
            ruleID: id,
            kind: .resume,
            source: source,
            amountAtEvent: 0,
            limitAtEvent: rule.amountUSD
        ))
    }

    // MARK: - Reads

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

    /// Recent audit events. Wraps the store so views don't need to know about GRDB.
    func recentEvents(forRule ruleID: String? = nil, limit: Int = 100) -> [BudgetEvent] {
        (try? store.recentEvents(forRule: ruleID, limit: limit)) ?? []
    }

    // MARK: - Legacy migration

    /// Converts the legacy `AlertSettings.costAlertThreshold` value (a single `Double?` in
    /// `UserDefaults`) into a `BudgetRule(scope: .global, period: .month, behavior: .warnOnly)`
    /// on first launch after Phase 3 ships. Runs exactly once per device.
    private func migrateLegacyCostAlertThresholdIfNeeded() {
        guard UserDefaults.standard.bool(forKey: migrationDefaultsKey) == false else { return }
        defer { UserDefaults.standard.set(true, forKey: migrationDefaultsKey) }

        guard let legacyThreshold = alertSettings.costAlertThreshold,
              legacyThreshold > 0,
              primaryGlobalRule == nil else {
            return
        }

        let migrated = BudgetRule(
            scope: .global,
            label: "Legacy spend alert",
            amountUSD: legacyThreshold,
            period: .month,
            behavior: .warnOnly,
            sourceDeviceID: deviceID
        )
        upsertRule(migrated, source: "legacy_migration")
    }

    // MARK: - Helpers

    private func encodeDetail(_ detail: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(detail) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
