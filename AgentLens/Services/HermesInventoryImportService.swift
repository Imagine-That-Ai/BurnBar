import Foundation
import OpenBurnBarCore

@MainActor
@Observable
final class HermesInventoryImportService {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case importing
        case complete
        case failed(String)
    }

    var phase: Phase = .idle
    var summary: HermesInventoryImportSummary = .empty
    var decision = HermesInventoryImportDecision()
    var progress = HermesInventoryImportProgress()

    private let dataStore: DataStore
    private let settingsManager: SettingsManager
    private let cloudSyncService: CloudSyncService?
    private let iCloudMirrorService: ICloudSessionMirrorService?
    private let parseInventory: @Sendable () async throws -> ParseResult
    private var cachedParseResult: ParseResult?

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        cloudSyncService: CloudSyncService? = nil,
        iCloudMirrorService: ICloudSessionMirrorService? = nil,
        parseInventory: @escaping @Sendable () async throws -> ParseResult = {
            try await HermesParser().parse()
        }
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.cloudSyncService = cloudSyncService
        self.iCloudMirrorService = iCloudMirrorService
        self.parseInventory = parseInventory
    }

    var hasImportableInventory: Bool {
        summary.conversationCount > 0 || summary.usageEventCount > 0
    }

    var primaryStatusText: String {
        switch phase {
        case .idle:
            return "Check for existing Hermes chats before OpenBurnBar imports anything."
        case .scanning:
            return "Scanning Hermes inventory…"
        case .ready:
            guard hasImportableInventory else { return "No existing Hermes conversations found yet." }
            return "\(summary.conversationCount) conversation\(summary.conversationCount == 1 ? "" : "s") ready to import."
        case .importing:
            return "Importing Hermes inventory…"
        case .complete:
            return "Imported \(progress.importedConversationCount) conversation\(progress.importedConversationCount == 1 ? "" : "s")."
        case let .failed(message):
            return message
        }
    }

    func scan() async {
        guard phase != .scanning && phase != .importing else { return }
        phase = .scanning
        do {
            let result = try await parseInventory()
            cachedParseResult = result
            summary = Self.summary(for: result)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func importInventory() async {
        guard phase != .importing else { return }
        phase = .importing

        do {
            let result: ParseResult
            if let cachedParseResult {
                result = cachedParseResult
            } else {
                result = try await parseInventory()
                self.cachedParseResult = result
                summary = Self.summary(for: result)
            }

            if decision.importLocally {
                try dataStore.insert(result.usages)
                let report = try await ConversationIndexer.shared.index(result.conversations, in: dataStore)
                progress = HermesInventoryImportProgress(
                    importedConversationCount: report.changedRecordCount,
                    skippedConversationCount: report.skippedRecordCount,
                    importedUsageEventCount: result.usages.count,
                    enqueuedProjectionJobCount: report.enqueuedProjectionJobCount,
                    cloudBackupRequested: decision.backupToOpenBurnBarCloud,
                    iCloudMirrorRequested: decision.mirrorToICloud
                )
            }

            if decision.backupToOpenBurnBarCloud {
                settingsManager.conversationCloudBackupEnabled = true
                settingsManager.sessionLogCloudBackupEnabled = true
                settingsManager.sessionLogCloudBackupConsentShown = true
                await cloudSyncService?.uploadPending()
                await cloudSyncService?.uploadPendingConversations()
                await cloudSyncService?.uploadPendingSessionLogs()
            }

            if decision.mirrorToICloud {
                settingsManager.iCloudSessionMirrorEnabled = true
                await iCloudMirrorService?.syncIfNeeded()
                _ = try await iCloudMirrorService?.exportHermesConversationsForMobile(result.conversations)
            }

            phase = .complete
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    static func summary(for result: ParseResult) -> HermesInventoryImportSummary {
        let dates = result.conversations.flatMap { [$0.startTime, $0.endTime].compactMap { $0 } }
        let estimatedBytes = result.conversations.reduce(0) { $0 + $1.fullText.utf8.count }
        return HermesInventoryImportSummary(
            conversationCount: result.conversations.count,
            usageEventCount: result.usages.count,
            firstActivityAt: dates.min(),
            lastActivityAt: dates.max(),
            estimatedTranscriptBytes: estimatedBytes
        )
    }
}
