import Foundation
import GRDB
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
    private let preflight: HermesInventoryImportPreflight
    private var cachedParseResult: ParseResult?

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        cloudSyncService: CloudSyncService? = nil,
        iCloudMirrorService: ICloudSessionMirrorService? = nil,
        parseInventory: @escaping @Sendable () async throws -> ParseResult = {
            try await HermesParser().parse()
        },
        preflight: HermesInventoryImportPreflight = .live
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.cloudSyncService = cloudSyncService
        self.iCloudMirrorService = iCloudMirrorService
        self.parseInventory = parseInventory
        self.preflight = preflight
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
            phase = .failed(Self.describe(error))
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
                try preflight.check(summary.estimatedTranscriptBytes)
                try dataStore.insertChunked(result.usages)
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
            phase = .failed(Self.describe(error))
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

    /// Converts any thrown error from the import path into a user-facing string.
    /// Raw GRDB errors (e.g. "SQLite error 10: disk I/O error") are opaque to
    /// end-users; this maps the common SQLite result codes onto actionable
    /// guidance the user can act on without filing a bug.
    static func describe(_ error: Error) -> String {
        if let preflightError = error as? HermesInventoryImportPreflightError {
            return preflightError.userMessage
        }
        if let dbError = error as? DatabaseError {
            return describe(databaseError: dbError)
        }
        return error.localizedDescription
    }

    private static func describe(databaseError error: DatabaseError) -> String {
        let supportPath = OpenBurnBarAppPaths.live().supportDirectory.path
        let extendedCode = error.extendedResultCode.rawValue
        switch error.resultCode {
        case .SQLITE_FULL:
            return "Your disk is full. Free up space on the volume containing \(supportPath) and try the import again."
        case .SQLITE_IOERR:
            return "OpenBurnBar couldn't write to its database. This is usually caused by low disk space or restricted permissions on \(supportPath). Free up space, quit any tools touching that folder, and try the import again. (SQLite \(error.resultCode.rawValue)/\(extendedCode))"
        case .SQLITE_BUSY, .SQLITE_LOCKED:
            return "The OpenBurnBar database is busy. Quit other OpenBurnBar processes (Finder previews, Spotlight, backup tools) and try the import again."
        case .SQLITE_READONLY:
            return "The OpenBurnBar database is read-only. Check the permissions on \(supportPath) and try the import again."
        case .SQLITE_NOTADB, .SQLITE_CORRUPT:
            return "The OpenBurnBar database appears to be corrupt or wrongly encrypted. Restore from a recovery bundle or reset the database before importing."
        default:
            let message = error.message ?? "no detail"
            return "Database error \(error.resultCode.rawValue) (extended \(extendedCode)): \(message). The import was rolled back; nothing was imported."
        }
    }
}

// MARK: - Preflight

/// Read-only failure surface from the import preflight. Caught by the service
/// and translated to a user-facing string via `userMessage`.
enum HermesInventoryImportPreflightError: Error, Equatable {
    case supportDirectoryUnwritable(path: String)
    case insufficientDiskSpace(availableBytes: Int64, neededBytes: Int64, path: String)

    var userMessage: String {
        switch self {
        case let .supportDirectoryUnwritable(path):
            return "OpenBurnBar can't write to \(path). Check the folder permissions (it should be owned by you with read/write access) and try the import again."
        case let .insufficientDiskSpace(availableBytes, neededBytes, path):
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            let available = formatter.string(fromByteCount: availableBytes)
            let needed = formatter.string(fromByteCount: neededBytes)
            return "Not enough free space on the volume containing \(path) — \(available) free, ~\(needed) needed. Free up space and try the import again."
        }
    }
}

/// Pre-flight checks for the import. Extracted so tests can inject deterministic
/// behavior without needing a real disk volume.
struct HermesInventoryImportPreflight: Sendable {
    /// Estimated minimum overhead the import itself consumes on disk regardless
    /// of transcript size (WAL pages, indexes, projection rows). Picked
    /// generously so the preflight doesn't surface false positives on tiny
    /// imports where the transcript footprint is negligible.
    static let minimumFreeBytes: Int64 = 50_000_000

    var check: @Sendable (_ estimatedTranscriptBytes: Int) throws -> Void

    static let live = HermesInventoryImportPreflight { estimatedTranscriptBytes in
        let paths = OpenBurnBarAppPaths.live()
        let supportDir = paths.supportDirectory

        let neededBytes = max(
            HermesInventoryImportPreflight.minimumFreeBytes,
            Int64(estimatedTranscriptBytes) * 2
        )

        if FileManager.default.fileExists(atPath: supportDir.path),
           !FileManager.default.isWritableFile(atPath: supportDir.path) {
            throw HermesInventoryImportPreflightError.supportDirectoryUnwritable(
                path: supportDir.path
            )
        }

        let values = try? supportDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let availableBytes = values?.volumeAvailableCapacityForImportantUsage,
           availableBytes < neededBytes {
            throw HermesInventoryImportPreflightError.insufficientDiskSpace(
                availableBytes: availableBytes,
                neededBytes: neededBytes,
                path: supportDir.path
            )
        }
    }

    static let alwaysOk = HermesInventoryImportPreflight { _ in }
}
