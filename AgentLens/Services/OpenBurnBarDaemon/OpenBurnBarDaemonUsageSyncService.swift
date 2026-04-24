import CryptoKit
import Foundation
import OpenBurnBarCore

struct OpenBurnBarDaemonProviderConfiguration: Equatable, Identifiable {

    struct CredentialSlot: Equatable, Identifiable {
        let slotID: String
        let label: String
        let isEnabled: Bool
        let status: BurnBarProviderCredentialSlotStatus
        let cooldownUntil: Date?
        let lastSelectedAt: Date?
        let lastQuotaRemainingPercent: Double?
        let lastQuotaResetsAt: Date?
        let lastStatusMessage: String?

        var id: String { slotID }
    }

    let providerID: String
    let provider: AgentProvider?
    let displayName: String
    let isEnabled: Bool
    let baseURL: String
    let preferredModelIDs: [String]
    let preferredCredentialSlotID: String?
    let credentialSlots: [CredentialSlot]

    var id: String { providerID }

    /// Brand metadata for rendering logos — works for all catalog providers.
    var brand: ProviderBrand {
        if let provider {
            return ProviderBrand(from: provider)
        }
        return ProviderBrand(providerID: providerID)
    }
}

struct OpenBurnBarDaemonRecentUsage: Equatable, Identifiable {
    let idempotencyKey: String
    let provider: AgentProvider
    let model: String
    let totalTokens: Int
    let cost: Double
    let recordedAt: Date

    var id: String { idempotencyKey }
}

struct OpenBurnBarDaemonRuntimeSnapshot: Equatable {
    static let empty = OpenBurnBarDaemonRuntimeSnapshot(
        providerConfigurations: [],
        recentUsage: [],
        ledgerRecordCount: 0
    )

    let providerConfigurations: [OpenBurnBarDaemonProviderConfiguration]
    let recentUsage: [OpenBurnBarDaemonRecentUsage]
    let ledgerRecordCount: Int
}

final class OpenBurnBarDaemonUsageSyncService {
    private let paths: OpenBurnBarDaemonRuntimePaths
    private let fileManager: FileManager
    private let decoder = JSONDecoder()

    init(
        paths: OpenBurnBarDaemonRuntimePaths = .live(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
    }

    @discardableResult
    func refreshState(
        insertUsages: (([TokenUsage]) throws -> Void)? = nil,
        refreshUsageCache: (() -> Void)? = nil
    ) -> OpenBurnBarDaemonRuntimeSnapshot {
        let usageRecords = loadUsageRecords()
        let importedUsages = usageRecords.compactMap { tokenUsage(from: $0) }

        if let insertUsages, !importedUsages.isEmpty {
            try? insertUsages(importedUsages)
            refreshUsageCache?()
        }

        return OpenBurnBarDaemonRuntimeSnapshot(
            providerConfigurations: providerConfigurations(from: loadProviderConfigurationSnapshot()),
            recentUsage: usageRecords
                .compactMap { recentUsage(from: $0) }
                .sorted { $0.recordedAt > $1.recordedAt }
                .prefix(6)
                .map { $0 },
            ledgerRecordCount: importedUsages.count
        )
    }

    @discardableResult
    func runtimeSnapshot(
        from configSnapshot: BurnBarProviderConfigurationSnapshot,
        usageEvents: [BurnBarUsageEvent],
        insertUsages: (([TokenUsage]) throws -> Void)? = nil,
        refreshUsageCache: (() -> Void)? = nil
    ) -> OpenBurnBarDaemonRuntimeSnapshot {
        let importedUsages = usageEvents.compactMap { tokenUsage(from: $0) }

        if let insertUsages, !importedUsages.isEmpty {
            try? insertUsages(importedUsages)
            refreshUsageCache?()
        }

        return OpenBurnBarDaemonRuntimeSnapshot(
            providerConfigurations: providerConfigurations(from: configSnapshot),
            recentUsage: usageEvents
                .compactMap { recentUsage(from: $0) }
                .sorted { $0.recordedAt > $1.recordedAt }
                .prefix(6)
                .map { $0 },
            ledgerRecordCount: importedUsages.count
        )
    }

    private func loadProviderConfigurationSnapshot() -> BurnBarProviderConfigurationSnapshot {
        guard fileManager.fileExists(atPath: paths.providerConfigURL.path) else {
            return BurnBarProviderConfigurationSnapshot(providers: [])
        }

        guard let data = try? Data(contentsOf: paths.providerConfigURL) else {
            return BurnBarProviderConfigurationSnapshot(providers: [])
        }

        if let directSnapshot = try? decoder.decode(BurnBarProviderConfigurationSnapshot.self, from: data) {
            return directSnapshot
        }

        guard let snapshot = try? decoder.decode(StoredProviderConfigurationSnapshot.self, from: data) else {
            return BurnBarProviderConfigurationSnapshot(providers: [])
        }

        return BurnBarProviderConfigurationSnapshot(
            providers: snapshot.providers.map { settings in
                BurnBarProviderSettings(
                    providerID: settings.providerID,
                    isEnabled: settings.isEnabled,
                    baseURL: settings.baseURL,
                    preferredModelIDs: settings.preferredModelIDs,
                    preferredCredentialSlotID: settings.preferredCredentialSlotID,
                    credentialSlots: settings.credentialSlots
                )
            }
        )
    }

    private func providerConfigurations(
        from snapshot: BurnBarProviderConfigurationSnapshot
    ) -> [OpenBurnBarDaemonProviderConfiguration] {
        snapshot.providers.map { settings in
            let provider = agentProvider(for: settings.providerID)
            let catalogName = BurnBarCatalogLoader.bundledCatalog.provider(id: settings.providerID)?.displayName
                ?? settings.providerID.capitalized
            return OpenBurnBarDaemonProviderConfiguration(
                providerID: settings.providerID,
                provider: provider,
                displayName: catalogName,
                isEnabled: settings.isEnabled,
                baseURL: settings.baseURL,
                preferredModelIDs: settings.preferredModelIDs,
                preferredCredentialSlotID: settings.preferredCredentialSlotID,
                credentialSlots: settings.credentialSlots.map { slot in
                        OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                            slotID: slot.slotID,
                            label: slot.label,
                            isEnabled: slot.isEnabled,
                            status: slot.status,
                            cooldownUntil: slot.cooldownUntil,
                            lastSelectedAt: slot.lastSelectedAt,
                            lastQuotaRemainingPercent: slot.lastQuotaRemainingPercent,
                            lastQuotaResetsAt: slot.lastQuotaResetsAt,
                            lastStatusMessage: slot.lastStatusMessage
                        )
                    }
                )
            }
            .sorted { providerSortOrder($0.provider) < providerSortOrder($1.provider) }
    }

    private func loadUsageRecords() -> [StoredUsageRecord] {
        guard fileManager.fileExists(atPath: paths.usageLedgerURL.path) else {
            return []
        }

        guard let fileContents = try? String(contentsOf: paths.usageLedgerURL, encoding: .utf8) else {
            return []
        }

        return fileContents
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                try? decoder.decode(StoredUsageRecord.self, from: Data(line.utf8))
            }
    }

    private func tokenUsage(from event: BurnBarUsageEvent) -> TokenUsage? {
        guard let provider = agentProvider(for: event.providerID) else {
            return nil
        }

        let sessionID = event.runID?.rawValue ?? "\(provider.rawValue.lowercased())-\(event.recordedAt.timeIntervalSince1970)"
        let identityValue = event.runID?.rawValue ?? "\(event.providerID)|\(event.modelID)|\(event.recordedAt.timeIntervalSince1970)"
        return TokenUsage(
            id: deterministicUUID(for: identityValue),
            provider: provider,
            sessionId: sessionID,
            projectName: "OpenBurnBar Daemon",
            model: event.modelID,
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheCreationTokens: event.cacheCreationTokens,
            cacheReadTokens: event.cacheReadTokens,
            costUSD: event.cost,
            startTime: event.recordedAt,
            endTime: event.recordedAt,
            usageSource: .daemon,
            provenanceMethod: .daemonBridge,
            provenanceConfidence: .exact
        )
    }

    private func tokenUsage(from record: StoredUsageRecord) -> TokenUsage? {
        guard let provider = agentProvider(for: record.event.providerID) else {
            return nil
        }

        let sessionID = record.event.runID?.rawValue ?? record.idempotencyKey
        return TokenUsage(
            id: deterministicUUID(for: record.idempotencyKey),
            provider: provider,
            sessionId: sessionID,
            projectName: "OpenBurnBar Daemon",
            model: record.event.modelID,
            inputTokens: record.event.inputTokens,
            outputTokens: record.event.outputTokens,
            cacheCreationTokens: record.event.cacheCreationTokens,
            cacheReadTokens: record.event.cacheReadTokens,
            costUSD: record.event.cost,
            startTime: record.event.recordedAt,
            endTime: record.event.recordedAt,
            usageSource: .daemon,
            provenanceMethod: .daemonBridge,
            provenanceConfidence: .exact
        )
    }

    private func recentUsage(from event: BurnBarUsageEvent) -> OpenBurnBarDaemonRecentUsage? {
        guard let provider = agentProvider(for: event.providerID) else {
            return nil
        }

        return OpenBurnBarDaemonRecentUsage(
            idempotencyKey: event.runID?.rawValue ?? "\(event.providerID)|\(event.modelID)|\(event.recordedAt.timeIntervalSince1970)",
            provider: provider,
            model: event.modelID,
            totalTokens: event.inputTokens + event.outputTokens + event.cacheCreationTokens + event.cacheReadTokens,
            cost: event.cost,
            recordedAt: event.recordedAt
        )
    }

    private func recentUsage(from record: StoredUsageRecord) -> OpenBurnBarDaemonRecentUsage? {
        guard let provider = agentProvider(for: record.event.providerID) else {
            return nil
        }

        return OpenBurnBarDaemonRecentUsage(
            idempotencyKey: record.idempotencyKey,
            provider: provider,
            model: record.event.modelID,
            totalTokens: record.event.inputTokens + record.event.outputTokens + record.event.cacheCreationTokens + record.event.cacheReadTokens,
            cost: record.event.cost,
            recordedAt: record.event.recordedAt
        )
    }

    private func deterministicUUID(for value: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        let bytes = Array(digest)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func agentProvider(for providerID: String) -> AgentProvider? {
        switch providerID.lowercased() {
        case "zai":       return .zai
        case "minimax":   return .minimax
        case "openai":    return .codex
        case "anthropic": return .claudeCode
        case "google":    return .geminiCLI
        case "deepseek":  return .kimi
        case "mistral":   return .cline
        case "meta":      return .forgeDev
        case "cohere":    return .augment
        case "xai":       return .kiloCode
        case "amazon":    return .rooCode
        case "alibaba":   return .rooCode
        case "moonshot":  return .kimi
        case "misc":      return nil
        default:          return nil
        }
    }

    private func providerSortOrder(_ provider: AgentProvider?) -> Int {
        switch provider {
        case .zai:
            return 0
        case .minimax:
            return 1
        default:
            return 2
        }
    }
}

struct StoredProviderConfigurationSnapshot: Codable {
    let providers: [StoredProviderSettings]
}

struct StoredProviderSettings: Codable {
    let providerID: String
    let isEnabled: Bool
    let baseURL: String
    let preferredModelIDs: [String]
    let preferredCredentialSlotID: String?
    let credentialSlots: [BurnBarProviderCredentialSlot]

    private enum CodingKeys: String, CodingKey {
        case providerID
        case isEnabled
        case baseURL
        case preferredModelIDs
        case preferredCredentialSlotID
        case credentialSlots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        preferredModelIDs = try container.decode([String].self, forKey: .preferredModelIDs)
        preferredCredentialSlotID = try container.decodeIfPresent(String.self, forKey: .preferredCredentialSlotID)
        credentialSlots = try container.decodeIfPresent([BurnBarProviderCredentialSlot].self, forKey: .credentialSlots) ?? []
    }
}

struct StoredUsageRecord: Codable {
    let idempotencyKey: String
    let event: BurnBarUsageEvent
}
