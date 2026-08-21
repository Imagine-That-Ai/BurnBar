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
                    provenanceMethod, provenanceConfidence, estimatorVersion, parentRequestID,
                    billingKind
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    -- Billing provenance follows the SAME source/confidence
                    -- precedence the `usageSource` arm above applies, because
                    -- the kind describes the source that the row retains. An
                    -- unknown-carrying correction never erases a classified
                    -- kind; a stale unknown is always improvable; a strictly
                    -- higher-confidence source re-classifies; an
                    -- equal-confidence source may re-classify only when it
                    -- speaks for the source the row already records. Without
                    -- that last gate an exact Codex provider-log correction
                    -- would flip a confirmed `billing_api` wallet charge into
                    -- plan value while `usageSource` still said `billing_api`.
                    billingKind = CASE
                        WHEN excluded.billingKind = 'unknown' THEN token_usage.billingKind
                        WHEN token_usage.billingKind = 'unknown' THEN excluded.billingKind
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
                        THEN excluded.billingKind
                        WHEN excluded.usageSource = token_usage.usageSource THEN excluded.billingKind
                        ELSE token_usage.billingKind
                    END,
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
                        -- A differing kind is a reason to run the write; whether
                        -- it actually replaces the stored one is decided by the
                        -- precedence CASE in the SET clause above.
                        OR (excluded.billingKind != 'unknown'
                            AND token_usage.billingKind != excluded.billingKind)
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
                usage.parentRequestID,
                // Stamp at write time; derive for callers that didn't classify.
                (usage.billingKind == .unknown
                    ? BurnBarBillingProvenance.classify(
                        provider: usage.provider,
                        usageSource: usage.usageSource
                    )
                    : usage.billingKind).rawValue
            ]
        )
    }

    static func usagePartitionToken(from rawValue: String?) -> String? { // pure-move: was private
        TokenUsage.providerAccountIdentityPartition(from: rawValue)
    }

    static func decodeUsage(row: Row) -> TokenUsage? { // pure-move: was private
        guard let idString = indexed(row, UsageDecodeCol.id.rawValue) as? String,
              let id = UUID(uuidString: idString),
              let providerString = indexed(row, UsageDecodeCol.provider.rawValue) as? String,
              let provider = AgentProvider.resolve(providerString),
              let sessionId = indexed(row, UsageDecodeCol.sessionId.rawValue) as? String,
              let projectName = indexed(row, UsageDecodeCol.projectName.rawValue) as? String,
              let model = indexed(row, UsageDecodeCol.model.rawValue) as? String else { return nil }

        let inputTokens = intValue(indexed(row, UsageDecodeCol.inputTokens.rawValue))
        let outputTokens = intValue(indexed(row, UsageDecodeCol.outputTokens.rawValue))
        let cacheCreationTokens = intValue(indexed(row, UsageDecodeCol.cacheCreationTokens.rawValue))
        let cacheReadTokens = intValue(indexed(row, UsageDecodeCol.cacheReadTokens.rawValue))
        let reasoningTokens = intValue(indexed(row, UsageDecodeCol.reasoningTokens.rawValue))
        let usageSourceRaw = indexed(row, UsageDecodeCol.usageSource.rawValue) as? String
        let usageSource = usageSourceRaw.flatMap { UsageSource(rawValue: $0) } ?? .unknown
        let executionSourceKind = (indexed(row, UsageDecodeCol.executionSourceKind.rawValue) as? String)
            .flatMap { UsageExecutionSourceKind(rawValue: $0) }
        let executionSourceConfidence = (indexed(row, UsageDecodeCol.executionSourceConfidence.rawValue) as? String)
            .flatMap { UsageProvenanceConfidence(rawValue: $0) }
        let provenanceMethodRaw = indexed(row, UsageDecodeCol.provenanceMethod.rawValue) as? String
        let provenanceMethod = provenanceMethodRaw.flatMap { UsageProvenanceMethod(rawValue: $0) } ?? .unknown
        let provenanceConfidenceRaw = indexed(row, UsageDecodeCol.provenanceConfidence.rawValue) as? String
        let provenanceConfidence = provenanceConfidenceRaw.flatMap { UsageProvenanceConfidence(rawValue: $0) } ?? .unknown
        let estimatorVersion = indexed(row, UsageDecodeCol.estimatorVersion.rawValue) as? String ?? ""
        let costValue = indexed(row, UsageDecodeCol.cost.rawValue)
        let cost = (costValue as? Double) ?? ((costValue as? NSNumber)?.doubleValue) ?? 0
        let startTime = OpenBurnBarDatabase.parseDateValue(indexed(row, UsageDecodeCol.startTime.rawValue))
        let endTime = OpenBurnBarDatabase.parseDateValue(indexed(row, UsageDecodeCol.endTime.rawValue))
        let createdAt = OpenBurnBarDatabase.parseDateValue(indexed(row, UsageDecodeCol.createdAt.rawValue)) ?? Date()
        guard let startTime, let endTime else { return nil }

        let providerID = (indexed(row, UsageDecodeCol.providerID.rawValue) as? String).map(ProviderID.init(rawValue:)) ?? provider.providerID
        let providerAccountSourceRaw = indexed(row, UsageDecodeCol.providerAccountSource.rawValue) as? String

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
            executionSourceID: indexed(row, UsageDecodeCol.executionSourceID.rawValue) as? String,
            executionSourceName: indexed(row, UsageDecodeCol.executionSourceName.rawValue) as? String,
            executionSourceKind: executionSourceKind,
            executionSourceConfidence: executionSourceConfidence,
            sourceDeviceId: indexed(row, UsageDecodeCol.sourceDeviceId.rawValue) as? String,
            sourceDeviceName: indexed(row, UsageDecodeCol.sourceDeviceName.rawValue) as? String,
            isRemote: intValue(indexed(row, UsageDecodeCol.isRemote.rawValue)) != 0,
            providerID: providerID,
            providerAccountID: indexed(row, UsageDecodeCol.providerAccountID.rawValue) as? String,
            providerAccountLabel: indexed(row, UsageDecodeCol.providerAccountLabel.rawValue) as? String,
            providerAccountSource: providerAccountSourceRaw.flatMap { ProviderAccountStorageScope(rawValue: $0) },
            provenanceMethod: provenanceMethod,
            provenanceConfidence: provenanceConfidence,
            estimatorVersion: estimatorVersion,
            parentRequestID: indexed(row, UsageDecodeCol.parentRequestID.rawValue) as? String,
            billingKind: (indexed(row, UsageDecodeCol.billingKind.rawValue) as? String)
                .flatMap(BurnBarBillingKind.init(rawValue:)) ?? .unknown
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
