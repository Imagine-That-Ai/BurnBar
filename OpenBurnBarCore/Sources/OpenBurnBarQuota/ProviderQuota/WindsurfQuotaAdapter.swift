import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

// MARK: - Windsurf Quota Adapter

/// Reports Windsurf (Codeium) plan quota, daily/weekly rate limits, flex credits,
/// and flow actions from its local `state.vscdb` global storage database.
public struct WindsurfQuotaAdapter: ProviderQuotaAdapter {
    public init() {}

    private static var candidateVscdbPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Library/Application Support/Windsurf - Next/User/globalStorage/state.vscdb",
            "\(home)/Library/Application Support/Windsurf/User/globalStorage/state.vscdb",
            "\(home)/.config/Windsurf - Next/User/globalStorage/state.vscdb",
            "\(home)/.config/Windsurf/User/globalStorage/state.vscdb"
        ]
    }

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        for path in Self.candidateVscdbPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let snapshot = try? parseStateDB(atPath: path) {
                return snapshot
            }
        }

        return ProviderQuotaSnapshot(
            provider: .windsurf,
            fetchedAt: Date(),
            source: .unavailable,
            confidence: .unavailable,
            managementURL: "https://codeium.com/profile",
            statusMessage: "Windsurf local state database not found",
            buckets: []
        )
    }

    private func parseStateDB(atPath path: String) throws -> ProviderQuotaSnapshot? {
        let reader = try SQLiteConnection.openReadOnly(path: path)
        defer { reader.close() }

        let rows = try reader.query(
            "SELECT value FROM ItemTable WHERE key = 'windsurf.settings.cachedPlanInfo'",
            arguments: []
        )

        guard let firstRow = rows.first,
              let jsonString: String = firstRow.string("value"),
              let data = jsonString.data(using: String.Encoding.utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let planName = (json["planName"] as? String) ?? "Windsurf"
        let usage = json["usage"] as? [String: Any] ?? [:]
        let quotaUsage = json["quotaUsage"] as? [String: Any] ?? [:]

        var buckets: [ProviderQuotaBucket] = []

        // 1. Daily Rolling Quota
        if let dailyRemainingPct = quotaUsage["dailyRemainingPercent"] as? Double ?? (quotaUsage["dailyRemainingPercent"] as? Int).map(Double.init) {
            let usedPct = min(max(100.0 - dailyRemainingPct, 0.0), 100.0)
            let resetsAt: Date? = {
                if let unix = quotaUsage["dailyResetAtUnix"] as? Double {
                    return Date(timeIntervalSince1970: unix)
                } else if let unix = quotaUsage["dailyResetAtUnix"] as? Int {
                    return Date(timeIntervalSince1970: Double(unix))
                }
                return nil
            }()

            buckets.append(ProviderQuotaBucket(
                key: "windsurf-daily",
                label: "Daily quota",
                windowKind: .daily,
                usedValue: usedPct,
                limitValue: 100.0,
                remainingValue: dailyRemainingPct,
                usedPercent: usedPct,
                resetsAt: resetsAt,
                unit: .percent,
                isEstimated: false
            ))
        }

        // 2. Weekly Rolling Quota
        if let weeklyRemainingPct = quotaUsage["weeklyRemainingPercent"] as? Double ?? (quotaUsage["weeklyRemainingPercent"] as? Int).map(Double.init) {
            let usedPct = min(max(100.0 - weeklyRemainingPct, 0.0), 100.0)
            let resetsAt: Date? = {
                if let unix = quotaUsage["weeklyResetAtUnix"] as? Double {
                    return Date(timeIntervalSince1970: unix)
                } else if let unix = quotaUsage["weeklyResetAtUnix"] as? Int {
                    return Date(timeIntervalSince1970: Double(unix))
                }
                return nil
            }()

            buckets.append(ProviderQuotaBucket(
                key: "windsurf-weekly",
                label: "Weekly quota",
                windowKind: .rollingDays,
                usedValue: usedPct,
                limitValue: 100.0,
                remainingValue: weeklyRemainingPct,
                usedPercent: usedPct,
                resetsAt: resetsAt,
                unit: .percent,
                isEstimated: false
            ))
        }

        // 3. Flex Credits (Reasoning models)
        let flexCredits: Double = (usage["flexCredits"] as? Double) ?? (usage["flexCredits"] as? Int).map(Double.init) ?? 0.0
        let remFlex: Double? = (usage["remainingFlexCredits"] as? Double) ?? (usage["remainingFlexCredits"] as? Int).map(Double.init)
        let usedFlex: Double = (usage["usedFlexCredits"] as? Double) ?? (usage["usedFlexCredits"] as? Int).map(Double.init) ?? (remFlex.map { max(flexCredits - $0, 0.0) } ?? 0.0)

        if flexCredits > 0 || usedFlex > 0 {
            let pct: Double = flexCredits > 0 ? min(max((usedFlex / flexCredits) * 100.0, 0.0), 100.0) : 0.0
            let remValue: Double = remFlex ?? max(flexCredits - usedFlex, 0.0)
            buckets.append(ProviderQuotaBucket(
                key: "windsurf-flex-credits",
                label: "Flex credits",
                windowKind: .monthly,
                usedValue: usedFlex,
                limitValue: flexCredits,
                remainingValue: remValue,
                usedPercent: pct,
                resetsAt: nil,
                unit: .credits,
                isEstimated: false
            ))
        }

        // 4. Flow Actions (Cascade Fast)
        let flowActions: Double = (usage["flowActions"] as? Double) ?? (usage["flowActions"] as? Int).map(Double.init) ?? 0.0
        let remFlow: Double? = (usage["remainingFlowActions"] as? Double) ?? (usage["remainingFlowActions"] as? Int).map(Double.init)
        let usedFlow: Double = (usage["usedFlowActions"] as? Double) ?? (usage["usedFlowActions"] as? Int).map(Double.init) ?? (remFlow.map { max(flowActions - $0, 0.0) } ?? 0.0)

        if flowActions > 0 || usedFlow > 0 {
            let pct: Double = flowActions > 0 ? min(max((usedFlow / flowActions) * 100.0, 0.0), 100.0) : 0.0
            let remValue: Double = remFlow ?? max(flowActions - usedFlow, 0.0)
            buckets.append(ProviderQuotaBucket(
                key: "windsurf-flow-actions",
                label: "Flow actions",
                windowKind: .monthly,
                usedValue: usedFlow,
                limitValue: flowActions,
                remainingValue: remValue,
                usedPercent: pct,
                resetsAt: nil,
                unit: .requests,
                isEstimated: false
            ))
        }

        return ProviderQuotaSnapshot(
            provider: .windsurf,
            fetchedAt: Date(),
            source: .localSession,
            confidence: .exact,
            managementURL: "https://codeium.com/profile",
            statusMessage: "\(planName) · \(buckets.count) quota buckets active",
            buckets: buckets
        )
    }
}
