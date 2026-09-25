import Foundation
import OpenBurnBarKernel
import Observation
import OpenBurnBarAnalytics

/// Observable façade over `GRDBBudgetRulesStore`. The macOS Settings UI binds to this;
/// `BudgetGate` reads through it (Phase 4); Hermes / MCP write through it (Phase 7).
///
/// Pattern mirrors `AlertSettings` (an `@Observable @MainActor final class`) but is backed
/// by SQLite rather than `UserDefaults` because rules need to ride `CloudSyncService` for
/// enterprise multi-seat parity in Phase 8.
///
/// The macOS settings backend. Rule filtering comes from `BudgetRuleProviding` defaults in
/// OpenBurnBarKernel; persistence, refresh, legacy migration, and Analytics stay here.
@Observable
@MainActor
final class BudgetSettings {
    private let store: GRDBBudgetRulesStore
    private let alertSettings: AlertSettings
    private let deviceID: String
    private let migrationDefaultsKey = "budgetSettings.legacyCostAlertThresholdMigrated"

    /// In-memory cache of every enabled rule. Refreshed on `refresh()` and after every write.
    private(set) var rules: [BudgetRule] = []
    private(set) var recentEventCache: [BudgetEvent] = []

    init(store: GRDBBudgetRulesStore, alertSettings: AlertSettings, deviceID: String) {
        self.store = store
        self.alertSettings = alertSettings
        self.deviceID = deviceID
        Task { @MainActor in
            await bootstrapFromStore()
        }
    }

    // MARK: - Refresh

    /// Re-reads every enabled rule from SQLite. Call after CloudSync downloads or
    /// after the user re-enables a disabled rule via direct DB edit.
    func refresh() async {
        await loadFromStore()
        await loadRecentEvents()
    }

    private func bootstrapFromStore() async {
        await refresh()
        await migrateLegacyCostAlertThresholdIfNeeded()
    }

    private func loadFromStore() async {
        do {
            rules = try await store.fetchAllRules(includeDisabled: false)
        } catch {
            rules = []
        }
    }

    private func loadRecentEvents(limit: Int = 100) async {
        do {
            recentEventCache = try await store.recentEvents(limit: limit)
        } catch {
            recentEventCache = []
        }
    }

    // MARK: - Writes (UI / Hermes / MCP entry points)

    @discardableResult
    func upsertRule(_ rule: BudgetRule, source: String = "settings_ui", suppressAnalytics: Bool = false) async -> BudgetRule {
        var stamped = rule
        stamped.updatedAt = Date()
        stamped.syncedAt = nil
        stamped.sourceDeviceID = stamped.sourceDeviceID ?? deviceID

        do {
            try await store.upsertRule(stamped)
            let kind: BudgetEventKind = rules.contains(where: { $0.id == stamped.id }) ? .ruleUpdated : .ruleCreated
            try await store.recordEvent(BudgetEvent(
                ruleID: stamped.id,
                kind: kind,
                source: source,
                amountAtEvent: 0,
                limitAtEvent: stamped.amountUSD,
                detailJSON: BudgetEventDetail.encode(["label": stamped.displayLabel, "period": stamped.period.rawValue])
            ))
            if !suppressAnalytics {
                Analytics.shared.track(.budgetRuleChanged, [
                    "action": kind == .ruleUpdated ? "updated" : "created",
                    "rule_scope": .string(stamped.scope.rawValue),
                    "period": .string(stamped.period.rawValue),
                    "amount_usd_bucket": .string(AnalyticsBuckets.amountUSD(stamped.amountUSD))
                ])
            }
            await refresh()
        } catch {
            AppLogger.dataStore.silentFailure( // cov:ignore -- nonfatal-log
                "budget_rule_upsert_failed", // cov:ignore -- nonfatal-log
                error: error, // cov:ignore -- nonfatal-log
                context: ["source": source] // cov:ignore -- nonfatal-log
            ) // cov:ignore -- nonfatal-log
        }
        return stamped
    }

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
                detailJSON: BudgetEventDetail.encode(["label": existing.displayLabel])
            ))
            Analytics.shared.track(.budgetRuleChanged, [
                "action": "deleted",
                "rule_scope": .string(existing.scope.rawValue),
                "period": .string(existing.period.rawValue),
                "amount_usd_bucket": .string(AnalyticsBuckets.amountUSD(existing.amountUSD))
            ])
            await refresh()
        } catch {
            // Best-effort delete; refresh state regardless.
            await refresh()
        }
    }

    func pauseRule(id: String, until resumeAt: Date, source: String = "settings_ui") async {
        guard var rule = rules.first(where: { $0.id == id }) else { return }
        rule.pausedUntil = resumeAt
        await upsertRule(rule, source: source, suppressAnalytics: true)
        try? await store.recordEvent(BudgetEvent( // try?-ok(best-effort audit event)
            ruleID: id,
            kind: .pause,
            source: source,
            amountAtEvent: 0,
            limitAtEvent: rule.amountUSD,
            detailJSON: BudgetEventDetail.encode(["pausedUntil": ISO8601DateFormatter().string(from: resumeAt)])
        ))
        Analytics.shared.track(.budgetRuleChanged, [
            "action": "paused",
            "rule_scope": .string(rule.scope.rawValue),
            "period": .string(rule.period.rawValue),
            "amount_usd_bucket": .string(AnalyticsBuckets.amountUSD(rule.amountUSD))
        ])
        await loadRecentEvents()
    }

    func resumeRule(id: String, source: String = "settings_ui") async {
        guard var rule = rules.first(where: { $0.id == id }) else { return }
        rule.pausedUntil = nil
        await upsertRule(rule, source: source, suppressAnalytics: true)
        try? await store.recordEvent(BudgetEvent( // try?-ok(best-effort audit event)
            ruleID: id,
            kind: .resume,
            source: source,
            amountAtEvent: 0,
            limitAtEvent: rule.amountUSD
        ))
        Analytics.shared.track(.budgetRuleChanged, [
            "action": "resumed",
            "rule_scope": .string(rule.scope.rawValue),
            "period": .string(rule.period.rawValue),
            "amount_usd_bucket": .string(AnalyticsBuckets.amountUSD(rule.amountUSD))
        ])
        await loadRecentEvents()
    }

    // MARK: - Reads
    //
    // Rule filtering (`rules(forCredential:)`, `rules(forProject:)`, `primaryGlobalRule`,
    // and the per-scope collections) comes from the `BudgetRuleProviding` defaults in
    // OpenBurnBarKernel, shared with the iOS facade.

    /// Recent audit events. Wraps the store so views don't need to know about GRDB.
    func recentEvents(forRule ruleID: String? = nil, limit: Int = 100) -> [BudgetEvent] {
        let events = ruleID.map { id in
            recentEventCache.filter { $0.ruleID == id }
        } ?? recentEventCache
        return Array(events.prefix(max(0, limit)))
    }

    // MARK: - Legacy migration

    /// Converts the legacy `AlertSettings.costAlertThreshold` value (a single `Double?` in
    /// `UserDefaults`) into a `BudgetRule(scope: .global, period: .month, behavior: .warnOnly)`
    /// on first launch after Phase 3 ships. Runs exactly once per device.
    private func migrateLegacyCostAlertThresholdIfNeeded() async {
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
        await upsertRule(migrated, source: "legacy_migration")
    }
}
