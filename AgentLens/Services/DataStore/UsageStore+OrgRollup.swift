import Foundation
import GRDB
import OpenBurnBarCore

extension UsageStore {
    // MARK: - Org Rollup

    /// Cross-seat spend rollup grouped by user, project, credential, or provider.
    /// Reuses the same `token_usage` table that `CloudSyncService` already syncs from
    /// every seat — `sourceDeviceID` / `sourceDeviceName` distinguish per-seat rows.
    func fetchOrgRollup(groupBy: OrgGroupBy, period: BudgetPeriod) async throws -> [OrgRollupRow] {
        let windowStart = period.windowStart()
        let column: String
        switch groupBy {
        case .user:       column = "COALESCE(sourceDeviceName, sourceDeviceID, 'local')"
        case .project:    column = "COALESCE(NULLIF(projectName, ''), 'Unassigned')"
        case .credential: column = "COALESCE(NULLIF(providerAccountLabel, ''), NULLIF(providerAccountID, ''), providerID || ' default')"
        case .provider:   column = "provider"
        }

        let whereSQL = windowStart == nil ? "" : "WHERE startTime >= ?"

        let sql = """
            SELECT \(column) AS label,
                   COALESCE(SUM(cost), 0) AS totalCost,
                   COALESCE(SUM(totalTokens), 0) AS totalTokens,
                   COUNT(DISTINCT sessionId) AS sessionCount,
                   COUNT(DISTINCT COALESCE(sourceDeviceID, 'local')) AS deviceCount
            FROM token_usage
            \(whereSQL)
            GROUP BY \(column)
            ORDER BY totalCost DESC
            LIMIT 100
        """

        return try await dbQueue.read { db in
            let rows: [Row]
            if let windowStart {
                rows = try Row.fetchAll(db, sql: sql, arguments: [windowStart])
            } else {
                rows = try Row.fetchAll(db, sql: sql)
            }
            return rows.compactMap { row -> OrgRollupRow? in
                guard let label = row["label"] as? String else { return nil }
                // SUM over an INTEGER column comes back as Int64, so reading
                // `totalTokens` as a Double cast would report zero tokens for
                // every rollup row. The typed subscript converts instead.
                let totalCost: Double = row["totalCost"] ?? 0
                let totalTokens: Double = row["totalTokens"] ?? 0
                let sessionCount: Int = row["sessionCount"] ?? 0
                let deviceCount: Int = row["deviceCount"] ?? 0
                return OrgRollupRow(
                    label: label,
                    totalCost: totalCost,
                    totalTokens: totalTokens,
                    sessionCount: sessionCount,
                    deviceCount: deviceCount
                )
            }
        }
    }
}
