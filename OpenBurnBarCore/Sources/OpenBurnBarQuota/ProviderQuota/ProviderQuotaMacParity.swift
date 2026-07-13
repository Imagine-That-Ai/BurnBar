import Foundation
import OpenBurnBarKernel

// MARK: - macOS adapter conveniences (lifted with WS-C2)

public extension ProviderQuotaSnapshot {
    /// macOS adapter convenience initializer (`AgentProvider` + source kind enum).
    init(
        provider: AgentProvider,
        providerID: ProviderID? = nil,
        accountID: String? = nil,
        accountLabel: String? = nil,
        accountStorageScope: ProviderAccountStorageScope? = nil,
        fetchedAt: Date,
        source: ProviderQuotaSourceKind,
        sourceId: String? = nil,
        confidence: ProviderQuotaConfidence,
        managementURL: String?,
        statusMessage: String,
        buckets: [ProviderQuotaBucket],
        schemaVersion: Int = 2
    ) {
        let pid = providerID ?? provider.providerID
        let sid = sourceId ?? accountID ?? "default"
        self.init(
            id: "\(pid.rawValue)_\(sid)",
            provider: provider.rawValue,
            providerID: pid,
            accountID: accountID,
            accountLabel: accountLabel,
            accountStorageScope: accountStorageScope,
            sourceKind: source,
            sourceId: sid,
            fetchedAt: fetchedAt,
            source: source.rawValue,
            confidence: confidence,
            managementURL: managementURL,
            statusMessage: statusMessage,
            buckets: buckets,
            schemaVersion: schemaVersion,
            updatedAt: fetchedAt
        )
    }

    func withAccountMetadata(
        providerID: ProviderID,
        accountID: String,
        accountLabel: String?,
        accountStorageScope: ProviderAccountStorageScope,
        sourceId: String
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            id: id,
            provider: provider,
            providerID: providerID,
            accountID: accountID,
            accountLabel: accountLabel,
            accountStorageScope: accountStorageScope,
            sourceKind: sourceKind,
            sourceId: sourceId,
            fetchedAt: fetchedAt,
            source: source,
            confidence: confidence,
            managementURL: managementURL,
            statusMessage: statusMessage,
            buckets: buckets,
            schemaVersion: schemaVersion,
            updatedAt: updatedAt
        )
    }
}

public extension ProviderQuotaConfidence {
    static var exact: ProviderQuotaConfidence { .high }
    static var estimated: ProviderQuotaConfidence { .medium }
    static var unavailable: ProviderQuotaConfidence { .stale }
}
