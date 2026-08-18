import Foundation
import OpenBurnBarFirestoreModels

public extension TokenUsage {
    /// Wire → domain bridge for the generated usage-quota canon.
    /// Fails closed when provider identity or recordedAt cannot be parsed.
    init?(generated doc: FirestoreUsageEventDoc) {
        let recordedAt = doc.recordedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recordedAt.isEmpty else { return nil }
        let provider = AgentProvider.fromProviderID(ProviderID(rawValue: doc.providerID ?? doc.provider))
            ?? AgentProvider.fromPersistedToken(doc.provider)
            ?? AgentProvider(rawValue: doc.provider)
        guard let provider else { return nil }
        self = TokenUsage.fromGeneratedEvent(
            provider: provider,
            sessionId: doc.sessionId ?? "",
            model: doc.model ?? "",
            inputTokens: doc.inputTokens ?? 0,
            outputTokens: doc.outputTokens ?? 0,
            cacheCreationTokens: doc.cacheWriteTokens ?? 0,
            cacheReadTokens: doc.cacheReadTokens ?? 0,
            costUSD: doc.costUSD ?? 0,
            recordedDate: ThreadSafeISO8601DateFormatter.parse(recordedAt) ?? Date(),
            providerID: doc.providerID.map(ProviderID.init(rawValue:)),
            providerAccountID: doc.providerAccountID,
            providerAccountLabel: doc.providerAccountLabel,
            currency: doc.currency,
            recordedAt: recordedAt,
            eventKind: doc.eventKind,
            idempotencyKey: doc.idempotencyKey,
            deviceId: doc.deviceId,
            sourceDeviceId: doc.sourceDeviceId,
            executionSourceID: doc.executionSourceID,
            executionSourceName: doc.executionSourceName,
            executionSourceKind: UsageExecutionSourceKind(rawValue: doc.executionSourceKind ?? ""),
            executionSourceConfidence: UsageProvenanceConfidence(rawValue: doc.executionSourceConfidence ?? "")
        )
    }
}
