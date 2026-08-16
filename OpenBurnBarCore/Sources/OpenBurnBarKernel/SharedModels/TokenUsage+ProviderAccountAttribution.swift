import Foundation

extension TokenUsage {
    /// Returns a copy of this row attributed to a provider account.
    ///
    /// The copy re-derives its deterministic `id` (the account partition is part
    /// of the identity key), so callers must treat the attributed row as a new
    /// row identity: persist paths that delete-by-session before insert (the
    /// parser refresh pipeline) and cloud orphan cleanup already handle the
    /// re-keying. `rawIdentity` is hashed into the `acct_sha256_…` partition
    /// token before it reaches SQLite or Firestore; only `label` stays
    /// human-readable.
    ///
    /// Intended for freshly parsed rows: `totalTokens` is re-derived from the
    /// token components, matching how every parser-built row computes it.
    public func attributingAccount(
        rawIdentity: String,
        label: String?,
        source: ProviderAccountStorageScope
    ) -> TokenUsage {
        TokenUsage(
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
            executionSourceID: executionSourceID,
            executionSourceName: executionSourceName,
            executionSourceKind: executionSourceKind,
            executionSourceConfidence: executionSourceConfidence,
            deviceId: deviceId,
            sourceDeviceId: sourceDeviceId,
            sourceDeviceName: sourceDeviceName,
            isRemote: isRemote,
            providerID: providerID,
            providerAccountID: rawIdentity,
            providerAccountLabel: label,
            providerAccountSource: source,
            currency: currency,
            recordedAt: recordedAt,
            eventKind: eventKind,
            idempotencyKey: idempotencyKey,
            provenanceMethod: provenanceMethod,
            provenanceConfidence: provenanceConfidence,
            estimatorVersion: estimatorVersion,
            parentRequestID: parentRequestID
        )
    }
}
