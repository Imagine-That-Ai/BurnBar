import Foundation
@preconcurrency import GRDB
import OpenBurnBarCore

// MARK: - Versioned usage-memory curation policy record (PR9)
//
// The durable, versioned home of `UsageMemoryCurationPolicy`: one JSON row in
// `controller_runtime_cache` (the same generic key/value surface the Stage-0
// miner cursor rides — macOS has no `app_state` table, see
// `usageSessionMinerCursorKey`). The record is the ONLY surface the
// self-improvement loop may tune, and every change is audited
// (`memory.policy_updated`) with version labels only.
//
// CONSENT/EGRESS ARE NOT IN THIS RECORD — BY CONSTRUCTION. The policy type
// carries thresholds, weights, trust, and caps; nothing in it can represent a
// consent grant, an egress destination, a gate box, or the G7 secret gate, so
// a tuned (or even maliciously crafted) persisted record can never widen what
// leaves the machine. Gates live in `SettingsManager`/`MemorySettings` and are
// re-checked live by every worker.

extension ControlPlaneStore {
    /// `controller_runtime_cache` key holding the persisted curation policy.
    static let usageMemoryCurationPolicyKey = "usage_memory.curation_policy.v1"

    /// Stable audit `project_id` for policy-record events (the record is
    /// machine-global — it predates and outlives any single memory scope).
    static let usageMemoryPolicyAuditProjectID = "usage:policy"

    /// Load the persisted curation policy. An absent row — the pre-PR9 state
    /// and every fresh install — resolves to the compiled
    /// `UsageMemoryCurationPolicy.defaults`, as does an undecodable row (a
    /// corrupt record must degrade to safe compiled knobs, never wedge the
    /// consolidation cadence).
    func loadUsageMemoryCurationPolicy() async throws -> UsageMemoryCurationPolicy {
        let json = try await dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT payloadJSON FROM controller_runtime_cache WHERE cacheKey = ?",
                arguments: [Self.usageMemoryCurationPolicyKey]
            )
        }
        guard let json,
              let decoded = try? JSONDecoder().decode( // try?-ok(corrupt policy row degrades to compiled defaults)
                  UsageMemoryCurationPolicy.self,
                  from: Data(json.utf8)
              )
        else {
            return .defaults
        }
        return decoded
    }

    /// Persist `policy` as the active curation record AND audit the change —
    /// one write transaction, so an audited version bump can never point at an
    /// unpersisted record. The audit labels are VERSIONS AND REASON ONLY
    /// ({old_version, new_version, reason}); knob values never enter the audit
    /// chain (the record itself is the readable state).
    func saveUsageMemoryCurationPolicy(
        _ policy: UsageMemoryCurationPolicy,
        reason: String,
        now: Date = Date()
    ) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(policy), as: UTF8.self)
        let nowString = Self.iso8601String(now)
        try await dbQueue.write { db in
            let existingJSON = try String.fetchOne(
                db,
                sql: "SELECT payloadJSON FROM controller_runtime_cache WHERE cacheKey = ?",
                arguments: [Self.usageMemoryCurationPolicyKey]
            )
            let oldVersion = existingJSON
                .flatMap { try? JSONDecoder().decode(UsageMemoryCurationPolicy.self, from: Data($0.utf8)) } // try?-ok(corrupt old row audits as the defaults version)
                .map(\.policyVersion) ?? UsageMemoryCurationPolicy.defaults.policyVersion
            try db.execute(
                sql: """
                INSERT INTO controller_runtime_cache (cacheKey, payloadJSON, updatedAt)
                VALUES (?, ?, ?)
                ON CONFLICT(cacheKey) DO UPDATE SET
                    payloadJSON = excluded.payloadJSON,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [Self.usageMemoryCurationPolicyKey, json, now]
            )
            try Self.insertMemoryAuditEvent(
                db: db,
                action: "memory.policy_updated",
                projectID: Self.usageMemoryPolicyAuditProjectID,
                subjectID: Self.usageMemoryCurationPolicyKey,
                labels: [
                    "new_version:\(policy.policyVersion)",
                    "old_version:\(oldVersion)",
                    "reason:\(reason)"
                ],
                nowString: nowString
            )
        }
    }
}
