import Foundation
import GRDB
import OpenBurnBarCore

extension UsageStore {
    func deleteKimiRequestIDModelRows(replacedBy usage: TokenUsage, in db: Database) throws { // pure-move: was private
        guard usage.provider == .kimi,
              !Self.isKimiRequestIDModel(usage.model) else { return }
        let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)

        try db.execute(
            sql: """
                DELETE FROM token_usage
                WHERE provider = ?
                  AND sessionId = ?
                  AND model LIKE 'chatcmpl-%'
                  AND COALESCE(sourceDeviceId, '') = COALESCE(?, '')
                  AND COALESCE(providerAccountID, '') = COALESCE(?, '')
                """,
            arguments: [
                usage.provider.rawValue,
                usage.sessionId,
                usage.sourceDeviceId,
                usagePartition
            ]
        )
    }

    private static func isKimiRequestIDModel(_ model: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("chatcmpl-")
    }

    func shouldSuppressFactoryRoutedMirror(_ usage: TokenUsage, in db: Database) throws -> Bool { // pure-move: was private
        guard Self.isFactoryRoutedMirrorProvider(usage.provider) else { return false }
        let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)
        let count = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM token_usage
                WHERE provider = ?
                  AND sessionId = ?
                  AND COALESCE(sourceDeviceId, '') = COALESCE(?, '')
                  AND COALESCE(providerAccountID, '') = COALESCE(?, '')
                """,
            arguments: [
                AgentProvider.factory.rawValue,
                usage.sessionId,
                usage.sourceDeviceId,
                usagePartition
            ]
        ) ?? 0
        return count > 0
    }

    func deleteFactoryRoutedMirrorRows(replacedBy usage: TokenUsage, in db: Database) throws { // pure-move: was private
        guard usage.provider == .factory else { return }
        let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)
        try db.execute(
            sql: """
                DELETE FROM token_usage
                WHERE provider IN (?, ?, ?)
                  AND sessionId = ?
                  AND COALESCE(sourceDeviceId, '') = COALESCE(?, '')
                  AND COALESCE(providerAccountID, '') = COALESCE(?, '')
                """,
            arguments: [
                AgentProvider.zai.rawValue,
                AgentProvider.minimax.rawValue,
                AgentProvider.ollama.rawValue,
                usage.sessionId,
                usage.sourceDeviceId,
                usagePartition
            ]
        )
    }

    func deleteStaleLowerConfidenceModelRows(replacedBy usage: TokenUsage, in db: Database) throws { // pure-move: was private
        let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)
        try db.execute(
            sql: """
                DELETE FROM token_usage
                WHERE provider = ?
                  AND sessionId = ?
                  AND model != ?
                  AND COALESCE(sourceDeviceId, '') = COALESCE(?, '')
                  AND COALESCE(providerAccountID, '') = COALESCE(?, '')
                  AND (
                    CASE provenanceConfidence
                        WHEN 'exact' THEN 4
                        WHEN 'derived_exact' THEN 3
                        WHEN 'high_confidence_estimate' THEN 2
                        WHEN 'low_confidence_estimate' THEN 1
                        ELSE 0
                    END
                  ) < ?
                """,
            arguments: [
                usage.provider.rawValue,
                usage.sessionId,
                usage.model,
                usage.sourceDeviceId,
                usagePartition,
                usage.provenanceConfidence.precedence
            ]
        )
    }

    private static func isFactoryRoutedMirrorProvider(_ provider: AgentProvider) -> Bool {
        provider == .zai || provider == .minimax || provider == .ollama
    }

    /// Inserts remote usage with update-to-correction semantics.
    ///
    /// VAL-TOKEN-012: Remote re-ingest follows explicit "update-to-correction" semantics.
    /// If remote data provides a correction for the same logical key, the canonical row
    /// converges to the corrected values.
    ///
    /// VAL-PERSIST-009: Remote correction convergence is enforced.
    /// When upstream remote data corrects a previously ingested remote row for the same
    /// logical key, local persistence converges to corrected canonical values.
    ///
    /// Precedence is still respected: higher-confidence data wins over lower-confidence.
    /// Cloud sync data with equal or higher confidence than existing row will update it.
    func insertRemoteUsage(_ usage: TokenUsage) async throws {
        try await dbQueue.write { db in
            let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)
            try db.execute(
                sql: """
                    INSERT INTO token_usage (
                        id, provider, sessionId, projectName, model,
                        inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                        reasoningTokens, totalTokens, cost, startTime, endTime, createdAt,
                        usageSource, sourceDeviceId, sourceDeviceName, isRemote, syncedAt,
                        providerID, providerAccountID, providerAccountLabel, providerAccountSource,
                        provenanceMethod, provenanceConfidence, estimatorVersion, parentRequestID
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider, sessionId, model, COALESCE(sourceDeviceId, ''), COALESCE(providerAccountID, '')) DO UPDATE SET
                        projectName = excluded.projectName,
                        inputTokens = excluded.inputTokens,
                        outputTokens = excluded.outputTokens,
                        cacheCreationTokens = excluded.cacheCreationTokens,
                        cacheReadTokens = excluded.cacheReadTokens,
                        reasoningTokens = excluded.reasoningTokens,
                        totalTokens = excluded.totalTokens,
                        cost = excluded.cost,
                        startTime = excluded.startTime,
                        endTime = excluded.endTime,
                        createdAt = excluded.createdAt,
                        -- VAL-TOKEN-009: Preserve source identity on equal-confidence upserts.
                        -- Only update usageSource when incoming confidence is strictly higher.
                        usageSource = CASE
                            WHEN
                                CASE excluded.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                                >
                                CASE token_usage.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                            THEN excluded.usageSource
                            ELSE token_usage.usageSource
                        END,
                        sourceDeviceId = CASE
                            WHEN CASE excluded.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                                >=
                                CASE token_usage.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                            THEN excluded.sourceDeviceId
                            ELSE token_usage.sourceDeviceId
                        END,
                        sourceDeviceName = CASE
                            WHEN CASE excluded.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                                >=
                                CASE token_usage.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                            THEN excluded.sourceDeviceName
                            ELSE token_usage.sourceDeviceName
                        END,
                        isRemote = excluded.isRemote,
                        providerID = excluded.providerID,
                        providerAccountID = excluded.providerAccountID,
                        providerAccountLabel = excluded.providerAccountLabel,
                        providerAccountSource = excluded.providerAccountSource,
                        provenanceMethod = excluded.provenanceMethod,
                        provenanceConfidence = CASE
                            WHEN
                                CASE excluded.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                                >=
                                CASE token_usage.provenanceConfidence
                                    WHEN 'exact' THEN 4
                                    WHEN 'derived_exact' THEN 3
                                    WHEN 'high_confidence_estimate' THEN 2
                                    WHEN 'low_confidence_estimate' THEN 1
                                    ELSE 0
                                END
                            THEN excluded.provenanceConfidence
                            ELSE token_usage.provenanceConfidence
                        END,
                        estimatorVersion = excluded.estimatorVersion,
                        -- Sticky fusion linkage (see upsertUsage): never erase a
                        -- recorded elderwand parentRequestID with an incoming NULL.
                        parentRequestID = COALESCE(excluded.parentRequestID, token_usage.parentRequestID),
                        syncedAt = NULL
                    WHERE
                        CASE excluded.provenanceConfidence
                            WHEN 'exact' THEN 4
                            WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1
                            ELSE 0
                        END
                        >=
                        CASE token_usage.provenanceConfidence
                            WHEN 'exact' THEN 4
                            WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1
                            ELSE 0
                        END
                    """,
                arguments: [
                    usage.id.uuidString, usage.provider.rawValue, usage.sessionId,
                    usage.projectName, usage.model,
                    usage.inputTokens, usage.outputTokens, usage.cacheCreationTokens,
                    usage.cacheReadTokens, usage.reasoningTokens, usage.totalTokens, usage.cost,
                    usage.startTime, usage.endTime, usage.createdAt,
                    usage.usageSource.rawValue,
                    usage.sourceDeviceId, usage.sourceDeviceName, usage.isRemote, Date(),
                    usage.providerID.rawValue,
                    usagePartition,
                    usage.providerAccountLabel,
                    usage.providerAccountSource?.rawValue,
                    usage.provenanceMethod.rawValue,
                    usage.provenanceConfidence.rawValue,
                    usage.estimatorVersion,
                    usage.parentRequestID
                ]
            )
        }
        SearchQueryCache.shared.clear()
    }
}
