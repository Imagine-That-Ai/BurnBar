import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

/// Reports Windsurf (Codeium) plan quota from its local `state.vscdb`.
public struct WindsurfQuotaAdapter: ProviderQuotaAdapter {
    public let vscdbPathOverride: String?
    public init(vscdbPathOverride: String? = nil) { self.vscdbPathOverride = vscdbPathOverride }

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let home = NSHomeDirectory()
        let paths = vscdbPathOverride.map { [$0] } ?? [
            "\(home)/Library/Application Support/Windsurf - Next/User/globalStorage/state.vscdb",
            "\(home)/Library/Application Support/Windsurf/User/globalStorage/state.vscdb",
            "\(home)/.config/Windsurf - Next/User/globalStorage/state.vscdb",
            "\(home)/.config/Windsurf/User/globalStorage/state.vscdb",
        ]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            if let snapshot = try? parseStateDB(atPath: path) { return snapshot }
        }
        return ProviderQuotaSnapshot(
            provider: .windsurf, fetchedAt: Date(), source: .unavailable, confidence: .unavailable,
            managementURL: "https://codeium.com/profile",
            statusMessage: "Windsurf local state database not found", buckets: []
        )
    }

    private func parseStateDB(atPath path: String) throws -> ProviderQuotaSnapshot? {
        let reader = try SQLiteConnection.openReadOnly(path: path)
        defer { reader.close() }
        let rows = try reader.query(
            "SELECT value FROM ItemTable WHERE key = 'windsurf.settings.cachedPlanInfo'",
            arguments: []
        )
        guard let jsonString = rows.first?.string("value"),
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let usage = json["usage"] as? [String: Any] ?? [:]
        let quota = json["quotaUsage"] as? [String: Any] ?? [:]
        let planName = (json["planName"] as? String) ?? "Windsurf"
        let buckets = [
            percentBucket(quota, remaining: "dailyRemainingPercent", reset: "dailyResetAtUnix", key: "windsurf-daily", label: "Daily quota", window: .daily),
            percentBucket(quota, remaining: "weeklyRemainingPercent", reset: "weeklyResetAtUnix", key: "windsurf-weekly", label: "Weekly quota", window: .rollingDays),
            creditBucket(usage, limit: "flexCredits", remaining: "remainingFlexCredits", used: "usedFlexCredits", key: "windsurf-flex-credits", label: "Flex credits", unit: .credits),
            creditBucket(usage, limit: "flowActions", remaining: "remainingFlowActions", used: "usedFlowActions", key: "windsurf-flow-actions", label: "Flow actions", unit: .requests),
        ].compactMap { $0 }
        return ProviderQuotaSnapshot(
            provider: .windsurf, fetchedAt: Date(), source: .localSession, confidence: .exact,
            managementURL: "https://codeium.com/profile",
            statusMessage: "\(planName) · \(buckets.count) quota buckets active", buckets: buckets
        )
    }

    private func number(_ object: [String: Any], _ key: String) -> Double? {
        (object[key] as? Double) ?? (object[key] as? Int).map(Double.init)
    }

    private func percentBucket(
        _ object: [String: Any], remaining: String, reset: String,
        key: String, label: String, window: ProviderQuotaWindowKind
    ) -> ProviderQuotaBucket? {
        guard let remainingValue = number(object, remaining) else { return nil }
        let used = min(max(100 - remainingValue, 0), 100)
        return ProviderQuotaBucket(
            key: key, label: label, windowKind: window, usedValue: used, limitValue: 100,
            remainingValue: remainingValue, usedPercent: used,
            resetsAt: number(object, reset).map(Date.init(timeIntervalSince1970:)),
            unit: .percent, isEstimated: false
        )
    }

    private func creditBucket(
        _ object: [String: Any], limit: String, remaining: String, used: String,
        key: String, label: String, unit: ProviderQuotaUnit
    ) -> ProviderQuotaBucket? {
        let cap = number(object, limit) ?? 0
        let remainingValue = number(object, remaining)
        let usedValue = number(object, used) ?? remainingValue.map { max(cap - $0, 0) } ?? 0
        guard cap > 0 || usedValue > 0 else { return nil }
        return ProviderQuotaBucket(
            key: key, label: label, windowKind: .monthly, usedValue: usedValue, limitValue: cap,
            remainingValue: remainingValue ?? max(cap - usedValue, 0),
            usedPercent: cap > 0 ? min(max((usedValue / cap) * 100, 0), 100) : 0,
            resetsAt: nil, unit: unit, isEstimated: false
        )
    }
}
