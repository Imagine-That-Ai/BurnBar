import Foundation
import GRDB
import OpenBurnBarCore

/// Reads The Elder Wand's fusion-versus-normal spend over a window directly
/// from the canonical `token_usage` table.
///
/// This is the durable counterpart to the live daemon RPC: once the v49
/// migration adds the nullable `parentRequestID` column and the daemon usage
/// sync threads `elderwand-<UUID>` through it, every imported fusion sub-call
/// row is tagged in SQLite. The standing "Fusion impact" screen can then ask a
/// single indexed question — "of everything I spent this period, how much went
/// to fusion runs?" — instead of replaying the daemon's in-memory recent-usage
/// buffer.
///
/// The actor projects rows into the platform-neutral `FusionUsageRow` and hands
/// them to `FusionSpendAggregator.partition(_:)`, the same pure aggregator the
/// receipt modal uses, so the two surfaces can never disagree about what counts
/// as fusion.
actor FusionImpactLedger {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    /// Fusion-versus-normal totals for `[windowStart, windowEnd]`. Fusion rows
    /// are those whose `parentRequestID` is an `elderwand-…` parent; everything
    /// else is normal. Costs are summed as recorded — never repriced — so the
    /// screen reconciles to the ledger exactly.
    func totals(from windowStart: Date, to windowEnd: Date) async throws -> FusionVsNormalTotals {
        let rows = try await rows(from: windowStart, to: windowEnd)
        return FusionSpendAggregator.partition(rows)
    }

    /// The flat usage rows for the window, projected for the aggregator.
    ///
    /// `stageLabel` is intentionally `nil`: the local `token_usage` table stores
    /// the fusion parent but not the per-stage signature (that rode the
    /// idempotency key, which is dropped on import). The period screen only ever
    /// needs the fusion/normal split and per-model contribution — both of which
    /// `partition(_:)` derives without the stage — so a `nil` stage is correct
    /// here. The end-of-session receipt modal, which does need stages, reads the
    /// live daemon path instead.
    func rows(from windowStart: Date, to windowEnd: Date) async throws -> [FusionUsageRow] {
        try await dbQueue.read { db in
            let sql = """
                SELECT
                    parentRequestID,
                    model,
                    inputTokens,
                    outputTokens,
                    cacheCreationTokens,
                    cacheReadTokens,
                    reasoningTokens,
                    cost,
                    provenanceConfidence,
                    startTime
                FROM token_usage
                WHERE startTime >= ? AND startTime <= ?
                """
            let dbRows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: [windowStart, windowEnd]
            )
            return dbRows.map { row in
                FusionUsageRow(
                    parentRequestID: row["parentRequestID"] as? String,
                    stageLabel: nil,
                    modelID: (row["model"] as? String) ?? "",
                    inputTokens: Self.intValue(row["inputTokens"]),
                    outputTokens: Self.intValue(row["outputTokens"]),
                    cacheCreationTokens: Self.intValue(row["cacheCreationTokens"]),
                    cacheReadTokens: Self.intValue(row["cacheReadTokens"]),
                    reasoningTokens: Self.intValue(row["reasoningTokens"]),
                    cost: Self.doubleValue(row["cost"]),
                    confidence: Self.confidence(row["provenanceConfidence"] as? String),
                    recordedAt: OpenBurnBarDatabase.parseDateValue(row["startTime"]) ?? windowStart
                )
            }
        }
    }

    // MARK: - Mapping helpers

    /// `UsageProvenanceConfidence` and `BurnBarUsageConfidence` share raw
    /// values, so the persisted column maps straight across; an unknown or
    /// missing value reads as `.unknown`, which `aggregateConfidence` treats as
    /// the weakest — i.e. the UI marks it an estimate honestly.
    private static func confidence(_ raw: String?) -> BurnBarUsageConfidence {
        guard let raw, let mapped = BurnBarUsageConfidence(rawValue: raw) else { return .unknown }
        return mapped
    }

    private static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Int64 { return Double(value) }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return 0
    }
}
