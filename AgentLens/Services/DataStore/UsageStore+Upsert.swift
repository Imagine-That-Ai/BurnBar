import Foundation
import GRDB
import OpenBurnBarCore

extension UsageStore {
    func upsertUsage(_ usage: TokenUsage, in db: Database) throws { // pure-move: was private
        let usagePartition = Self.usagePartitionToken(from: usage.providerAccountID)
        let statement = try db.cachedStatement(
            sql: """
                INSERT INTO token_usage (
                    id, provider, sessionId, projectName, model,
                    inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
                    reasoningTokens, totalTokens, cost, startTime, endTime, createdAt,
                    usageSource, executionSourceID, executionSourceName,
                    executionSourceKind, executionSourceConfidence,
                    sourceDeviceId, sourceDeviceName, isRemote,
                    providerID, providerAccountID, providerAccountLabel, providerAccountSource,
                    provenanceMethod, provenanceConfidence, estimatorVersion, parentRequestID
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    executionSourceID = CASE
                        WHEN excluded.executionSourceID != 'unknown' AND
                            CASE excluded.executionSourceConfidence
                                WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                                WHEN 'high_confidence_estimate' THEN 2
                                WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                            >=
                            CASE token_usage.executionSourceConfidence
                                WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                                WHEN 'high_confidence_estimate' THEN 2
                                WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                        THEN excluded.executionSourceID ELSE token_usage.executionSourceID END,
                    executionSourceName = CASE
                        WHEN excluded.executionSourceID != 'unknown' AND
                            CASE excluded.executionSourceConfidence
                                WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                                WHEN 'high_confidence_estimate' THEN 2
                                WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                            >=
                            CASE token_usage.executionSourceConfidence
                                WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                                WHEN 'high_confidence_estimate' THEN 2
                                WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                        THEN excluded.executionSourceName ELSE token_usage.executionSourceName END,
                    executionSourceKind = CASE
                        WHEN excluded.executionSourceID != 'unknown' AND
                            CASE excluded.executionSourceConfidence
                                WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                                WHEN 'high_confidence_estimate' THEN 2
                                WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                            >=
                            CASE token_usage.executionSourceConfidence
                                WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                                WHEN 'high_confidence_estimate' THEN 2
                                WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                        THEN excluded.executionSourceKind ELSE token_usage.executionSourceKind END,
                    executionSourceConfidence = CASE
                        WHEN excluded.executionSourceID != 'unknown' AND
                            CASE excluded.executionSourceConfidence
                                WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                                WHEN 'high_confidence_estimate' THEN 2
                                WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                            >=
                            CASE token_usage.executionSourceConfidence
                                WHEN 'exact' THEN 4 WHEN 'derived_exact' THEN 3
                                WHEN 'high_confidence_estimate' THEN 2
                                WHEN 'low_confidence_estimate' THEN 1 ELSE 0 END
                        THEN excluded.executionSourceConfidence ELSE token_usage.executionSourceConfidence END,
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
                    -- Fusion linkage is sticky: once a daemon row records the
                    -- elderwand parentRequestID, a later non-daemon correction
                    -- (which carries NULL) must not erase it.
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
                    AND (
                        token_usage.projectName != excluded.projectName
                        OR token_usage.inputTokens != excluded.inputTokens
                        OR token_usage.outputTokens != excluded.outputTokens
                        OR token_usage.cacheCreationTokens != excluded.cacheCreationTokens
                        OR token_usage.cacheReadTokens != excluded.cacheReadTokens
                        OR token_usage.reasoningTokens != excluded.reasoningTokens
                        OR token_usage.totalTokens != excluded.totalTokens
                        OR token_usage.cost != excluded.cost
                        OR token_usage.startTime != excluded.startTime
                        OR token_usage.endTime != excluded.endTime
                        OR token_usage.usageSource != excluded.usageSource
                        OR (excluded.executionSourceID != 'unknown' AND (
                            token_usage.executionSourceID != excluded.executionSourceID
                            OR token_usage.executionSourceName != excluded.executionSourceName
                            OR token_usage.executionSourceKind != excluded.executionSourceKind
                            OR token_usage.executionSourceConfidence != excluded.executionSourceConfidence
                        ))
                        OR COALESCE(token_usage.providerAccountID, '') != COALESCE(excluded.providerAccountID, '')
                        OR COALESCE(token_usage.providerAccountLabel, '') != COALESCE(excluded.providerAccountLabel, '')
                        OR COALESCE(token_usage.providerAccountSource, '') != COALESCE(excluded.providerAccountSource, '')
                        -- Update when an incoming daemon row newly carries the
                        -- fusion parentRequestID a prior row lacked.
                        OR (excluded.parentRequestID IS NOT NULL
                            AND COALESCE(token_usage.parentRequestID, '') != excluded.parentRequestID)
                    )
                """,
        )
        try statement.execute(
            arguments: [
                usage.id.uuidString,
                usage.provider.rawValue,
                usage.sessionId,
                usage.projectName,
                usage.model,
                usage.inputTokens,
                usage.outputTokens,
                usage.cacheCreationTokens,
                usage.cacheReadTokens,
                usage.reasoningTokens,
                usage.totalTokens,
                usage.cost,
                usage.startTime,
                usage.endTime,
                usage.createdAt,
                usage.usageSource.rawValue,
                usage.executionSourceID,
                usage.executionSourceName,
                usage.executionSourceKind.rawValue,
                usage.executionSourceConfidence.rawValue,
                usage.sourceDeviceId,
                usage.sourceDeviceName,
                usage.isRemote ? 1 : 0,
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

    static func usagePartitionToken(from rawValue: String?) -> String? { // pure-move: was private
        TokenUsage.providerAccountIdentityPartition(from: rawValue)
    }

    static func decodeUsage(row: Row) -> TokenUsage? { // pure-move: was private
        guard let idString = row["id"] as? String,
              let id = UUID(uuidString: idString),
              let providerString = row["provider"] as? String,
              let provider = AgentProvider(rawValue: providerString),
              let sessionId = row["sessionId"] as? String,
              let projectName = row["projectName"] as? String,
              let model = row["model"] as? String else { return nil }

        let inputTokens = intValue(row["inputTokens"])
        let outputTokens = intValue(row["outputTokens"])
        let cacheCreationTokens = intValue(row["cacheCreationTokens"])
        let cacheReadTokens = intValue(row["cacheReadTokens"])
        let reasoningTokens = intValue(row["reasoningTokens"])
        let usageSourceRaw = row["usageSource"] as? String
        let usageSource = usageSourceRaw.flatMap { UsageSource(rawValue: $0) } ?? .unknown
        let executionSourceKind = (row["executionSourceKind"] as? String)
            .flatMap { UsageExecutionSourceKind(rawValue: $0) }
        let executionSourceConfidence = (row["executionSourceConfidence"] as? String)
            .flatMap { UsageProvenanceConfidence(rawValue: $0) }
        let provenanceMethodRaw = row["provenanceMethod"] as? String
        let provenanceMethod = provenanceMethodRaw.flatMap { UsageProvenanceMethod(rawValue: $0) } ?? .unknown
        let provenanceConfidenceRaw = row["provenanceConfidence"] as? String
        let provenanceConfidence = provenanceConfidenceRaw.flatMap { UsageProvenanceConfidence(rawValue: $0) } ?? .unknown
        let estimatorVersion = row["estimatorVersion"] as? String ?? ""
        let cost = (row["cost"] as? Double) ?? ((row["cost"] as? NSNumber)?.doubleValue) ?? 0
        let startTime = OpenBurnBarDatabase.parseDateValue(row["startTime"])
        let endTime = OpenBurnBarDatabase.parseDateValue(row["endTime"])
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date()
        guard let startTime, let endTime else { return nil }

        let providerID = (row["providerID"] as? String).map(ProviderID.init(rawValue:)) ?? provider.providerID
        let providerAccountSourceRaw = row["providerAccountSource"] as? String

        return TokenUsage(
            id: id,
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime,
            createdAt: createdAt,
            usageSource: usageSource,
            executionSourceID: row["executionSourceID"] as? String,
            executionSourceName: row["executionSourceName"] as? String,
            executionSourceKind: executionSourceKind,
            executionSourceConfidence: executionSourceConfidence,
            sourceDeviceId: row["sourceDeviceId"] as? String,
            sourceDeviceName: row["sourceDeviceName"] as? String,
            isRemote: intValue(row["isRemote"]) != 0,
            providerID: providerID,
            providerAccountID: row["providerAccountID"] as? String,
            providerAccountLabel: row["providerAccountLabel"] as? String,
            providerAccountSource: providerAccountSourceRaw.flatMap { ProviderAccountStorageScope(rawValue: $0) },
            provenanceMethod: provenanceMethod,
            provenanceConfidence: provenanceConfidence,
            estimatorVersion: estimatorVersion,
            parentRequestID: row["parentRequestID"] as? String
        )
    }

    static func intValue(_ value: Any?) -> Int { // pure-move: was fileprivate
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    static func doubleValue(_ value: Any?) -> Double { // pure-move: was fileprivate
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return 0
    }
}
